# Winograd Conv2 — 200MHz 타이밍 미달성 근본원인 분석 + 해결 계획

> # ✅ 최종 결론 (2026-06-19): 200MHz 는 이 칩(`xc7a100t-csg324-1`)에서 **불가** → **171.43MHz 확정**.
> 이 문서의 근본원인 분석(per-cycle 데이터이동 패턴)은 유효. **모든 해결시도의 결산 = `docs/winograd/winograd_overclock_journey.md` Iter 15**:
> ① **carry-bisect**(M 닫음) → Vivado 에서 unpinned **churn 으로 순손해**(WNS −0.342, Fmax 187<196) → revert.
> ② **floorplan**(reduce 압축) → **밀도 벽**: place 실패/강제시 **−1.116**. 근본=reduce 가 *흩어진 DSP-lane gather 노드*라
> −0.094 가 placer 최적 타협점, 모으면 입력 route 폭발 → **압축 intrinsic 불가**.
> ③ **클럭**: 188 = clk_wiz **silent snap**(요청≠실제); −1 칩 VCO 최대 **1200**(DS181) → 200 아래 천장 = **171.43**(÷7, M=12).
> → **winograd @ 171.43MHz** (VCO=1200, **baseline RTL**, bisect/floorplan 둘 다 out). 아래는 근본분석 보존.

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

## 2. 해결 방안 (개정 2026-06-11b) — scatter/gather 에 전용 cycle 부여

### 2.0 ★개정 경위 — 1차안 "V-stationary" 는 100T 에서 면적 불가 (실측 기록)

1차안(per-PE V 더블버퍼 4×VW + dist1/dist2 분배 파이프 + prefetch/PRIME)은 **iverilog
100/100 bit-exact 까지 통과**했으나 Vivado 에서 **`Place 30-487`** 로 기각:

```
slices 필요 12813 > 가용 9894 (총 15850)
LUT 59822(combined)/69136(total), capacity 63400
FF 87704 / 126800,  control sets 2272 (slice 당 control set 1개 제약으로 FF packing 불가)
```

- FF +~26K(vbuf 10.3K + dist 10.3K + lane reg 5.2K) 자체도 크지만, 결정타는 **CE 복제가
  만든 control set 폭증**(pf 단계별 CE × max_fanout 복제 → replica 마다 새 control set)
  → FF 가 slice 에 안 채워짐. 87.7K FF 는 완벽 packing 해도 10.9K slice 라 구조적으로 불가.
- **교훈**: max_fanout 은 route 를 사지만 **CE/제어 net 에 쓰면 control set 으로 면적을
  지불**한다. 99% DSP + LUT 85% 칩에서는 FF/CE 예산도 1급 제약.
- V-stationary 자체는 §6 의 장기 proposal 로 강등 (더 큰 디바이스에서 유효).

### 2.1 채택안 — 레버 2a(per-lane activation register) + G-1(gather 분할)

같은 근본원인(전역 distinct-data 버스가 변환 logic 과 한 cycle 에 직렬)을 **1/10 면적**으로
처리: 데이터를 정지시키는 대신 **die 횡단 net 에 전용 cycle 을 준다**.

**A. ★2a per-lane activation register** (`conv2_winograd_engine.v`)
- `a_q_l[0:3]` (4×46×VW=2576b, reset-free): `a_q_l[L] <= grp_q2 ? a_ic[L+4] : a_ic[L]`.
- 분할: [treg → stage2(~4단) → grp-mux → **a_q_l**] | [**a_q_l** → 46 DSP BREG].
  scatter net(이전 critical)이 logic 없는 전용 cycle 을 가짐. lane 별 분리 register 가
  placer 를 lane-cluster 로 유도 (`conv2_winograd_aflat_locality.md` 레버 2a).
- B-port 정렬 +1 → `w_q_op3`(per-PE local), `mul_en_q3`/`mul_grp_q3`, tag 11단.

**B. ★G-1 gather 분할** (`wino_mul_array.v`)
- lane-local `lpre_q/lpim_q`(free-run, CE-free): [PREG→lane_reduce] | [cross-lane 4-add
  →gpre_q] 분할. +1 latency.

**C. 정렬**: m_valid = issue+**9**, tag `tg[11]`, vld/grp_pipe 5단. cyc/img 1341→**1343**.

### 2.2 변경 후 per-cycle 경로 목록

