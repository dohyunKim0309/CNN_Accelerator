#ifndef CONV1_WEIGHTS_H
#define CONV1_WEIGHTS_H

#include <stdint.h>

// Conv1 weight BRAM 적재 데이터 (32b packed Aport 포맷)
// conv1_weight_loader가 addr 0~35 (36 words) 순서로 읽음
//
// 포맷: 각 uint32 word의 하위 25-bit = packed_w
//   packed_w[7:0]   = W0 (int8)
//   packed_w[16:8]  = {9{W0[7]}} (W0 부호 확장)
//   packed_w[24:17] = W1 + (W0<0 ? -1 : 0) (int8 보정)
//
// Python 가중치 패킹 스크립트로 생성한 값을 채울 것

const uint32_t conv1_weights[36] = {
    /* TODO: 36개의 packed weight 값(uint32)을 채울 것 */
    0U
};

#endif /* CONV1_WEIGHTS_H */
