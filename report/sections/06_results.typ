#import "../helpers.typ": *

= Results <sec-results>

== Baseline — 오버클럭 이전: 기능 검증

기능 검증의 기준은 PyTorch reference 모델(golden)이다. golden으로부터 레이어별 입력·기대출력을
hex로 생성하고, 각 레이어의 출력이 INT8 단위로 golden과 정확히 일치하는지(bit-exact)를 모듈별
테스트벤치와 전체 통합 테스트벤치로 확인했다.

#placeholder("그림 F12: golden → hex → RTL bit-exact 검증 파이프라인", h: 2.5cm)

=== PE cell — 2²⁴ exhaustive
PE cell은 weight·activation 입력 조합 전체($2^24 approx 16.7"M"$)에 대한 exhaustive 검증으로
SIMD packing이 *모든 INT8 경우에 bit-exact* ($W_1=-128$ corner 포함)임을 증명했다. 이는
@sec-packing packing 주장의 직접 근거다.

#placeholder("그림 W1: pe_cell 2²⁴ exhaustive PASS 로그 (캡처 예정)", h: 3cm)

=== Conv2 — 단위 TB
Conv2는 단위 테스트벤치로 레이어 출력이 golden과 bit-exact임을 확인하며, 통합 테스트벤치에서도
전체 파이프라인의 logit이 일치한다(아래 통합 TB). 컨볼루션 레이어의 bit-exact 자체는 PE
cell의 $2^24$ exhaustive(위)와 통합 TB(아래)로도 직접 뒷받침된다.

=== FC / argmax — 단위 TB (로그)
FC는 2,304→10 누적이 golden과 일치함을, argmax는 4-round tournament가 최댓값 인덱스를
올바르게(낮은 인덱스 우선 tie-break) 내는지 확인한다. 단위 테스트벤치에서 10개 클래스 logit이
*10 / 10 모두 bit-exact* 로 일치했고, argmax가 낸 class index도 기대값(=5)과 일치해
*ALL PASS* (logit bit-exact + argmax correct)를 확인했다.

#placeholder("그림 W4: fc 단위 TB 결과 (logit 10/10 bit-exact, argmax class_idx=5 correct, ALL PASS)", h: 3cm)

=== MaxPool — 단위 TB (로그)
MaxPool은 동작이 단순(2×2 조합 비교)하므로 PASS 로그만 싣는다. single-image 테스트벤치에서
한 이미지의 풀링 출력 *144 픽셀 × 16 채널 = 2,304 byte* 전체를 golden과 비교해 *0 / 2,304
mismatch* 로 bit-exact 일치를 확인했다(compute 1,015 cycle).

#figbox("figures/existing/maxpool_testbench.png",
  [그림 W6: maxpool 단위 TB 결과 (0/2,304 mismatch, bit-exact PASS)], w: 78%)

=== 통합 TB & ping-pong
전체 파이프라인 통합 테스트벤치로 MNIST 이미지에 대해 logit이 bit-exact임을 확인하고,
ping-pong bank toggle과 stage 간 핸드셰이크 타이밍을 파형으로 분석한다.

#placeholder("그림 W7: 통합 TB PASS 로그 + ping-pong/handshake 파형 (캡처 예정)", h: 3cm)

== Baseline — 오버클럭 이후: 보드 구현 & 실행

*Timing.* 200 MHz에서 timing closure를 완료했다(WNS +0.011 ns @ slow corner, MET). 단계별
서사와 WNS 추적표(표 T4)는 @sec-optim-base 에 있으며, 여기서는 최종 signoff 값만 인용한다.

*Resource utilization.* baseline은 DSP *226/240(94%)* (Conv2 192 + Conv1 18 + FC 16)을 쓴다.
LUT / FF / BRAM을 포함한 전체 사용량은 아래 implementation 리포트와 같다.

#figbox("figures/existing/direct_impl_utilization.png",
  [그림: Baseline 200 MHz utilization 리포트], w: 88%)

*Power (명세 우선순위 \#2).* default setup으로 측정한 power summary는 아래와 같다. 명세 p.7의
요구대로 power 리포트 setup을 변경하지 않았으며, 트레이드오프 해석은 @sec-disc-power 에 둔다.

#figbox("figures/existing/direct_impl_200MHz_power_summary.png",
  [그림: Baseline 200 MHz power summary (default setup)], w: 80%)

