import numpy as np
import os

# -------------------------------------------------------
# 파일 경로 설정 (스크립트 디렉터리에서 실행한다고 가정)
# -------------------------------------------------------
INPUT_FILE       = "../../data/npy/input.npy"
WEIGHT_FILE      = "../../data/npy/layer1_0_weight.npy"
OUTPUT_HEX_BYTE  = "../../data/hex_layer_by_layer/conv1_output_processed.hex"   # 기존: 1 byte/line
OUTPUT_HEX_BRAM  = "../../data/hex_layer_by_layer/conv1_output_c1c2.hex"        # 신규: c1c2 BRAM init format

# -------------------------------------------------------
# 파일 로드
# -------------------------------------------------------
inp    = np.load(INPUT_FILE)   # (N, 1, 28, 28), int8
weight = np.load(WEIGHT_FILE)  # (8, 1, 3, 3),   int8

print(f"[Load] input shape  : {inp.shape},    dtype={inp.dtype}")
print(f"[Load] weight shape : {weight.shape}, dtype={weight.dtype}")

# -------------------------------------------------------
# 첫 번째 이미지 선택
# -------------------------------------------------------
IMAGE_IDX = 0
x = inp[IMAGE_IDX]  # (1, 28, 28)
print(f"[Select] image index={IMAGE_IDX}, shape={x.shape}")

# -------------------------------------------------------
# Step 1: Conv2D  (padding=0, stride=1)
# -------------------------------------------------------
out_ch, in_ch, kH, kW = weight.shape
H, W = x.shape[1], x.shape[2]
oH = H - kH + 1
oW = W - kW + 1

conv_out = np.zeros((out_ch, oH, oW), dtype=np.int32)
for oc in range(out_ch):
    for ic in range(in_ch):
        for i in range(oH):
            for j in range(oW):
                patch = x[ic, i:i+kH, j:j+kW].astype(np.int32)
                k     = weight[oc, ic].astype(np.int32)
                conv_out[oc, i, j] += np.sum(patch * k)

print(f"[Conv]        shape={conv_out.shape}  min={conv_out.min()}  max={conv_out.max()}")

# -------------------------------------------------------
# Step 2: LSB 10bit 제거 (arithmetic right shift by 10)
# -------------------------------------------------------
shifted = conv_out >> 10
print(f"[>> 10]       min={shifted.min()}  max={shifted.max()}")

# -------------------------------------------------------
# Step 3: Saturation → int8 (-128 ~ 127)
# -------------------------------------------------------
saturated = np.clip(shifted, -128, 127).astype(np.int8)
print(f"[Saturation]  min={saturated.min()}  max={saturated.max()}")

# -------------------------------------------------------
# Step 4: ReLU
# -------------------------------------------------------
relu_out = np.maximum(saturated.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU]        min={relu_out.min()}  max={relu_out.max()}")

# -------------------------------------------------------
# Output 1: 기존 byte-level hex (1 byte/line, oc-major flatten)
#   - 인간 inspection 용
#   - 순서: oc=0 (h-w raster) → oc=1 → ... → oc=7
# -------------------------------------------------------
with open(OUTPUT_HEX_BYTE, "w") as f:
    for b in relu_out.flatten().tobytes():
        f.write(f"{b:02X}\n")
print(f"\n[Write] {OUTPUT_HEX_BYTE}  ({relu_out.size} lines, 1 byte/line)")

# -------------------------------------------------------
# Output 2: c1c2 BRAM init format (64-bit/line, h*32+w addr 순서)
#   - conv2_engine 의 c1c2 BRAM Port B read 와 정합
#   - Width 64-bit = 8 IC × 8b packed; IC 0 = LSB (lowest 8 bits)
#   - Addr 11-bit = {bank_sel, row[4:0], col[4:0]} → 1 bank 당 1024 entry
#   - 본 file 은 1 bank (= 1 image) 분. 다른 bank 는 testbench 가 별도 init.
#
#   Mapping:
#     - h ∈ 0..25, w ∈ 0..25: line[h*32 + w] = packed 8 IC bytes
#     - w ∈ 26..31 (gap): line = 0 (col_cnt 가 26..31 도달 안 함, 안전 padding)
#     - h ∈ 26..31 (out-of-range): line = 0
#   → 총 1024 lines
# -------------------------------------------------------
with open(OUTPUT_HEX_BRAM, "w") as f:
    for h in range(32):
        for w in range(32):
            if h < 26 and w < 26:
                word = 0
                for ic in range(8):
                    byte = int(relu_out[ic, h, w]) & 0xFF
                    word |= (byte << (ic * 8))
                f.write(f"{word:016X}\n")
            else:
                f.write("0000000000000000\n")
print(f"[Write] {OUTPUT_HEX_BRAM}  (1024 lines, 64-bit/line, c1c2 BRAM addr 순)")