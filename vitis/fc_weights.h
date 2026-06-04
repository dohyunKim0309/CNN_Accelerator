#ifndef FC_WEIGHTS_H
#define FC_WEIGHTS_H

#include <stdint.h>

// FC weight BRAM 적재 데이터
// fc_weight_bram은 비대칭 BRAM: Port A 32b×8192 write / Port B 256b×1024 read
//
// 논리 구조 (fc_fsm.v 기준):
//   pair_cnt: 0~4  (5쌍 = 10 output class, even/odd pair)
//   s_cnt:    0~143 (spatial = 144 elements per pair)
//   Port B read addr = wbase + s_cnt  (wbase = pair_cnt * 144)
//   → 총 720 논리 엔트리, 각 256b = {w_odd_128b, w_even_128b}
//
// Port A 물리 레이아웃 (32b write):
//   논리 엔트리 E = pair*144 + s
//   물리 addr = E*8 + k  (k=0..7)
//   word[k*32 +: 32] = {w_odd_concat[127:0], w_even_concat[127:0]}[k*32 +: 32]
//   → k=0..3: w_even_concat(IC0~15 even OC weights, 각 int8)
//      k=4..7: w_odd_concat (IC0~15 odd OC weights,  각 int8)
//
// 총 : 720 × 8 = 5760 uint32 words
//
// Python 가중치 패킹 스크립트가 생성하는 5760개 값을 채울 것
// (TB의 load_fcw task가 생성하는 'word[k*32+:32]' 순서와 동일)

const uint32_t fc_weights[5760] = {
    /* TODO: 5760개의 32-bit 값(uint32)을 채울 것
     *       = 720 논리 엔트리 × 8 words/entry
     *       Python: for pair in 0..4, for s in 0..143,
     *                 word = np.concatenate([w_even_16ch, w_odd_16ch])  # 256b
     *                 for k in 0..7: fc_weights[...] = word[k*4:(k+1)*4] as uint32 */
    0U
};

#endif /* FC_WEIGHTS_H */
