"""
.npy → .mem 변환 스크립트 (테스트벤치 $readmemh 용)
  - conv1_weight.mem : 64 x 32-bit (6-bit 주소, addr 0~35만 유효)
  - input_image.mem  : 784 x 8-bit
"""

import numpy as np

NPY_DIR = r"C:\Users\111eh\AppData\Local\Temp\BNZ.6a153c8824bc5259"
OUT_DIR = r"C:\Users\111eh\INTELLIGENT_SYSTEM_DESIGN\assign4_code\CNN_Accelerator"
IMG_IDX = 0

def pack_weights(W0: int, W1: int) -> int:
    return (int(W1) * (1 << 17) + int(W0)) & 0x1FFFFFF

# ── conv1_weight.mem ──────────────────────────────────────────────────────────
w = np.load(f"{NPY_DIR}/layer1_0_weight.npy")  # (8, 1, 3, 3)

entries = []
for (oc0, oc1) in [(0,1), (2,3), (4,5), (6,7)]:
    for k in range(9):
        kr, kc = k // 3, k % 3
        entries.append(pack_weights(int(w[oc0, 0, kr, kc]),
                                    int(w[oc1, 0, kr, kc])))

# 64 depth (6-bit 주소 공간), 나머지는 0으로 패딩
entries += [0] * (64 - len(entries))

with open(f"{OUT_DIR}/conv1_weight.mem", "w") as f:
    for e in entries:
        f.write(f"{e & 0xFFFFFFFF:08x}\n")
print(f"conv1_weight.mem 생성 완료 (64 entries)")

# ── input_image.mem ───────────────────────────────────────────────────────────
inp = np.load(f"{NPY_DIR}/input.npy")          # (10000, 1, 28, 28)
img = inp[IMG_IDX, 0].flatten().astype(np.uint8)

with open(f"{OUT_DIR}/input_image.mem", "w") as f:
    for px in img:
        f.write(f"{px:02x}\n")
print(f"input_image.mem 생성 완료 (784 entries, image index={IMG_IDX})")
