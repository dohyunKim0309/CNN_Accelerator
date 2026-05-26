"""
Conv1 검증 스크립트
  - Python으로 conv1 결과 계산 (reference)
  - 시뮬레이션 출력(conv1_out.hex) 과 비교
"""

import numpy as np

NPY_DIR = r"C:\Users\111eh\AppData\Local\Temp\BNZ.6a153c8824bc5259"
SIM_HEX = r"C:\Users\111eh\INTELLIGENT_SYSTEM_DESIGN\assign4_code\CNN_Accelerator\conv1_out.hex"
IMG_IDX = 0

# ── 1. Python reference 계산 ──────────────────────────────────────────────────
weight = np.load(f"{NPY_DIR}/layer1_0_weight.npy")   # (8, 1, 3, 3) int8
inp    = np.load(f"{NPY_DIR}/input.npy")              # (10000,1,28,28) int8
img    = inp[IMG_IDX, 0].astype(np.int32)             # (28,28)

OC, IC, KH, KW = weight.shape   # 8,1,3,3
OUT_H, OUT_W = 26, 26

ref = np.zeros((OC, OUT_H, OUT_W), dtype=np.int32)
for oc in range(OC):
    for r in range(OUT_H):
        for c in range(OUT_W):
            acc = 0
            for kr in range(KH):
                for kc in range(KW):
                    acc += int(img[r+kr, c+kc]) * int(weight[oc, 0, kr, kc])
            # arithmetic right shift 10 + ReLU + saturate [0,127]
            shifted = acc >> 10
            ref[oc, r, c] = max(0, min(127, shifted))

ref = ref.astype(np.int8)
print(f"[Python] ref shape: {ref.shape}, min={ref.min()}, max={ref.max()}")

# ── 2. 시뮬레이션 결과 로드 ───────────────────────────────────────────────────
raw = []
with open(SIM_HEX, "r") as f:
    for line in f:
        line = line.strip()
        if line:
            val = int(line, 16)
            # 8-bit unsigned → signed
            raw.append(val if val < 128 else val - 256)

raw = np.array(raw, dtype=np.int8).reshape(8, 26, 26)
print(f"[Sim]    sim shape: {raw.shape}, min={raw.min()}, max={raw.max()}")

# ── 3. 비교 ───────────────────────────────────────────────────────────────────
match = np.array_equal(ref, raw)
diff  = ref.astype(np.int32) - raw.astype(np.int32)

print(f"\n=== 결과 {'✅ 일치' if match else '❌ 불일치'} ===")
print(f"  최대 오차: {np.abs(diff).max()}")
print(f"  불일치 픽셀 수: {np.sum(diff != 0)} / {8*26*26}")

if not match:
    idx = np.argwhere(diff != 0)
    print("\n  [처음 5개 불일치]")
    print(f"  {'ch':>3} {'row':>4} {'col':>4}  {'ref':>5}  {'sim':>5}  {'diff':>5}")
    for i in idx[:5]:
        oc, r, c = i
        print(f"  {oc:3d} {r:4d} {c:4d}  {ref[oc,r,c]:5d}  {raw[oc,r,c]:5d}  {diff[oc,r,c]:5d}")
