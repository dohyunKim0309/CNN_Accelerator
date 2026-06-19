# conv2_winograd_engine — 현행 동작 · latency anchor · 안전수정 가이드

> ❗ **2026-06-19 정정 — 현행 RTL = baseline.** 본문 latency 가 한때 carry-bisect(+1) 값으로 적혔으나
> **bisect 은 HW churn 으로 revert**(journey Iter 15, `.bisect.bak` 보존). **baseline 환산(전부 −1)**:
> 1349→**1348** / issue+12→**+11** / tag16→**15** / tg_*[16]→**[15]** / 2oc+13→**2oc+12** /
> 2oc+18→**2oc+17** / 2oc+19→**2oc+18** / tail36→**35**. 권위값 = journey **Iter 15** (최종 171.43MHz).
> (본문 개별 수치 전수 −1 정정은 잔여 mechanical cleanup.)

> **역할 (다른 winograd 문서와 중복 없이)**: overclock 파이프 추가 **이후의 현행 RTL** 의
> ① cycle-exact 파이프라인 + **latency anchor**, ② 복소 MAC/`m_assemble` 의 **HW 매핑**,
> ③ **안전수정 규칙** 만 담는다. 알고리즘·설계청사진·진행기록·정적리뷰는 아래 관련문서로 위임.
> 추측 금지 — 전부 `conv2_winograd_engine.v` + leaf 실제 코드 (2026-06-16, class B revert 후, iverilog 100/100).

## 관련 문서 (역할 분담 — 본 문서는 "현행 동작 + latency + 안전수정")

| 문서 | 담당 (여기서 다루지 않음) |
|---|---|
| `algorithm_complex_f43.md` | 복소 F(4,3) 도출·검증·행렬(§9.1 정정판)·§8 HW 아키텍처. **복소/켤레의 수학적 근거** |
| `conv2_winograd_design.md` | RTL 구현 **설계청사진**: 모듈분해/외부인터페이스/weight 포맷/DSP 매핑 |
| `conv2_winograd_timing.md` | **절대 cycle-by-cycle 다이어그램**(현행 정합: m_valid=2oc+13, 1349) + handshake §8 / ping-pong §5 / PDRAIN §5.1 / row_buffers §6 / FSM 상태표 §7. 본 문서는 **상대 anchor·규칙**만(중복 회피) |
| `conv2_winograd_timing_review.md` | 정적 타이밍 위험 catalog (깊은 조합블록 §2) — 예측/근거 |
| `winograd_overclock_journey.md` | **200MHz 진행기록** (Iter 0~12, §A 카탈로그). 현재 WNS·잔존 벽은 여기 |
| `conv2_winograd_aflat_locality.md` | a_flat lane-locality 레버 2a 설계 (=★2a a_q 의 출처) |
| `WINOGRAD_200MHZ_CLOSURE_PLAN.md` (루트) | scatter/gather 분할 계획 §2 |

---

## 0. 현재 상태
- iverilog: standalone `tb_conv2_winograd_engine_multi` + full `tb_cnn_accelerator_winograd_multi`
  **둘 다 100/100** (logit+readback). steady-state **1349 cyc/img**.
- 200MHz WNS 음수 잔존 (reduce 영역 25-bit carry + congestion). 수치·이력 = journey Iter 12.
- 알고리즘 1줄 요약·곱셈수·drop-in 인터페이스 = `conv2_winograd_design.md` §0/§1.

## 1. 파일 / 모듈 (`RTL/conv2_winograd/`)
모듈 **분해·인터페이스·DSP 매핑은 design 문서 §1~3**. 여기선 leaf 와 clk/파이프 깊이만:

| 파일 | clk 파이프 | 비고 |
|---|---|---|
| `conv2_winograd_engine.v` | — | top: FSM(제어) + datapath 결선 (§2~4) |
| `wino_input_transform.v` | **3-stage** | `V=Bᵀ·d·B`, d→a_flat = **+2** |
| `wino_mul_array.v` (lane×4) | a_q(★2a)+DSP3+pre_q(★G-1) | per-IC그룹: a_q reg + 46 DSP + lane_reduce |
| `wino_lane_reduce.v` | comb | 46 product → 26 position partial |
| `wino_m_assemble.v` | comb | 26→36 켤레확장 (곱셈기 0, 순수 routing+negate) — §3 |
| `wino_output_transform.v` | **4-stage** | `Y16=Aᵀ·M·A` |
| `wino_truncate.v` | 1 | `sat(>>>14)+ReLU` |
| `wino_row_buffers.v` / `wino_dsp_mul.v` / `wino_weight_loader.v` | — | 2-set LUTRAM / DSP48E1 래퍼 / startup weight write |

