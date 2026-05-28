import numpy as np

# ============================================================
# 1. conv2 출력 로드 (maxpool 입력)
#    형식: ch0[0..575], ch1[0..575], ..., ch15[0..575]
#    r = row*24 + col
# ============================================================
with open("python_conv2_ref.hex", "r") as f:
    lines = [l.strip() for l in f if l.strip()]

assert len(lines) == 16 * 576, f"Expected 9216, got {len(lines)}"

conv2_vals = np.array([int(x, 16) for x in lines], dtype=np.uint8)
input_tensor = conv2_vals.reshape(16, 24, 24)   # [CH, H, W]

# ============================================================
# 2. 2x2 MaxPool (stride=2, valid) → 12x12 출력
#    out[ch, row, col] = max(
#        in[ch, row*2,   col*2  ],
#        in[ch, row*2,   col*2+1],
#        in[ch, row*2+1, col*2  ],
#        in[ch, row*2+1, col*2+1]
#    )
# ============================================================
output = np.zeros((16, 12, 12), dtype=np.uint8)

for ch in range(16):
    for row in range(12):
        for col in range(12):
            r0 = row * 2
            c0 = col * 2
            output[ch, row, col] = int(max(
                int(input_tensor[ch, r0,   c0  ]),
                int(input_tensor[ch, r0,   c0+1]),
                int(input_tensor[ch, r0+1, c0  ]),
                int(input_tensor[ch, r0+1, c0+1])
            ))

# ============================================================
# 3. 저장
#    형식: ch0[0..143], ch1[0..143], ..., ch15[0..143]
#    r = row*12 + col  (12*12 = 144)
# ============================================================
with open("python_maxpool_ref.hex", "w") as f:
    for ch in range(16):
        for r in range(144):
            row = r // 12
            col = r % 12
            f.write(f"{output[ch, row, col]:02x}\n")

# ============================================================
# 4. 통계 출력
# ============================================================
print(f"Output shape : {output.shape}")
print(f"Total pixels : {16 * 144}")
print(f"Non-zero     : {np.count_nonzero(output)}")
print(f"Max value    : {int(output.max())}")
print(f"Saved        : python_maxpool_ref.hex ({16*144} lines)")

for ch in range(16):
    nz = np.count_nonzero(output[ch])
    print(f"  ch{ch:02d} non-zero: {nz} / 144")
