# Winograd Conv2 — 200MHz 타이밍 미달성 근본원인 분석 + 해결 계획

> **작성**: Claude (Fable 5, Claude Code 세션) — 2026-06-11, 요청자: 김도현 (dkim7800@gmail.com)
> **대상**: `RTL/conv2_winograd/` 복소수 Winograd F(4,3) conv2 엔진 (184 DSP, drop-in)
> **질문**: direct conv2 baseline(192 DSP)은 200MHz 가 닫혔는데(WNS +0.011, HW 10000/10000),
> 왜 Winograd 버전(184 DSP, 곱셈 더 적음)은 안 닫히는가?

---

## 1. 근본 원인 — "같은 칩, 같은 DSP 수인데 왜 다른가"

### 1.1 두 설계의 결정적 차이는 **연산량이 아니라 per-cycle 데이터 이동 패턴**

| | direct conv2 (닫힘) | Winograd conv2 (안 닫힘) |
|---|---|---|
| DSP | 192 (94%) | 184 (+conv1_2x 36+fc 18 = **238/240 = 99%**) |
| 매 cycle die 를 가로지르는 신호 | **동일값 broadcast** (state/shift_en/pe_en/weight bc + 픽셀 1개) | **서로 다른 값의 광폭 버스**: `a_flat` 2576b 산포(scatter) + 184×24b product 수렴(gather) |
| 그 신호의 fanout 구조 | fanout 큰 net **하나** → `max_fanout` 복제로 해결 가능 | **fanout 1~2 짜리 net 수천 개** → 복제가 원리적으로 무효 |
| 데이터 위치 | weight-stationary + 누적 PE-local (데이터는 제자리, 제어만 이동) | transform 중앙집중 → 모든 데이터가 매 cycle 중앙↔184 DSP 왕복 |

baseline 의 모든 타이밍 벽(`overclock_journey_100_to_200mhz.md`)은 **"동일값 고fanout broadcast
의 route delay"** 였고, 전부 `max_fanout` driver 복제 + reset 트리 + phys_opt 로 닫혔다.

Winograd 의 실패 경로는 다르다 (`winograd_overclock_journey.md` Iter 2~3 측정):
- route congestion(`Route 35-447`), 실패 경로 **net 비중 65~96%**, TNS −185,083(수천 endpoint).
- 원인 버스: `a_flat`(2576b, 변환→184 DSP), product gather(184×24b→26 위치), `tile6_q`(2304b),
  `m_re/m_im_flat`(1800b). 이들은 **모든 bit 이 서로 다른 출발/도착지를 가진 fanout-1 net** 이라
  baseline 의 만능 레버(`max_fanout`)가 **아예 작동하지 않는 부류**다.

### 1.2 왜 이것이 "아키텍처" 문제인가

현재 데이터플로우는 **tile 당 상수(또는 2-cycle 상수)인 데이터를 매 cycle 전역 이동**시킨다:

1. **V(입력변환 결과)는 tile 당 32-cycle 동안 상수**이고, lane 별로는 grp0/grp1 두 벡터를
   번갈아 쓸 뿐이다. 그런데 현 구조는 *중앙* 변환기에서 grp-mux 한 2576b 를 **매 cycle**
   184 DSP 로 재산포한다 → die 횡단 net delay 가 변환 logic 과 **한 cycle 에 직렬**로 합산.
2. **M 은 2-cycle 에 한 번** 완성되는데, 184 DSP 의 product 를 **매 cycle** 중앙 reduce 로
   수렴시킨다 (PREG→lane_reduce→cross-lane 이 한 cycle).
3. DSP 238/240 사용 → placer 의 배치 자유도 0. lane(46 DSP)이 고정 DSP column 들에 흩어져
   scatter/gather 거리가 구조적으로 die-spanning.

즉 **곱셈은 3.13× 줄였지만 per-cycle 전역 배선 트래픽은 직접 conv 대비 ~10× 늘린 구현**이며,
이 칩(Arty A7-100T)의 한계는 곱셈기가 아니라 배선이다. Iter 3~4 가 깊은 조합블록(13~20단)을
파이프라인으로 제거했어도, **per-cycle 전역 scatter/gather 는 그대로**라 200MHz(5ns)가 안 닫힌다.

### 1.3 결론

- 알고리즘(복소수 F(4,3))의 문제가 아니다 — **mapping(데이터플로우)의 문제**다.
- "max_fanout 더 줄이기 / floorplan" 으로는 못 닫는다 — 대상 net 들이 복제 불가능한 부류다.
- 필요한 것은 **데이터를 시간축에서 재배치**하는 아키텍처 수정: per-cycle 경로에서
  데이터 버스를 제거하고, tile-rate(32-cycle) 백그라운드 전송으로 옮기는 것.