> producer∥consumer∥writer + 2-set ping-pong = **timing §5**, handshake = **timing §8** (현행과 동일, 미복제).

---

## 2. ★ Consumer datapath 파이프라인 — 상대 anchor (절대 cycle 다이어그램 = timing §2.1/§3)

issue = `compute_cnt` 0..31. `oc=compute_cnt[4:1]`, `grp=compute_cnt[0]`. **한 OC 의 M 은
grp0(IC0-3)·grp1(IC4-7) 2 cycle 누적**으로 완성 (§3). 절대값(예: m_valid@2oc+13)은 timing §2.1.

```
issue T (compute_cnt)
 │ IT-share d-mux(grp_q) → wino_input_transform 3-stage (a_flat = d_flat+2)
 │ ★2a a_q <= a_flat                       (mul_array, scatter 전용 cycle)     +1
 │ DSP AREG/BREG→MREG→PREG                                                       +3
 │ wino_lane_reduce(comb) → pre_q/pim_q     (★G-1)                               +1
 │ gather 2+2: gpab=lane{0,1}, gpcd=lane{2,3} (reg, free-run)                    +1
 │ cross-lane gpre/gpim(comb) → gpre_q/gpim_q (★C-1)                             +1
 │ grp0: acc<=gpre_q/gpim_q  |  grp1: msum=acc+gp → m_assemble → m_*_flat latch  2-cyc
 ▼ m_valid                                                              ★ issue+12
 │ wino_output_transform 4-stage → ot_valid                                      +4
 │ wino_truncate(en=ot_valid)                                                    +1
 │ collector: tile_out[bank][pix][oc] (cwe, coc=tg_*[16])                        +1
 ▼ tile_out → writer(tile_done) → c2pool
```

### 2.1 ★★ Latency anchor (수정 시 반드시)
| anchor | 값 |
|---|---|
| **issue → m_valid** | **+12** (IT3 +2 / a_q +1 / DSP 3 / pre_q +1 / gp쌍 +1 / gpre_q +1 / grp 2-cyc / ★carry-bisect +1) |
| m_valid → ot_valid | +4 (OT) → trunc +1 → collector +1 |
| tag pipe 깊이 / collector index | **16** / `tg_*[16]` |

> ⚠️ **M 경로 latency 를 ±1 바꾸면**(파이프 단 가감): ①`tg_*` 깊이 ②shift 루프 상한
> ③collector `tg_*[N]` 를 **셋 다 ±1**. cyc/img 도 ±1(DRAIN tail). **2026-06-15 carry-bisect 적용**
> (M 경로 im 25-bit add 를 13+12 분할, +1 lat): m_valid issue+11→**+12**, tag 15→**16**, tg_*[15]→**[16]**,
> 1348→**1349**. ★버그=`-sim` low `~a+~b+2` 가 2¹⁴ 도달→hi 로 carry 2 가능, `car_n` 2-bit 필수
> (standalone `tb_conv2_winograd_engine_multi` 가 먼저 잡음 → full 100/100).

---

## 3. ★★ 복소 MAC + 켤레확장 `m_assemble` — HW 매핑 (수학근거는 algorithm 문서)

복소/켤레대칭의 **수학적 도출**은 `algorithm_complex_f43.md` (§9.1 행렬, §8). 여기선 그게
**RTL 에서 어떻게 배선되는가**(= 2026-06-15 bisect 가 틀린 지점)만:

### 3.1 `wino_m_assemble.v`: 26 계산값 → 36 M (곱셈기 0)
입력 `sre/sim[0:25]`(=msum_re/msum_im). real 16(`mim=0`) / cmul 10(`mim=+sim[k]`) /
conj 10(`mim=-sim[k]`, 켤레=허수부 negate). **cmul k(16..25) ↔ 위치** (하드코딩 시 오류 주의):
```
k :  16  17  18  19  20  21  22  23  24  25
+ :   3   9  15  18  19  20  21  22  23  33   (cmul,  mim=+sim[k])
- :   4  10  16  24  25  26  28  27  29  34   (conj,  mim=-sim[k])  ← k22→28, k23→27 교차
```

