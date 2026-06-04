#ifndef INPUT_IMAGE_H
#define INPUT_IMAGE_H

#include <stdint.h>

// 28x28 single-channel input image (int8 quantized)
// Python 양자화 스크립트로 생성한 값을 아래 배열에 채울 것
// 레이아웃: row-major, pixel[row][col] = input_image[row*28 + col]
// 총 784 bytes → main.c에서 4 bytes씩 묶어 196 words로 BRAM_INPUT에 32b write

const int8_t input_image[784] = {
    /* TODO: 양자화된 픽셀 값 (int8) 784개를 채울 것 */
    0
};

#endif /* INPUT_IMAGE_H */
