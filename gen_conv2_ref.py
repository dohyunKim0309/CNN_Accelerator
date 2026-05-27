import numpy as np

# ============================================================
# 1. conv1 출력 로드 (conv2 입력)
#    형식: ch0[0..675], ch1[0..675], ..., ch7[0..675]
#    r = row*26 + col
# ============================================================
with open("python_conv1_ref.hex", "r") as f:
    lines = [l.strip() for l in f if l.strip()]

assert len(lines) == 8 * 676, f"Expected 5408, got {len(lines)}"

conv1_vals = np.array([int(x, 16) for x in lines], dtype=np.int32)
input_tensor = conv1_vals.reshape(8, 26, 26)   # [IC, H, W]

# ============================================================
# 2. conv2 가중치 로드
#    shape: (16, 8, 3, 3) = (OC, IC, KH, KW), dtype int8
# ============================================================
weights = np.load(r"C:\Users\111eh\AppData\Local\Temp\BNZ.6a15946226137b87\layer2_0_weight.npy").astype(np.int32)  # (16, 8, 3, 3)

# ============================================================
# 3. Conv2 연산 (valid, no padding → 24x24 출력)
#    sum[oc, row, col] = Σ weight[oc,ic,kh,kw] * input[ic, row+kh, col+kw]
# ============================================================
output = np.zeros((16, 24, 24), dtype=np.int32)

for oc in range(16):
    for ic in range(8):
        for kh in range(3):
            for kw in range(3):
                output[oc] += weights[oc, ic, kh, kw] * input_tensor[ic, kh:kh+24, kw:kw+24]

# ============================================================
# 4. Truncate (>>10) + ReLU + Saturate [0, 127]
#    하드웨어 conv2_truncate_relu 동작과 동일
# ============================================================
output_shifted = output >> 10        # 산술 우측 시프트
output_clipped = np.clip(output_shifted, 0, 127).astype(np.uint8)

# ============================================================
# 5. 저장
#    형식: ch0[0..575], ch1[0..575], ..., ch15[0..575]
#    r = row*24 + col
# ============================================================
with open("python_conv2_ref.hex", "w") as f:
    for ch in range(16):
        for r in range(576):   # 24*24 = 576
            row = r // 24
            col = r % 24
            f.write(f"{output_clipped[ch, row, col]:02x}\n")

# ============================================================
# 6. 통계 출력
# ============================================================
print(f"Output shape : {output_clipped.shape}")
print(f"Total pixels : {16 * 576}")
print(f"Non-zero     : {np.count_nonzero(output_clipped)}")
print(f"Max value    : {output_clipped.max()}")
print(f"Saved        : python_conv2_ref.hex ({16*576} lines)")

# 채널별 비영값 확인
for ch in range(16):
    nz = np.count_nonzero(output_clipped[ch])
    print(f"  ch{ch:02d} non-zero: {nz} / 576")
