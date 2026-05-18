"""
reference_core.py
=================

MNIST CNN 가속기 (EEE351 AS2) 검증용 numpy reference inference 엔진.

목적
----
AS2_announcement.pdf의 명세를 비트 단위로 준수하는 reference forward pass.
- 모든 layer 결과를 명세 그대로 INT8 saturation (LSB 10bit shift + clip[-128,127])
- 후속 시나리오 스크립트 (1_quantize.py, 3_complex_winograd_f(4,3).py)가
  이 모듈을 import해서 conv2_fn 등을 교체하며 12개 시나리오를 평가
- 0_reference.py는 이 모듈을 그대로 사용하여 INT8 Direct baseline + bit-exact
  검증을 수행

설계 원칙
--------
1. 모든 누적은 int32. INT8×INT8 = INT16, Conv2의 8ch×9 = 72개 누적시
   max ~127×127×72 ≈ 1.16M → 21 bit 정도. FC는 2304개 누적 → 25 bit. int32 안전.
2. Conv는 im2col + matmul로 numpy BLAS (Apple Accelerate) 활용. M4 Max에서 빠름.
3. 시나리오 교체 포인트는 forward(conv1_fn=, conv2_fn=, fc_fn=)로 주입.
   양자화는 forward 외부에서 weight를 미리 변환해 전달 (forward는 monolithic하게 유지).

명세 (AS2_announcement.pdf 요약)
--------------------------------
네트워크:
    Input (1, 28, 28) INT8
      → Conv1 (8, 1, 3, 3), stride 1, no pad
    Feature Map1 (8, 26, 26) INT8 after sat
      → ReLU
      → Conv2 (16, 8, 3, 3), stride 1, no pad
    Feature Map2 (16, 24, 24) INT8 after sat
      → ReLU
      → MaxPool 2×2 (stride 2)
    Feature Map3 (16, 12, 12) INT8
      → Flatten (C-order: idx = c*144 + h*12 + w → 2304)
      → FC (10, 2304)
    Output Logit (10) INT8 after sat → argmax

Saturation 규칙 (모든 Conv/FC 출력에 동일하게 적용):
    acc (int32, bit-extended)
      → shift = acc >> 10        # LSB 10bit arithmetic shift (반올림 X, floor)
      → clip(shift, -128, 127)   # int8 saturation
      → cast to int8             # LSB 8bit만 살림

Flatten 순서 (명세 Fig.3 + 본문 "width, height, channel" 재확인):
    Feature Map3 (C=16, H=12, W=12) → C-order .flatten()
    idx = c * 144 + h * 12 + w
    한 채널의 12×12 = 144 픽셀이 먼저 (W 빠르게 변함), 다음 채널의 144 픽셀, ...
"""

from __future__ import annotations

import numpy as np
from typing import Callable

# =============================================================================
# 저수준 빌딩 블록
# =============================================================================

def truncate_satdown(acc: np.ndarray, shift: int = 10) -> np.ndarray:
    """
    명세 INT8 saturation: acc (int32) → (>>shift) → clip[-128,127] → int8.

    구현 노트
    --------
    - arithmetic right shift: numpy의 `>>`는 정수 dtype에서 산술 시프트 (음수 보존).
      단, 음수에 대해 numpy의 `>>`는 **floor division by 2^shift**와 동등.
      예: -1 >> 1 == -1 (floor(-0.5) = -1). 이것이 명세의 "LSB 10bit 버림"과 일치.
    - clip 후 int8 캐스팅은 단순 dtype 변환 (이미 [-128,127] 범위이므로 wrap 없음).

    Parameters
    ----------
    acc   : int32 (or wider) ndarray, conv/FC 누적 결과
    shift : LSB에서 버릴 비트 수. 명세상 10 고정.

    Returns
    -------
    int8 ndarray, acc와 같은 shape
    """
    assert acc.dtype.kind == 'i', f"acc must be signed int, got {acc.dtype}"
    shifted = acc >> shift              # arithmetic shift (signed)
    clipped = np.clip(shifted, -128, 127)
    return clipped.astype(np.int8)


def _im2col_3x3(x: np.ndarray) -> np.ndarray:
    """
    3×3, stride 1, no pad 컨볼루션용 im2col.

    Parameters
    ----------
    x : (N, C, H, W) int8 또는 int32

    Returns
    -------
    cols : (N, H-2, W-2, C*9) — 출력 픽셀별로 receptive field 9개를 채널 묶어서 펼침.
           dtype은 input과 동일. matmul 시 int32로 캐스팅.

    구현
    ----
    stride tricks로 메모리 복사 없이 view 생성 후, contiguous로 한 번만 복사.
    M4 Max에서 numpy stride_tricks는 안정적이고 빠름.
    """
    N, C, H, W = x.shape
    out_h, out_w = H - 2, W - 2
    # (N, C, out_h, out_w, 3, 3) view
    s_n, s_c, s_h, s_w = x.strides
    shape = (N, C, out_h, out_w, 3, 3)
    strides = (s_n, s_c, s_h, s_w, s_h, s_w)
    patches = np.lib.stride_tricks.as_strided(x, shape=shape, strides=strides, writeable=False)
    # (N, out_h, out_w, C, 3, 3) → (N, out_h, out_w, C*9)
    cols = patches.transpose(0, 2, 3, 1, 4, 5).reshape(N, out_h, out_w, C * 9)
    return np.ascontiguousarray(cols)