*보드 실행 결과.* clean 빌드(WNS +0.011)에서 측정했으므로 수치 자체가 신뢰 가능하다.

- *정확도(SW 대비)*: MNIST 10,000장에 대해 *10,000 / 10,000 일치* (100%).
- *Latency*: 최초 200 MHz 실측 *108.9 ms* (10,896,290 cycle @ 100 MHz 타이머). 이 108.9 ms는
  100 MHz baseline(0.188 s) 대비 1.72×, 150 MHz(0.128 s) 대비 1.17×이다. 이후 Vitis
  feed-overlap 최적화로 *약 98 ms* 까지 더 단축했다(0.188 s 대비 1.92×). 즉 클럭만으로는
  1.72×, feed 최적화를 더하면 1.92×다.
- *프로파일*: 실측 로그상 in-CDMA(blocking) 입력 feed가 전체의 72%(7,905,500 cycle, 100 MHz
  도메인)를 차지한다. 가속기 클럭을 2배로 올려도 compute slice만 압축되므로 1.72×에 그쳤다 —
  즉 다음 병목이 연산이 아니라 *PS-PL feed* 임을 데이터가 가리킨다(해석은 @sec-disc-limit).

#figure(
  table(
    columns: 3, align: (left, right, right),
    table.header[단계][1만장 latency][baseline 대비],
    [100 MHz baseline], [0.188 s], [1.00×],
    [150 MHz], [0.128 s], [1.47×],
    [200 MHz], [108.9 ms], [1.72×],
    [200 MHz + feed-overlap], [\~98 ms], [1.92×],
  ),
  caption: [표 T6: end-to-end latency 진행 (검증된 지점)],
)

#figbox("figures/existing/result_04_overclock_200MHz_vitis_overlap_hw.png",
  [그림: 200 MHz + feed-overlap 보드 실측 (10000/10000, ~98 ms)], w: 80%)

== Winograd — 오버클럭 이전: bit-exact 검증

Winograd 데이터패스는 시뮬레이션 정수 검증을 통과했다. *Winograd를 적용한 top-module TB* 는
logit bit-exact + bram_output readback 모두 *100/100 PASS* (`FINAL: results 100/100`,
throughput 132,759 cyc total, avg 1,341 cyc/img)이다. Conv1 2× rebalance gate는 별도로 40/40
bit-exact이며, 두 결과는 서로 다른 테스트벤치이므로 혼동 없이 분리해 표기한다.

#figbox("figures/existing/winograd_testbench_100image_result.png",
  [그림 F10: Winograd top-module TB 결과 (100/100, avg 1,341 cyc/img)], w: 75%)

검증 기준은 정수 golden이다 — 하드웨어의 정수 데이터패스는 정수 reference와 정확히 0 오차로
일치한다(bit-exact). 한편 float 골든 모델 내부에서 나오는 $"err" < 5 times 10^(-16)$은
부동소수 reference 자체의 반올림 오차일 뿐 하드웨어 비교값이 아니므로, 둘을 분리해 서술한다.
전체 10,000장은 정수 golden 기준 bit-exact 100%로 확인했다.

== Winograd — 오버클럭 이후: util & 비교

합성 결과 자원 사용량은 LUT 75.88%(48,110/63,400), FF 49.07%(62,221/126,800), *DSP
98.33%(236/240)*, BRAM 41.85%(56.5/135)이다. DSP가 거의 포화 상태로, Winograd multiply
array(184) + Conv1 2×(36) + FC(16)가 예산을 빠듯하게 채운다.

#figbox("figures/existing/winograd_impl_utilization.png",
  [그림: Winograd utilization (DSP 236/240 = 98.33%)], w: 88%)

timing은 *171.42 MHz에서 met* (WNS +0.222 ns, 0 failing endpoint)으로 닫혔다(서사는
@sec-optim-wino). 다만 *보드 실측은 수행하지 못했다* (보드 제출 마감 시점에 fallback 미확정).
따라서 정확도·latency는 시뮬레이션 검증 + implementation timing + cycle 추정으로 보고한다:
시뮬레이션 bit-exact(100/100)이므로 보드에서도 baseline과 동일한 10,000/10,000이 기대되며,
latency는 $1,341 times 10,000 / 171.42 "MHz" approx 78 "ms"$(compute-only, feed 무시)로
추정된다 — *모두 추정이며 보드 실측이 아님을 명시* 한다. (Baseline vs Winograd 종합 비교는
표 T12, @sec-optim-summary.)