| 경로 | 성질 |
|---|---|
| [rb read → tile6_q] | 전용 cycle (기존 class B fix) |
| [treg → stage2 → grp-mux → a_q_l] | logic ~4단 + local net |
| [a_q_l → 46 DSP BREG] | **net 전용 cycle** (이전엔 변환 logic 과 직렬 — 이게 핵심) |
| [PREG → lane_reduce → lpre_q] / [lpre_q → cross-lane → gpre_q] | gather 2-cycle 분할 |
| wmem_op→w_q_op→op2→op3 | PE-local |
| compute_cnt_l / grp_q2 / mul_en_q3 | 동일값 broadcast → max_fanout 복제 ✓ |
| 출력변환/trunc/collector/writer | 중앙-local, 파이프 완료 |

### 2.3 자원 영향 (1차안 대비)

- FF: +~10K (a_q_l 2.6K + w_q_op3 2.2K + lpre/lpim_q 5.2K) → ~50% (1차안 69% → 해소)
- 신규 CE 0개 (a_q_l/w_q_op3/lpre_q 전부 free-run) → **control set 증가 없음**
- LUT: grp-mux 위치만 이동 (register 입력으로 fold) ≈ ±0 → 기존 84~85% 유지

### 2.4 ★개정 2026-06-11c — 2차 Place 30-487 (LUT 90%) → IT-share (입력변환 8→4)

2a 안의 2차 place 도 기각: slices 10373 > 9531, **LUT combined 60.2K/63.4K = 95%**,
FF 69K(해소됨ok), control set 2006. **이제 벽은 FF 가 아니라 LUT.**

- post-synth `report_utilization`: Slice LUTs 57,221 (**90.25%**), FF 68,985 (54.4%),
  DSP 236/240, BRAM 41.85%. → LUT 를 ~6K 줄여야 place 가능권.
- **원인 분석**: 입력변환 8 인스턴스가 가속기 최대 LUT 소비처(개당 ~1.8K, 총 ~15K).
  그런데 grp-mux 가 매 cycle 8개 출력 중 4개만 선택 — **변환기 절반이 매 cycle 낭비**.
- **수정 (IT-share)**: 변환기 4개로 반감, **grp-mux 를 출력(46×VW)에서 입력(36×8b)으로
  이동** = d 입력을 grp_q 로 time-share. d-mux@(T+1)=grp_q → treg@(T+2) → stage2 →
  a_q_l@(T+3): 타임라인이 2a 와 동일해 **tag/drain/latency 무변경, bit-exact**.
- 효과: LUT **−~6K**(IT −7.2K, d-mux +1K) → ~84-87% 권. FF −3.2K(treg 4개분) 덤.
- 검증: iverilog standalone 100/100 + full 100/100, 1343 cyc/img (불변).

---

## 3. 실행 계획