def conv2d_int8(x_int8: np.ndarray, w_int8: np.ndarray, *, shift: int = 10) -> np.ndarray:
    """
    명세 준수 3×3 stride-1 no-pad 컨볼루션 + INT8 saturation.

    Parameters
    ----------
    x_int8 : (N, Cin, H, W) int8
    w_int8 : (Cout, Cin, 3, 3) int8
    shift  : truncate_satdown에 전달 (기본 10)

    Returns
    -------
    y_int8 : (N, Cout, H-2, W-2) int8

    구현
    ----
    1. im2col: x → (N, Ho, Wo, Cin*9)
    2. weight reshape: w → (Cout, Cin*9), int32 캐스팅
    3. matmul: cols @ w.T → (N, Ho, Wo, Cout) int32
    4. transpose → (N, Cout, Ho, Wo)
    5. truncate_satdown

    numpy matmul은 Accelerate (BLAS)로 multi-threaded. M4 Max P-core 전부 활용.
    """
    assert x_int8.dtype == np.int8 and w_int8.dtype == np.int8
    N, Cin, H, W = x_int8.shape
    Cout, Cin_w, KH, KW = w_int8.shape
    assert Cin == Cin_w and KH == 3 and KW == 3

    cols = _im2col_3x3(x_int8).astype(np.int32)               # (N, Ho, Wo, Cin*9)
    w_flat = w_int8.reshape(Cout, Cin * 9).astype(np.int32)   # (Cout, Cin*9)

    acc = cols @ w_flat.T                                      # (N, Ho, Wo, Cout) int32
    acc = acc.transpose(0, 3, 1, 2)                            # (N, Cout, Ho, Wo)

    return truncate_satdown(acc, shift=shift)


def relu_int8(x: np.ndarray) -> np.ndarray:
    """
    INT8 ReLU. 음수 → 0. dtype 유지.

    명세에는 ReLU와 saturation 순서가 "conv → sat → ReLU"인지 "conv → ReLU → sat"인지
    명시되어 있지 않지만, 결과는 동일:
        - acc가 음수 → shift 후 여전히 음수 → clip(-128,127) → 음수 INT8 → ReLU → 0
        - acc가 음수 → ReLU 적용 못함 (int32 단계) → ...
    우리는 "Conv (acc+sat→int8) → ReLU(int8)" 순서로 진행 (forward에서).
    """
    return np.maximum(x, 0).astype(np.int8)