### 3.2 grp0/grp1 2-cycle 누적 (engine, `mul_en_q4` gated)
- grp0(`grp_pipe[5]==0`): `acc <= gpre_q/gpim_q` (IC0-3 park).
- grp1(`grp_pipe[5]==1`): `msum=acc+gpre_q/gpim_q`(8-IC) → `m_assemble` → `m_*_flat` latch, `m_valid=1`.
- ⚠️ grp1 cycle 에 `acc`(grp0)·`gpim_q`(grp1) 동시 유효, **다음 oc grp0 가 grp1+1 에 acc 덮어씀**
  → reduce-tail 재타이밍 시 operand 유효 cycle **snapshot 필수**.

### 3.3 ★ bisect 가 안 된 이유 (재시도 시)
`m_im[conj]=-(acc+gp)` = 25-bit `~a+~b+2` **단일 carry chain**(7×CARRY4). negate 는 입력반전
fused → **negate-fold 무효**(반례: 순수 add `gpab_im→gpim_q` 도 −0.037 실패). 13+12 bisect(+1
latency)는 방향은 맞으나 §3.2 정렬 + §2.1 tag 재정렬이 얽혀 **full-pipe 0/100 원인격리 불가** →
**재시도는 standalone TB 로 reduce-tail 단독부터** (§5).

---

## 4. FSM → datapath 신호 맵 (FSM 자체 상태표·전이·counter 의미는 timing §7)

> FSM 상태(IDLE…DRAIN)·producer(PIDLE/PLOAD/**PDRAIN** §5.1)·counter 범위·전이조건 = **timing §7**
> (현행과 동일, 미복제). 여기선 **제어→datapath 경계 신호**만 (= 다음 FSM 모듈분리 §6 의 포트):

| 신호 | 방향 | datapath 소비처 |
|---|---|---|
| `compute_cnt` | FSM→ | tag pipe(`issue_oc=[4:1]`), IT d-mux(`grp=[0]`) |
| `compute_cnt_nxt` (조합) | FSM→ | `compute_cnt_l` 4-copy **lockstep** (지연 0 — 단순 `<=compute_cnt` 면 깨짐) |
| `tile_cnt`/`trow_cnt` | FSM→ | rb read(rd_tx/rd_set=[0]) + tag pipe + write set |
| `mul_en`/`mul_grp` | FSM→ | engine 이 `mul_*_q4`(+4) 로 파이프 → DSP CE/grp |
| `pw_v2/set2/row2/col2` | FSM→ | `u_rb` write (`wr_en/set/row/col`, data=c1c2_dout) |
| `output_bank_sel` | FSM→ | writer c2pool addr |
| `c1c2_re`/`c1c2_addr`/`rdone`/`loader_start` | FSM→port/loader | 외부 read / conv1 handshake / weight load |
| `wdone`(writer) / `loader_done` | datapath→FSM | after_diff·bank toggle / LOAD_WEIGHTS 종료 |

---

## 5. ★ 안전 수정 gate
1. **2단계 bit-exact** (둘 다 통과해야 머지):
   - **standalone** `tb_conv2_winograd_engine_multi` — **reduce-tail/FSM 수정은 여기서 먼저**
     (full-pipe 0/100 은 원인격리 불가 = bisect 교훈).
   - **full** `tb_cnn_accelerator_winograd_multi` (logit+readback).
   - iverilog 명령 = 각 TB 헤더.
2. **latency 바꾸면 §2.1 anchor 3곳 동시 수정.**
3. 재타이밍 reg 는 tile당 상수면 reset-free 가능하나 **CE 에 max_fanout = control set 면적 지불**(plan §2.0).
4. **동일신호 다중 copy 엔 `keep` 필수** (equiv-merge — wm_*_q 교훈).

## 6. (예정) FSM 모듈 분리
§4 신호맵 경계로 `conv2_winograd_fsm.v` 추출 (baseline `RTL/conv2/conv2_fsm.v` 미러: control plane
분리, datapath·fanout복제reg 잔류). 순수 relocation(bit-exact). 목적 = control-datapath 경계
수정을 standalone 단독 디버그 가능하게. **현재 보류** (먼저 본 문서로 구조 고정).