| 단계 | 내용 | 검증 gate | 상태 |
|---|---|---|---|
| 0 | 변경 전 baseline 재확인 | iverilog standalone 100/100 + full 100/100 | ✅ (1341 cyc/img) |
| 1 | 1차안 V-stationary (vbuf+prefetch+PRIME) | iverilog 100/100 ×2 (1347 cyc/img) | ✅ 통과했으나 |
| 1' | → Vivado **Place 30-487 면적 기각** (§2.0) | slices 12813 > 9894 | ❌ 100T 불가 |
| 2 | **개정안**: ★2a a_q_l + w_q_op3 + tag 11단 (engine) | iverilog standalone **100/100** | ✅ (1343 cyc/img) |
| 3 | ★G-1 lane reduce reg free-run (mul_array) + full 검증 | `tb_cnn_accelerator_winograd_multi` **100/100** | ✅ (logit+readback) |
| 3' | → 2차 Vivado **Place 30-487 (LUT 95%)** (§2.4) | slices 10373 > 9531 | ❌ LUT 벽 |
| 3'' | **IT-share** (입력변환 8→4, grp d-mux) | iverilog 100/100 ×2, 1343 cyc/img | ✅ 완료 |
| 3''' | 3차 synth: LUT 75.9% / FF 49.1% — 면적 통과 | report_utilization | ✅ |
| 3'''' | 첫 routed: **WNS −2.037** (rb write broadcast fo=312, route 93%) | timing_summary | ❌ |
| 3''''' | **rb → 분산 LUTRAM** (6 bank×64×64b) + write +1 reg + PDRAIN 3 | iverilog 100/100 ×2 (1344) + 2clk 10/10 | ✅ 완료 |
| 4 | Vivado 재합성 — **이번엔 post-route phys_opt AggressiveExplore 포함** | route → WNS | ⏳ 사용자 |
| 5 | 미달 시 fallback ladder (§5) | report_timing 30-path + design_analysis | — |

**면적이 그래도 부족하면 (RTL 밖 레버, 효과 큰 순)**:
- **BD AXI 인프라 정리**: 현재 auto_ds×7 + auto_us×5 + auto_pc×4 + xbar×2 가 합성에
  포함 — width/protocol 불일치가 만든 자동 변환기들로, master/slave 폭·프로토콜을
  맞추면 수천~만 LUT 절감 여지. BRAM controller 5개 통합, XADC 미사용 시 제거도 후보.
- **conv1_2x → conv1 원복**: −18 DSP, −2~4K LUT. bottleneck 이 conv1(1634cyc)로 옮아
  200MHz 에서 ~82ms (1.20×). 참고로 전체 유지 + 171.4MHz = ~78ms 라 큰 차이 없음 —
  면적이 끝내 안 맞으면 이쪽이 합리적 절충.

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

## 4. 전망 (정직하게)

- 이전 critical(변환 logic + die 횡단 net 직렬)이 두 cycle 로 갈라졌고, gather 도 분할됨.
  남는 per-cycle 경로는 [logic ~4단 + local net] 또는 [net 전용 cycle] 부류.
- 불확실성: ① [a_q_l → 46 DSP] net 이 5ns 안에 들어오는가 (lane DSP 산개 정도),
  ② [stage2+grp-mux→a_q_l] 의 net 비중, ③ LUT 85% congestion. → 안 닫히면 §5.
- 1차안 대비 트레이드오프: scatter 가 "제거"가 아니라 "전용 cycle"이므로 net 자체는 남는다.
  대신 면적이 들어맞는다 — 100T 에서는 이것이 유일하게 실행 가능한 절충.

## 5. Fallback ladder (위에서부터 시도)

1. **[stage2→a_q_l] 가 worst**: 입력변환 stage2 를 한 단 더 분할(3-stage 화, 생성기
   `emit_input_transform` 패턴 그대로, +1 정렬 = w_q_op4/tag 12 — 기계적).
2. **[a_q_l→BREG] net 이 worst**: a_q_l 을 lane 당 2-copy 로 복제(fanout 46→23, +2.6K FF)
   또는 lane 별 pblock 4개 (DSP column 단위) — lane 데이터가 lane-local 이라 이제 효과 있음.
3. **lpre_q 수렴이 worst**: cross-lane 4-add 를 2+2 트리로 한 단 더 분할(+1, 기계적).
4. **control broadcast 잔존**: max_fanout 32→16→8 (grp_q2/mul_en_q3/compute_cnt_l).
5. **그래도 미달**: MMCM 이산 집합상 다음 후보 **171.4MHz** 로 확정 (≈78ms, baseline 98ms
   대비 1.26×). ※ 175MHz 는 이 보드 MMCM 설정에서 생성 불가(188→200 스냅 사고와 동일 함정).
   ⚠ fallback 1·2 적용 시 면적 재확인 필수 — §2.0 교훈(FF/control set 예산).

## 6. 장기 아키텍처 proposal (이번 적용 범위 밖, 차후/대형 디바이스 검토)

1. **V-stationary (1차안, §2.0)**: per-PE V 더블버퍼 + tile-rate prefetch 분배 — per-cycle
   scatter 를 *완전 제거*하는 가장 깨끗한 답이나 FF/control set 예산이 100T 를 초과
   (실측: slice 12813 필요). Artix-200T 급 이상이면 그대로 유효. 구현·검증 이력은 git
   (iverilog 100/100 통과본) 에 있음.
2. **DSP cascade 기반 IC 누적**: 4 lane 의 동일 operand DSP 를 수직 인접 배치(quad)하고
   PCIN/PCOUT 전용 cascade 로 Σ_IC 를 fabric 배선 0 으로 수행 → gather 대역 4× 감소
   (184→46 값). 비용: lane-interleave 배치 제약(LOC/RLOC) + lane 별 1-cycle staggered
   issue 재설계.
3. F(4,3) 알고리즘 자체는 유지 — 교체할 이유 없음 (곱셈수·bit-exact·golden 전부 그대로).

---

*근거 문서: `docs/overclock_journey_100_to_200mhz.md`(baseline 이 닫힌 방법),
`docs/winograd/winograd_overclock_journey.md`(Iter 0~4), `docs/winograd/conv2_winograd_timing_review.md`(정적 카탈로그),
`docs/winograd/conv2_winograd_aflat_locality.md`(레버 2a 초안 — 본 계획 §2.1A 가 이를 흡수·강화).*