def maxpool2x2_int8(x: np.ndarray) -> np.ndarray:
    """
    2×2 stride-2 max pooling, INT8.

    Parameters
    ----------
    x : (N, C, H, W) int8, H와 W는 짝수

    Returns
    -------
    (N, C, H/2, W/2) int8

    구현
    ----
    reshape trick: (N, C, H/2, 2, W/2, 2) → max over axis (3, 5).
    """
    N, C, H, W = x.shape
    assert H % 2 == 0 and W % 2 == 0
    reshaped = x.reshape(N, C, H // 2, 2, W // 2, 2)
    pooled = reshaped.max(axis=(3, 5))
    return pooled.astype(np.int8)


def flatten_chw(x: np.ndarray) -> np.ndarray:
    """
    (N, C, H, W) → (N, C*H*W) numpy C-order.

    명세 Fig.3대로:
        idx = c * H*W + h * W + w
    한 채널의 H×W가 W 빠르게 변하며 144개 펼쳐지고, 다음 채널이 이어짐.
    numpy 기본 .reshape(N, -1)이 C-order이므로 그대로 사용.
    """
    N = x.shape[0]
    return x.reshape(N, -1)


def fc_int8(x_int8: np.ndarray, w_int8: np.ndarray, *, shift: int = 10) -> np.ndarray:
    """
    INT8 Fully Connected layer + saturation.

    Parameters
    ----------
    x_int8 : (N, In) int8
    w_int8 : (Out, In) int8 (명세대로 row-major: FC weight shape = (10, 2304))
    shift  : 10

    Returns
    -------
    (N, Out) int8
    """
    assert x_int8.dtype == np.int8 and w_int8.dtype == np.int8
    acc = x_int8.astype(np.int32) @ w_int8.astype(np.int32).T   # (N, Out) int32
    return truncate_satdown(acc, shift=shift)


# =============================================================================
# 상위 forward
# =============================================================================

# 시그니처 타입 별칭 (가독성용)
ConvFn = Callable[..., np.ndarray]
FcFn = Callable[..., np.ndarray]


def forward(
    images_int8: np.ndarray,
    w1_int8: np.ndarray,
    w2_int8: np.ndarray,
    wfc_int8: np.ndarray,
    *,
    conv1_fn: ConvFn = conv2d_int8,
    conv2_fn: ConvFn = conv2d_int8,
    fc_fn: FcFn = fc_int8,
    shift: int = 10,
) -> np.ndarray:
    """
    명세 CNN을 한 번에 inference. 시나리오 교체용 fn 주입 가능.

    Parameters
    ----------
    images_int8 : (N, 1, 28, 28) int8 — 입력 이미지 (data_int8/input.npy)
    w1_int8     : (8, 1, 3, 3)   int8 — Conv1 weight (layer1_0_weight.npy)
    w2_int8     : (16, 8, 3, 3)  int8 — Conv2 weight (layer2_0_weight.npy)
    wfc_int8    : (10, 2304)     int8 — FC weight (fc1_weight.npy)
    conv1_fn    : Conv1을 수행할 함수. 시그니처 conv1_fn(x, w, *, shift) → int8.
                  기본은 conv2d_int8 (Direct).
    conv2_fn    : Conv2를 수행할 함수. 시나리오 3+에서 Winograd로 교체.
    fc_fn       : FC를 수행할 함수. 보통 fc_int8 고정.
    shift       : Saturation shift. 명세상 10.

    Returns
    -------
    logit_int8 : (N, 10) int8 — argmax(axis=1)이 최종 예측 클래스.

    Pipeline
    --------
    Conv1 → ReLU → Conv2 → ReLU → MaxPool2x2 → Flatten(C-order) → FC

    주의
    ----
    - ReLU는 saturation 이후의 int8에 적용 (음수 → 0). 명세상 순서가 명시되어 있지
      않으나 결과 동일.
    - Quantization (weight를 INT4/Log2로 변환 등)은 이 함수 밖에서 미리 처리하여
      w1/w2/wfc 인자로 전달. forward 내부에는 분기 없음.
    """
    # --- Conv1 + ReLU ---
    fmap1 = conv1_fn(images_int8, w1_int8, shift=shift)        # (N, 8, 26, 26) int8
    fmap1 = relu_int8(fmap1)

    # --- Conv2 + ReLU ---
    fmap2 = conv2_fn(fmap1, w2_int8, shift=shift)              # (N, 16, 24, 24) int8
    fmap2 = relu_int8(fmap2)

    # --- MaxPool 2x2 ---
    fmap3 = maxpool2x2_int8(fmap2)                             # (N, 16, 12, 12) int8

    # --- Flatten (C-order: c*144 + h*12 + w) ---
    flat = flatten_chw(fmap3)                                  # (N, 2304) int8

    # --- FC ---
    logit = fc_fn(flat, wfc_int8, shift=shift)                 # (N, 10) int8

    return logit


# =============================================================================
# 유틸리티 (시나리오 스크립트가 쓰기 좋게)
# =============================================================================

def load_assignment_data(data_dir: str = "../data_int8") -> dict:
    """
    과제 .npy 5개 일괄 로드.

    Returns
    -------
    dict with keys: 'input', 'output', 'w1', 'w2', 'wfc'
    """
    import os
    d = lambda f: os.path.join(data_dir, f)
    return {
        'input':  np.load(d('input.npy')),             # (10000, 1, 28, 28) int8
        'output': np.load(d('output.npy')),            # (10000, 10) int8 expected logit
        'w1':     np.load(d('layer1_0_weight.npy')),   # (8, 1, 3, 3) int8
        'w2':     np.load(d('layer2_0_weight.npy')),   # (16, 8, 3, 3) int8
        'wfc':    np.load(d('fc1_weight.npy')),        # (10, 2304) int8
    }


def bit_exact_match(my_logit: np.ndarray, expected_logit: np.ndarray) -> dict:
    """
    Bit-exact 검증. 명세 reference와 100% 일치해야 INT8 Direct가 정확.

    Returns
    -------
    dict {
        'per_image_match': (N,) bool,  # 이미지별로 10개 logit 모두 일치하는지
        'total_match_rate': float,     # 전체 비트 일치 비율 (모든 logit 원소 기준)
        'image_match_rate': float,     # 이미지 단위 일치 비율
    }
    """
    assert my_logit.shape == expected_logit.shape
    elem_match = (my_logit == expected_logit)                  # (N, 10) bool
    per_image = elem_match.all(axis=1)                         # (N,) bool
    return {
        'per_image_match': per_image,
        'total_match_rate': float(elem_match.mean()),
        'image_match_rate': float(per_image.mean()),
    }