---

## 2. 해결 방안 — "V-stationary" 아키텍처 (weight 경로와 대칭화)

weight 가 이미 이렇게 고쳐졌다는 점이 열쇠다: Iter 2 에서 weight 를 **per-PE 분산 RAM** 으로
옮기고 per-cycle 전역 신호를 5-bit counter(복제 가능)만 남기자 route hang 이 풀렸다.
**activation(V)에도 같은 처방**을 적용한다.

### 2.1 핵심 변경 3가지 (전부 bit-exact 보존, throughput 불변)

**A. per-PE V 더블버퍼 (vbuf) + tile-rate 분배 — scatter 제거**
- 각 PE(184개)에 `{bank0,bank1}×{grp0,grp1}` 4×VW(14b) register. per-cycle B-port 경로는
  `vbuf → 4:1 mux(1 LUT) → DSP BREG` 로 **완전 local**.
- mux select = `act_q2`(tile parity), `grp_q2` — **1-bit broadcast** → `max_fanout` 복제 가능
  (baseline 의 pe_en/shift_en 과 동일 부류 = 닫히는 부류).
- V 적재는 **prefetch**: tile t 계산 중(cc==20 trigger) tile t+1 을 row buffer 에서 읽어
  입력변환(기존 2-stage) → 분배 파이프 `dist1→dist2`(2-hop register) → 비활성 bank 에 write.
  모든 hop 이 register 로 끊겨 있어 어느 segment 도 5ns 를 넘을 이유가 없음.
- 부수 효과: **rb 36-way read(tile6_q)와 입력변환 전체가 per-cycle 경로에서 사라짐**
  (tile 당 1회만 동작). 옛 class B 경로 소멸.

**B. gather 2단 분할 — per-lane reduce register**
- `wino_mul_array`: `PREG → lane_reduce → [lpre_q/lpim_q (lane-local reg, 신규)] →
  cross-lane 4-add → gpre_q → msum/m_assemble → m_flat`. 한 cycle 에 있던
  [46-DSP 수렴 + 4-lane 합]을 두 cycle 로 분할. +1 latency (throughput 불변).

**C. 정렬 재조정 (기계적)**
- m_valid = issue+7 → **issue+8**, tag pipeline 9→**10**단, collector `tg[10]`,
  vld/grp_pipe 4→5단. 이미지당 PRIME(첫 tile V 적재) +5 cycle → cyc/img 1341→**~1346** (+0.4%).

### 2.2 변경 후 per-cycle 경로 목록 (전부 닫히는 부류)

| 경로 | 성질 |
|---|---|
| vbuf→mux→BREG / wmem_op→w_q_op | PE-local |
| compute_cnt_l / grp_q2 / act_q2 / mul_en_q2 / vb_we | 1-bit~5-bit 동일값 broadcast → max_fanout 복제 ✓ |
| PREG→lane_reduce→lpre_q | lane 내 수렴 + adder 2단 (분할됨) |
| lpre_q→cross-lane→gpre_q | 4-source 수렴 + adder 2단 (분할됨) |
| 출력변환/trunc/collector/writer | 중앙-local, 2-stage 파이프 완료 |
| prefetch 경로 전체 (rb read, 변환, dist) | register hop 단위로 분리, 각 hop 여유 |

### 2.3 자원 영향 (예상)

- FF: +~26K (vbuf 10.3K + dist 10.3K + lane reduce reg 5.2K) → 42% → **~62%** (FF 는 최풍부 자원)
- LUT: 옛 grp-mux(2576b 2:1) 제거 vs per-PE 4:1 mux 추가 ≈ **±1K 내외** (84% 유지)
- BRAM/DSP: 불변. fallback: dist 2-stage→1-stage 로 FF 5.2K 절감 가능.

---

## 3. 실행 계획

| 단계 | 내용 | 검증 gate | 상태 |
|---|---|---|---|
| 0 | 변경 전 baseline 재확인 | iverilog standalone 100/100 + full 100/100 | ✅ (1341 cyc/img) |
| 1 | `wino_mul_array` lane reduce reg (+1) | (2와 함께 검증) | ✅ 완료 |
| 2 | engine: PRIME state + prefetch 시퀀서 + dist 파이프 + per-PE vbuf + tag 10단 | iverilog standalone **100/100** | ✅ 완료 (1347 cyc/img) |
| 3 | full pipeline 검증 | `tb_cnn_accelerator_winograd_multi` **100/100** | ✅ 완료 (logit+readback 100/100) |
| 4 | Vivado 재합성 (사용자, Parallels) | place/route + WNS 리포트 | ⏳ 사용자 |
| 5 | 미달 시 fallback ladder (§5) | report_design_analysis | — |

