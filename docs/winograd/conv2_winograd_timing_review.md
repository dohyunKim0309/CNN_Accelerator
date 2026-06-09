# conv2_winograd 전체 타이밍 리뷰 — 문제 예측 + 해결책 후보 (정적 분석)

> 목적: Vivado run(수시간) whack-a-mole 대신 **전 모듈 정적 리뷰로 모든 타이밍 위험을
> 미리 예측·기록 + 해결책 후보**. 근본 원인 = "깊은 조합 블록(13~20단)을 한 cycle 에
> 합성되게 둔 생성/엔진 코드". 검증된 사실(Vivado routed) 과 예측을 구분 표기.
>
> 진행 상태(2026-06-07): WNS −10.5@150 → (출력변환 파이프라인 + B 재정렬 + max_fanout) →
> **−6.337@150**. 새 limiter = 입력변환(13단). 아래는 그 다음 전부.

---

## §1. per-cycle datapath 맵 (현재 stage 경계)

```
S0 FSM        compute_cnt / tile_cnt / trow_cnt / grp                (reg)
S1 rb_read    tile_cnt/trow_cnt → wino_row_buffers 36-way mux → tile6_q   (reg) [B재정렬]
S2 ★IN-XFORM  tile6_q → 8× wino_input_transform(Bᵀ·d·B, 13단) → grp-mux → a_flat
              → DSP B-port → BREG                                    ← ★현 limiter −6.337
S3..S5 DSP    AREG/BREG → MREG → PREG  (wino_dsp_mul 내부 3-stage)   (reg, OK)
S6 ★REDUCE    PREG(prod) → wino_lane_reduce(Gauss) → cross-lane(4-add)
              → msum(acc+gp) → wino_m_assemble(conj) → m_re/m_im_flat (reg) ← ★14단 (class E)
S7..S8 OUT-X  m_*_flat → wino_output_transform(Aᵀ·M·A) [2-stage 파이프라인 완료] → y16
S9 trunc      y16 → wino_truncate(>>14+sat) → trunc_out              (reg)
S10 collect   trunc_out → tile_out[bank][pix][oc]                    (reg)
S11 writer    tile_out → c2pool                                      (reg)
```
**핵심: 한 stage 안에 든 조합 깊이가 곧 fmax 한계.** S2(13단)·S6(14단)이 현재 두 벽.

---

## §2. ★ 깊은 조합 블록 catalog (근본 문제)

