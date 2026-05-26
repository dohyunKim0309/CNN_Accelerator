"""
.npy → .coe 변환 스크립트 (Vivado BRAM 초기화용)
  - conv1_weight.coe : weight_loader가 읽는 36-entry BRAM
  - input_image.coe  : conv1_engine이 읽는 입력 이미지 BRAM (8-bit PortB)
"""

import numpy as np

# ── 파일 경로 설정 ─────────────────────────────────────────────────────────────
NPY_DIR   = r"C:\Users\111eh\AppData\Local\Temp\BNZ.6a153c8824bc5259"
OUT_DIR   = r"C:\Users\111eh\INTELLIGENT_SYSTEM_DESIGN\assign4_code\CNN_Accelerator"
IMG_IDX   = 0   # 사용할 이미지 인덱스 (0 ~ 9999)

# ── 헬퍼 ──────────────────────────────────────────────────────────────────────
def pack_weights(W0: int, W1: int) -> int:
    """
    packed_w[24:0] = W1 * 2^17 + W0  (pe_cell DSP 트릭)
    두 개의 INT8 weight를 25비트에 패킹 → 32비트 BRAM 워드로 저장
    """
    packed = int(W1) * (1 << 17) + int(W0)
    return packed & 0x1FFFFFF   # 25-bit two's complement 마스크


def write_coe(filename: str, entries: list, radix: int = 16, bits: int = 32):
    """entries 리스트를 .coe 파일로 저장"""
    fmt = f"0{bits // 4}x" if radix == 16 else "d"
    with open(filename, "w") as f:
        f.write(f"memory_initialization_radix={radix};\n")
        f.write("memory_initialization_vector=\n")
        for i, e in enumerate(entries):
            val = format(e & ((1 << bits) - 1), fmt)
            sep = "," if i < len(entries) - 1 else ";"
            f.write(val + sep + "\n")
    print(f"생성 완료: {filename}  ({len(entries)} entries)")


# ═══════════════════════════════════════════════════════════════════════════════
# 1. conv1_weight.coe  ─ weight_loader용 (36 × 32-bit)
#
#   BRAM 레이아웃:
#     addr  0~ 8  →  pe[0~8].w_regs[0]   packed(W0=oc0[k], W1=oc1[k])
#     addr  9~17  →  pe[9~17].w_regs[0]  packed(W0=oc2[k], W1=oc3[k])
#     addr 18~26  →  pe[0~8].w_regs[1]   packed(W0=oc4[k], W1=oc5[k])
#     addr 27~35  →  pe[9~17].w_regs[1]  packed(W0=oc6[k], W1=oc7[k])
#
#   k (0~8) → kr = k//3, kc = k%3
# ═══════════════════════════════════════════════════════════════════════════════
w = np.load(f"{NPY_DIR}/layer1_0_weight.npy")   # shape: (8, 1, 3, 3)
print(f"Conv1 weight shape: {w.shape}, dtype: {w.dtype}")

oc_pairs = [(0,1), (2,3), (4,5), (6,7)]   # (W0_oc, W1_oc) per 구간

entries_w = []
for (oc0, oc1) in oc_pairs:
    for k in range(9):
        kr, kc = k // 3, k % 3
        W0 = int(w[oc0, 0, kr, kc])
        W1 = int(w[oc1, 0, kr, kc])
        entries_w.append(pack_weights(W0, W1))

write_coe(f"{OUT_DIR}/conv1_weight.coe", entries_w, radix=16, bits=32)


# ═══════════════════════════════════════════════════════════════════════════════
# 2. input_image.coe  ─ in_bram용 (784 × 8-bit)
#
#   입력: (10000, 1, 28, 28) INT8, row-major 순서
#   addr = row * 28 + col  (0 ~ 783)
# ═══════════════════════════════════════════════════════════════════════════════
inp = np.load(f"{NPY_DIR}/input.npy")            # shape: (10000, 1, 28, 28)
print(f"Input shape: {inp.shape}, dtype: {inp.dtype}")

img = inp[IMG_IDX, 0].flatten().astype(np.uint8) # (784,) unsigned for hex

write_coe(f"{OUT_DIR}/input_image.coe", img.tolist(), radix=16, bits=8)

print(f"\n사용 이미지 인덱스: {IMG_IDX}")
print("두 .coe 파일을 Vivado BRAM IP의 'Initialization' 탭에 각각 지정하세요.")
