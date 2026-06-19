= Conclusion <sec-conclusion>

본 프로젝트는 Arty A7-100T 위에서 MNIST 10,000장을 분류하는 INT8 CNN 가속기를 설계하고,
end-to-end latency 최소화를 목표로 최적화하였다. 결과는 두 갈래로 정리된다.

*검증 완료된 baseline.* 명세의 INT8 직접 컨볼루션을 비트-정확하게 구현하고 200 MHz로 timing
closure(WNS +0.011 ns @ slow corner)하여, MNIST 10,000장에 대해 *10,000/10,000 정확도* 와
*약 98 ms* latency를 보드에서 실측하였다. 이 과정에서 가장 큰 작업은 −8.6 ns에서 +0.011 ns까지
닫아간 timing closure 여정(@sec-optim)이었으며, 그 핵심 통찰은 이 칩의 타이밍 벽이 로직
깊이가 아니라 high-fanout 제어·리셋 net의 route delay에 있었고 `max_fanout` 드라이버 복제가
일관된 처방이었다는 것이다.

*제안 알고리즘.* Conv2가 곱셈의 90%를 차지한다는 분석에서 출발해, (1) DSP48E1 한 개로 두
INT8 곱을 처리하는 SIMD packing, (2) 곱셈을 직접 conv 대비 3.13× 줄이면서 INT8 bit-exact를
유지하는 complex Winograd F(4×4, 3×3), (3) 그로 인해 이동한 병목을 맞추는 Conv1 2× rebalance를
도입하였다. Winograd 데이터패스는 시뮬레이션에서 bit-exact로 검증되었고 implementation은
*171.42 MHz로 timing-met* (200 MHz는 두더지 잡기식 병목 연쇄로 미달)이다. 다만 보드 제출
마감 시점의 시간 제약으로 *보드 실측은 수행하지 못해*, 1만 장 latency는 cycle 추정(\~78 ms
\@171.42 MHz)으로만 보고한다.

마지막으로, 본 설계의 다음 한계는 연산이 아니라 데이터 전송에 있다. 클럭을 두 배로 올려도
latency가 1.72×만 줄어든 것은 전체 시간의 72%가 PS-PL feed에 묶여 있기 때문이며, 따라서
Winograd의 연산 이득을 온전히 얻으려면 feed overlap이 선행되어야 한다 — 이는 향후 작업의
분명한 방향이다.