| # | 블록 | 조합 깊이 | 폭 | 갱신 주기(=slack) | 현 register? | Vivado 근거 |
|---|---|---|---|---|---|---|
| **A** | 출력변환 Aᵀ·M·A + truncate | 원래 20단 → **8/stage** | MW25→YW28 | per (oc,tile) = **2-cyc** | ✅ 2-stage 파이프라인 | −10.5→해소 |
| **B** | **입력변환 Bᵀ·d·B + assembly** | **13단** | DW8→VW14 | **per tile = 32-cyc** ★ | ❌ comb | **−6.337 (현 worst)** |
| **C** | **mul_array reduce chain** (lane_reduce→cross-lane→msum→m_assemble) | **~14단** | PW24→MW25 | per issue = **2-cyc** | ❌ comb (PREG→m_*_flat reg) | −7.8 (class E, pre-fix #950) |

→ **A 만 파이프라인됨. B·C 가 남은 깊은 벽.** 셋 다 "곱셈 없는 adder network 를 한 cycle 에"
둔 것 — 생성기(`winograd_gen.py`)가 순수 조합 emit, 엔진이 단일 cycle 배치.

### ★ 결정적 통찰: B(입력변환)는 per-cycle 경로에 있으면 안 됨
`V = Bᵀ·d·B` 는 **d(tile)에만 의존 → tile 당 32-cycle 상수**. grp/oc 와 무관.
즉 13단 변환을 **매 cycle 재계산**하는 게 낭비이자 병목. tile 당 1회면 충분(32-cyc slack).
per-cycle 에 정작 필요한 건 grp-mux(1단)뿐.

---

## §3. high-fanout net catalog

| net | fanout | 구동대상 | 상태 | 비고 |
|---|---|---|---|---|
| `tile_cnt`/`trow_cnt` | 302 | row buffer 36-way read mux (2304b) | max_fanout=40 적용 | rb 내부 mux 라 효과 제한적 가능 |
| `compute_cnt_l` | 552/lane | per-PE RAMD32 read addr (46op×12b) | max_fanout=64 적용 | RAMD32 산개시 잔존 |
| `wm_*`(loader) | 184/163/32 | per-PE RAMD32 write | max_fanout=24 적용 | startup-only |
| `m_*_flat` | 30 | 출력변환 입력 (M 1개가 다수 Y16 에) | — | 출력변환 파이프라인이 흡수 |
| 변환 내부 합 | 21 | adder network 재사용 | — | 파이프라인시 분산 |

---

## §4. wide-bus catalog (배치 분산시 net delay)

| bus | 폭 | 경로 | 위험 |
|---|---|---|---|
| `a_flat` | 2576b | 변환 → **184 DSP B-port** | ★ 활성 분배, 근본 wide. lane-cluster 안 되면 net↑ |
| `w_q` | 2208b | per-PE RAM → 184 DSP A-port | per-PE local 화 완료(개선됨) |
| `tile6_q` | 2304b | rb → 8 transform | 변환 근처 배치면 OK |
| `m_re/m_im_flat` | 900b×2 | mul_array → 출력변환 | 중간 |
| 모든 net% 60~96% | — | — | **= 98% DSP 배치 분산(congestion) 근본** |

---

## §5. slack 기회 (파이프라인이 "무료"인 곳)

throughput 은 **issue rate(1/cyc, FSM 고정)** 이 결정 → **latency(파이프 깊이) 늘려도 cyc/img 불변**
(inter-image overlap). 따라서 아래는 전부 latency-only:

- **입력변환(B)**: a_ic 가 tile당 32-cyc 상수 → 3~4 stage 파이프 or **prefetch**(다음 tile 미리 계산) 가능.
- **reduce chain(C)**: M 이 2-cyc 마다 → 중간 register 1개 삽입 여유.
- **출력변환(A)**: M 2-cyc 마다 → 이미 2-stage, 더 깊게 가능.

**비용 = 재정렬(tag/collector/drain +N)** — 기계적, iverilog 가 off-by-one 잡음.

---

## §6. 해결책 후보 (우선순위 + 예상)

### 6.1 입력변환(B) — 현 worst. 후보 3개
- **B-1 파이프라인 N-stage** (생성기 `emit_input_transform` clocked 화: t=Bᵀd reg, V=tB reg…).
  - 2-stage→~6ns(~150), **3-stage→~4ns(200 시도)**. 재정렬: weight per-PE 2nd reg(local)+grp_q2+tag/collector +N.
  - 출력변환과 동형. 확실·결정적. **권장 1순위.**
- **B-2 prefetch** (tile tx 계산 중 tx+1 변환 미리, a_ic_reg 더블버퍼). per-cycle 경로에서 변환 **완전 제거**(grp-mux만 남음).
  - 가장 깨끗(13단이 critical 에서 사라짐)하나 prefetch FSM·더블버퍼 추가 = 복잡. **2순위(B-1 으로 200 못 닫으면).**
- **B-3 multicycle** (a_ic_reg + `set_multicycle_path`): tile당 상수 slack 이용. tile 경계 hazard(정착 전 사용) 주의 → 안전마진 필요. **저비용이나 위험.**

### 6.2 reduce chain(C) — 2순위
- **C-1**: cross-lane 합 직후 `gpre/gpim` register 삽입 → [lane_reduce+cross-lane] | [msum+m_assemble] 분할. +1 latency.
  - mul_array 내부 수정. ~14단 → ~7+7. accumulator 정렬(grp_pipe/vld_pipe) +1 재조정.

### 6.3 출력변환(A) — 필요시 심화
- 현 2-stage(~8/stage)가 200 에 빠듯하면 **각 matrix-mult 을 2 sub-stage**(부분합 reg)로 → 4-stage(~4/stage).

### 6.4 congestion(net 60%+) — 직교 레버
- **floorplan pblock**: conv2(184 DSP + 변환 + per-PE RAM)을 영역에 모아 net↓. 98% DSP 라 효과 불확실하나 시도가치.
- **lane-cluster 구조화**: a_flat/per-PE RAM/transform 을 lane별 4-cluster 로(이미 mul_array 가 lane generate). per-lane register 복제로 placer 유도.
- `phys_opt_design -directive AggressiveExplore` (200MHz 닫을 때 쓴 레버).

---

## §7. 통합 로드맵 (한 run 에 최대)

1. **B-1**(입력변환 3-stage) + **C-1**(reduce 1-stage) 동시 → 두 깊은 벽 제거. iverilog 40/40.
2. 재합성: 새 WNS 확인.
   - 200 근접 → phys_opt + (선택)pblock 으로 마무리.
   - 여전히 net-bound(−3~−5) → **floorplan(§6.4)** 가 본질 레버. or 출력변환 심화(6.3).
3. 그래도 안 닫히면 = **100T congestion 한계** 결론 → baseline(98ms) 대비 달성 freq 로 판단.

**예상**: B·C 파이프라인으로 logic 은 200MHz 급(stage ≤~5단)까지 내려가나, **net(congestion)
이 stage당 ~2.5–4ns 로 잔존** → 175~200 경계. 200 확정은 floorplan 성패에 달림. (정직히 불확실.)

---

## §8. 기능(non-timing) 위험 — 낮음
- per-PE RAMD32 read-during-write(load 중): mul_en=0 게이트 → 무해(검증됨).
- `wino_weight_bram` Port B `regceb=1'b1` tied → BMG abrupt-stop(REGCEB) class 아님(안전). [[bmg-l2-regceb-abrupt-stop]]
- 파이프라인 재정렬 off-by-one → iverilog(standalone 40/40 + full 40/40)가 전수 검출. 매 단계 필수.
- bit-exact: 모든 후보가 register 위치/latency 만 변경, 데이터 경로 값 불변 → golden 유지.

---

## §9. ROI 재확인 (1339 cyc/img, baseline 98ms@200)
150→89ms(1.10×) · 175→76ms(1.28×) · **200→67ms(1.46×)**. 150 미미, **200 이 목표**.
B·C 가 logic 벽이고 floorplan 이 net 벽 — 둘 다 넘어야 200. 넘기면 1.46×, 못 넘으면 ~175(1.28×).
