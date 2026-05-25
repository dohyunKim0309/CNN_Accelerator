import numpy as np

# -------------------------------------------------------
# 파일 경로 설정 (스크립트 디렉터리에서 실행한다고 가정)
# -------------------------------------------------------
INPUT_FILE       = "../../data/npy/input.npy"
WEIGHT1_FILE     = "../../data/npy/layer1_0_weight.npy"
WEIGHT2_FILE     = "../../data/npy/layer2_0_weight.npy"
OUTPUT_HEX_BYTE  = "../../data/hex_layer_by_layer/conv2_output_processed.hex"   # 기존: 1 byte/line
OUTPUT_HEX_BRAM  = "../../data/hex_layer_by_layer/conv2_output_c2pool.hex"      # 신규: c2pool BRAM expected format

# -------------------------------------------------------
# 파일 로드
# -------------------------------------------------------
inp     = np.load(INPUT_FILE)    # (N, 1, 28, 28), int8
weight1 = np.load(WEIGHT1_FILE)  # (8, 1, 3, 3),   int8
weight2 = np.load(WEIGHT2_FILE)  # (16, 8, 3, 3),  int8

print(f"[Load] input shape   : {inp.shape},       dtype={inp.dtype}")
print(f"[Load] weight1 shape : {weight1.shape},   dtype={weight1.dtype}")
print(f"[Load] weight2 shape : {weight2.shape}, dtype={weight2.dtype}")

# -------------------------------------------------------
# 첫 번째 이미지 선택
# -------------------------------------------------------
IMAGE_IDX = 0
x = inp[IMAGE_IDX]  # (1, 28, 28)
print(f"\n[Select] image index={IMAGE_IDX}, shape={x.shape}")

# -------------------------------------------------------
# ========== Conv1 Pipeline ==========
# -------------------------------------------------------

# Step 1-1: Conv2D (padding=0, stride=1)
out_ch, in_ch, kH, kW = weight1.shape
H, W = x.shape[1], x.shape[2]
oH, oW = H - kH + 1, W - kW + 1  # 26, 26

conv1_out = np.zeros((out_ch, oH, oW), dtype=np.int32)
for oc in range(out_ch):
    for ic in range(in_ch):
        for i in range(oH):
            for j in range(oW):
                patch = x[ic, i:i+kH, j:j+kW].astype(np.int32)
                k     = weight1[oc, ic].astype(np.int32)
                conv1_out[oc, i, j] += np.sum(patch * k)

print(f"\n[Conv1]       shape={conv1_out.shape}  min={conv1_out.min()}  max={conv1_out.max()}")

# Step 1-2: >> 10
shifted1 = conv1_out >> 10
print(f"[>> 10]       min={shifted1.min()}  max={shifted1.max()}")

# Step 1-3: Saturation
saturated1 = np.clip(shifted1, -128, 127).astype(np.int8)
print(f"[Saturation]  min={saturated1.min()}  max={saturated1.max()}")

# Step 1-4: ReLU
relu1 = np.maximum(saturated1.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU]        min={relu1.min()}  max={relu1.max()}")

# -------------------------------------------------------
# ========== Conv2 Pipeline ==========
# -------------------------------------------------------

# Step 2-1: Conv2D (padding=0, stride=1)
out_ch2, in_ch2, kH2, kW2 = weight2.shape
H2, W2 = relu1.shape[1], relu1.shape[2]
oH2, oW2 = H2 - kH2 + 1, W2 - kW2 + 1  # 24, 24

conv2_out = np.zeros((out_ch2, oH2, oW2), dtype=np.int32)
for oc in range(out_ch2):
    for ic in range(in_ch2):
        for i in range(oH2):
            for j in range(oW2):
                patch = relu1[ic, i:i+kH2, j:j+kW2].astype(np.int32)
                k     = weight2[oc, ic].astype(np.int32)
                conv2_out[oc, i, j] += np.sum(patch * k)

print(f"\n[Conv2]       shape={conv2_out.shape}  min={conv2_out.min()}  max={conv2_out.max()}")

# Step 2-2: >> 10
shifted2 = conv2_out >> 10
print(f"[>> 10]       min={shifted2.min()}  max={shifted2.max()}")

# Step 2-3: Saturation
saturated2 = np.clip(shifted2, -128, 127).astype(np.int8)
print(f"[Saturation]  min={saturated2.min()}  max={saturated2.max()}")

# Step 2-4: ReLU
relu2 = np.maximum(saturated2.astype(np.int32), 0).astype(np.int8)
print(f"[ReLU]        min={relu2.min()}  max={relu2.max()}")

# -------------------------------------------------------
# Output 1: 기존 byte-level hex (1 byte/line, oc-major flatten)
#   - 인간 inspection 용
#   - 순서: oc=0 (h-w raster) → oc=1 → ... → oc=15
# -------------------------------------------------------
with open(OUTPUT_HEX_BYTE, "w") as f:
    for b in relu2.flatten().tobytes():
        f.write(f"{b:02X}\n")
print(f"\n[Write] {OUTPUT_HEX_BYTE}  ({relu2.size} lines, 1 byte/line)")

# -------------------------------------------------------
# Output 2: c2pool BRAM expected format (128-bit/line, write_addr 순서)
#   - conv2_engine 의 c2pool BRAM Port A write 결과 비교용
#   - Width 128-bit = 16 OC × 8b packed; OC 0 = LSB (lowest 8 bits)
#   - write_addr 카운터는 c2pool_we pulse 마다 +1, 0..575 raster (h*24 + w)
#   - 본 file 은 576 lines (valid output 만). testbench 가 c2pool_mem[0..575] 와 비교.
#
#   Mapping:
#     - line[N] for N ∈ 0..575: N = h*24 + w, packed 16 OC bytes
# -------------------------------------------------------
with open(OUTPUT_HEX_BRAM, "w") as f:
    for N in range(576):
        h = N // 24
        w = N % 24
        word = 0
        for oc in range(16):
            byte = int(relu2[oc, h, w]) & 0xFF
            word |= (byte << (oc * 8))
        f.write(f"{word:032X}\n")
print(f"[Write] {OUTPUT_HEX_BRAM}  (576 lines, 128-bit/line, c2pool write_addr 순)")