> **검증 중 잡은 함정 (기록)**: 1차 구현에서 98/100 (img2/img20, addr75=tile(0,0) px(3,3), OC0
> byte 만). px(3,3)↔M[5][5] 단독 의존성으로 역추적 → `compute_cnt_l`(lane 복제 카운터)이
> PRIME 5 cyc 동안 stale `compute_cnt`(31)를 재적재 → RUN 첫 issue 가 `wmem[31]`(oc15/grp1
> weight)을 읽는 **lockstep 위반**. 수정 = `compute_cnt_nxt` 에 `state==PRIME → 0` 추가.
> 교훈: 복제 카운터는 원본과 *같은 next-state 식*을 공유해야 하며, FSM 에 state 를 추가하면
> 그 state 에서의 next-state 도 재검토할 것. (멀쩡해 보이는 96%는 ReLU 클리핑이 가린 것 —
> bit-exact 100-image gate 가 아니었으면 못 잡았다.)

**Vivado 체크리스트 (단계 4)**:
1. 복붙 파일 = `RTL/conv2_winograd/conv2_winograd_engine.v`, `RTL/conv2_winograd/wino_mul_array.v` (2개만, 포트 불변 → BD/top/firmware 무변경).
2. impl strategy 에 **post-route `phys_opt_design -directive AggressiveExplore`** 포함 (interactive 로 하지 말 것 — 재현성 함정, baseline 교훈).
3. 실패 시 가져올 것: `report_timing -setup -max_paths 30 -input_pins -nets -file`, `report_design_analysis -timing -file`, `report_utilization -file`.

---

## 4. 왜 이 방안이 200MHz 를 닫을 것으로 보는가 (정직한 전망)

- 남는 per-cycle 경로가 전부 baseline 에서 **이미 닫아 본 부류**(local 연산, 복제 가능한
  broadcast, 2단 이하 adder)로 환원된다. baseline 은 DSP 94% + 동일 칩에서 이 부류만 남기고
  +0.011 로 닫았다.
- 불확실성: ① 99% DSP 점유에서 placer 가 lane 을 얼마나 흩는가 (lpre_q 수렴 거리),
  ② LUT 84% 에서의 congestion 잔존. → 안 닫히면 §5.

## 5. Fallback ladder (위에서부터 시도)

1. **lpre_q 수렴이 worst 일 때**: cross-lane 4-add 를 2+2 트리로 한 단 더 분할(+1, 기계적).
2. **분배(dist) 경로가 worst 일 때**: dist 3-stage 화 (+FF 5.2K, prefetch trigger cc 20→18).
3. **control broadcast 잔존**: max_fanout 32→16→8 (act_q2/grp_q2/mul_en_q2/vb_we).
4. **순수 congestion**: lane 별 pblock 4개 (DSP column 단위) — 이제 lane 데이터가 전부
   lane-local 이라 pblock 효과가 비로소 생김 (이전엔 중앙 변환기 때문에 무효였음).
5. **그래도 미달**: MMCM 이산 집합상 다음 후보 **171.4MHz** 로 확정 (≈78ms, baseline 98ms
   대비 1.26×). ※ 175MHz 는 이 보드 MMCM 설정에서 생성 불가(188→200 스냅 사고와 동일 함정).

## 6. 장기 아키텍처 proposal (이번 적용 범위 밖, 차후 검토)

**DSP cascade 기반 IC 누적**: 4 lane 의 동일 operand DSP 를 수직 인접 배치(quad)하고
PCIN/PCOUT 전용 cascade 로 Σ_IC 를 fabric 배선 0 으로 수행 → gather 대역 4× 감소
(184→46 값). 비용: lane-interleave 배치 제약(LOC/RLOC) + lane 별 1-cycle staggered issue
재설계. 본 계획(§2)으로 닫히면 불필요. F(4,3) 알고리즘 자체는 유지 — 교체할 이유 없음
(곱셈수·bit-exact·golden 전부 그대로).

---

*근거 문서: `docs/overclock_journey_100_to_200mhz.md`(baseline 이 닫힌 방법),
`docs/winograd/winograd_overclock_journey.md`(Iter 0~4), `docs/winograd/conv2_winograd_timing_review.md`(정적 카탈로그),
`docs/winograd/conv2_winograd_aflat_locality.md`(레버 2a 초안 — 본 계획 §2.1A 가 이를 흡수·강화).*
