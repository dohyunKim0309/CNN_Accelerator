#ifndef CONV2_WEIGHTS_H
#define CONV2_WEIGHTS_H

#include <stdint.h>

// Conv2 weight BRAM 적재 데이터 (32b packed Aport 포맷)
// weight_loader_conv2가 addr 0~575 (576 words) 순서로 읽음
//
// 주소 매핑 (weight_loader_conv2.v 기준):
//   addr = ((oc_pair*8 + ic)*3 + kh)*3 + kw
//   oc_pair: 0~7, ic: 0~7, kh: 0~2, kw: 0~2
//
// 포맷: 각 uint32 word의 하위 25-bit = packed_w (conv1과 동일 포맷)
//
// Python 가중치 패킹 스크립트로 생성한 값을 채울 것

const uint32_t conv2_weights[576] = {
    /* TODO: 576개의 packed weight 값(uint32)을 채울 것 */
    0U
};

#endif /* CONV2_WEIGHTS_H */
