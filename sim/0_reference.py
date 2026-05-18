"""
0_reference.py
==============

시나리오 #1: INT8 Direct 컨볼루션 (명세 그대로) reference.

목적
----
1. reference_core.forward()로 10K MNIST 이미지를 INT8 Direct로 추론.
2. expected output.npy와 **비트 일치** 검증 (목표 100%). 이게 통과해야 명세를
   비트 단위로 정확히 시뮬레이트하고 있다는 증명. 후속 시나리오의 baseline.
3. 절대 정확도 (argmax vs MNIST true label) 계산.
4. Reference 일치율 (argmax vs expected logit의 argmax) 계산. INT8 Direct는
   둘이 같아야 정상 (expected가 우리 reference이므로).

산출
----
표준 출력에 두 지표 + bit-match 상세 표시.

의존성
------
- numpy
- torchvision (MNIST true label 다운로드용). 첫 실행 시 인터넷 필요.
  다운로드 캐시: ../data_int8/mnist_cache/  (data_int8 폴더 재사용)
"""

from __future__ import annotations

import os
import sys
import time
import numpy as np

# reference_core.py는 같은 디렉토리
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_core as rc


# =============================================================================
# MNIST true label 로딩
# =============================================================================

def load_mnist_test_labels(cache_dir: str) -> np.ndarray:
    """
    torchvision으로 MNIST 테스트셋 라벨 10K개 로드.

    과제 input.npy의 이미지가 MNIST test split과 동일 순서라고 가정.
    (명세상 10K = MNIST test set 크기와 일치)

    Returns
    -------
    labels : (10000,) int64 — 0~9
    """
    try:
        from torchvision.datasets import MNIST
    except ImportError as e:
        raise ImportError(
            "torchvision이 필요합니다. `pip install torchvision` 후 재실행.\n"
            "또는 MNIST 라벨을 별도로 받아 numpy로 저장한 뒤 load하도록 수정."
        ) from e

    os.makedirs(cache_dir, exist_ok=True)
    # train=False → test split (10K). download=True → 이미 있으면 skip.
    ds = MNIST(root=cache_dir, train=False, download=True)
    # ds.targets은 torch.Tensor; numpy로
    labels = ds.targets.numpy().astype(np.int64)
    assert labels.shape == (10000,), f"unexpected MNIST test shape: {labels.shape}"
    return labels


# =============================================================================
# 메인
# =============================================================================

def main():
    # --- 경로 설정 ---
    here = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.normpath(os.path.join(here, '..', 'data_int8'))
    mnist_cache = os.path.join(data_dir, 'mnist_cache')

    # --- 데이터 로드 ---
    print("=" * 60)
    print("Scenario #1: INT8 Direct (reference)")
    print("=" * 60)

    print(f"[load] assignment .npy from {data_dir}")
    data = rc.load_assignment_data(data_dir=data_dir)
    images   = data['input']     # (10000, 1, 28, 28) int8
    expected = data['output']    # (10000, 10) int8
    w1, w2, wfc = data['w1'], data['w2'], data['wfc']

    print(f"  input   : shape={images.shape},   dtype={images.dtype},"
          f"   range=[{images.min()}, {images.max()}]")
    print(f"  output  : shape={expected.shape}, dtype={expected.dtype},"
          f" range=[{expected.min()}, {expected.max()}]")
    print(f"  w1 (L1) : shape={w1.shape},   dtype={w1.dtype}")
    print(f"  w2 (L2) : shape={w2.shape},   dtype={w2.dtype}")
    print(f"  wfc (FC): shape={wfc.shape},     dtype={wfc.dtype}")

    print(f"[load] MNIST true labels (test split, 10K) from torchvision")
    print(f"       cache: {mnist_cache}")
    true_labels = load_mnist_test_labels(mnist_cache)
    print(f"  labels  : shape={true_labels.shape}, dtype={true_labels.dtype}")

    # --- Forward (INT8 Direct, 명세 그대로) ---
    print("\n[forward] running rc.forward() on 10K images ...")
    t0 = time.time()
    my_logit = rc.forward(images, w1, w2, wfc)   # 모든 conv/fc_fn 기본 = INT8 Direct
    dt = time.time() - t0
    print(f"  done in {dt:.2f} s ({10000/dt:.0f} img/s)")
    print(f"  my_logit: shape={my_logit.shape}, dtype={my_logit.dtype},"
          f" range=[{my_logit.min()}, {my_logit.max()}]")

    # --- 검증 1: bit-exact match with expected output ---
    print("\n[verify] bit-exact match vs expected output.npy")
    match = rc.bit_exact_match(my_logit, expected)
    print(f"  per-element match rate : {match['total_match_rate']*100:.4f}%  "
          f"(target: 100.0000%)")
    print(f"  per-image  match rate  : {match['image_match_rate']*100:.4f}%  "
          f"(target: 100.0000%)")

    if match['image_match_rate'] < 1.0:
        # 불일치 이미지의 첫 몇 개 진단
        mismatches = np.where(~match['per_image_match'])[0]
        print(f"  MISMATCH: {len(mismatches)} images differ from reference.")
        print(f"  first 5 mismatched indices: {mismatches[:5].tolist()}")
        for idx in mismatches[:3]:
            print(f"    img {idx}: my={my_logit[idx].tolist()}")
            print(f"           ref={expected[idx].tolist()}")
            diff = my_logit[idx].astype(np.int32) - expected[idx].astype(np.int32)
            print(f"           diff={diff.tolist()}")
    else:
        print("  OK: 100% bit-exact match. Reference established.")

    # --- 검증 2: 절대 정확도 (vs MNIST true label) ---
    print("\n[accuracy] vs MNIST true labels")
    my_pred  = my_logit.argmax(axis=1)
    ref_pred = expected.argmax(axis=1)

    abs_acc       = (my_pred == true_labels).mean()
    ref_acc       = (ref_pred == true_labels).mean()
    my_vs_ref_acc = (my_pred == ref_pred).mean()

    print(f"  absolute accuracy (my   vs true) : {abs_acc*100:.4f}%")
    print(f"  absolute accuracy (ref  vs true) : {ref_acc*100:.4f}%   "
          f"# 명세 INT8 quantized network의 본질적 상한")
    print(f"  reference agreement (my vs ref)  : {my_vs_ref_acc*100:.4f}%   "
          f"# INT8 Direct는 100% 기대")

    # --- 종합 ---
    print("\n" + "=" * 60)
    if match['image_match_rate'] == 1.0:
        print("PASS: INT8 Direct reference 검증 완료. 후속 시나리오 진행 가능.")
    else:
        print("FAIL: bit-exact 불일치. truncate/flatten/순서 규칙 재검토 필요.")
    print("=" * 60)


if __name__ == "__main__":
    main()
