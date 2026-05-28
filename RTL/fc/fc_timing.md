# FC Cycle-by-Cycle Timing

`fc_engine` 의 cycle 별 동작 timing 기록. conv2_timing.md 의 FC 버전.

**용도**:
- Testbench 결과 검증 (cycle 별 register 값 1:1 대조)
- Timing 변경 (BRAM L, pipeline depth, FSM 수정) 시 파급 효과 추적
- pe_en / adder_en / acc_en alignment 검증

**표의 모든 셀은 "해당 cycle 시작 시점에서의 register 값"** (= 직전 edge 에서 latch 된 값). 조합 신호 (`comp_v`, BRAM addr, `poolfc_dout`, `p_dsp` 등) 는 그 cycle 의 register 값으로 즉시 계산되는 값.

본 doc 의 cycle 0 (= cycle T) = **COMPUTE state 첫 cycle** (DONE → COMPUTE 전이 직후 첫 cycle, `state == COMPUTE && s_cnt == 0 && pair_cnt == 0` 인 cycle).

---

## 0. 약속

### 0.1 좌표 / register 의미

| Symbol | 의미 |
|---|---|
| `s_cnt` | spatial index, 0..143 (144개). 한 pair 처리 단위. |
| `pair_cnt` | output pair index, 0..4 (5개). 한 pair = 2 OC (even + odd). |
| `wbase` | weight base addr, `pair_cnt * 144`. |
| `sp(p, S)` | "pair p 의 spatial S" 데이터. 단순화 위해 같은 pair 내에서는 `spS` 표기. |
| `comp_v` | FSM 의 compute valid 신호 (combinational, `state == COMPUTE`). |
| `s_first` | `(state == COMPUTE && s_cnt == 0)`. pair 시작 marker. |
| `s_last` | `(state == COMPUTE && s_cnt == 143)`. pair 종료 marker. |

### 0.2 BRAM L

`bram_pool_to_fc` 와 `fc_weight_bram` 모두 **L=1** 으로 확정 (2026-05-29).
`docs/ip_spec/block_memory_generator.md` §4 (`bram_pool_to_fc`) 및 §1 표 (`fc_weight_bram`) 참조.

```
addr@T → doutb@T+1
```

L 변경 시 본 문서의 cycle offset 및 `CTRL_DELAY` 모두 동기 조정 필요.

### 0.3 PE → accumulator pipeline depth

| Stage | Latency (cycle) | 게이팅 신호 |
|---|---|---|
| BRAM read (L=1) | 1 | `enb = comp_v` |
| `fc_pe_cell` stage 1 (`p_dsp_r` 등록) | 1 | `en = pe_en` |
| `fc_pe_cell` stage 2 (`p0_out` 등록) | 1 | `en = pe_en` |
| `fc_adder_tree` 4-stage (e1 → e2 → e3 → sum0) | 4 | `en = adder_en` |
| `fc_accumulator` (acc0/logit0 등록) | 1 | `en = acc_en` |
| **합계 (comp_v issue @ T → logit 확정 @ T+8)** | **8** | |

**Pipelined 모듈의 `en` 게이팅 원칙** (conv2_timing.md §0.4 와 동일): 각 register stage 가 `en` 으로 게이팅됨. 마지막 valid 입력이 끝단 register 까지 propagate 하려면 `en=1` 이 **pipeline depth 만큼 cycle 연속 유지**되어야 함.

→ `pe_en` = 2-cycle window (PE 2-stage), `adder_en` = 4-cycle window (adder 4-stage), `acc_en` = 1-cycle pulse (acc 1-stage).

### 0.4 comp_pipe 인덱싱

```verilog
always @(posedge clk) begin
    comp_pipe[0]  <= fsm_comp_v;
    comp_pipe[1]  <= comp_pipe[0];
    ...
    comp_pipe[7]  <= comp_pipe[6];
end
```

`comp_pipe[k] @ cycle C = fsm_comp_v @ cycle (C − k − 1)` (1-cycle 등록 지연부터 시작).

즉:
- comp_pipe[0] @ T+1 = comp_v @ T = 1 (comp_v 가 cycle T 부터 1 이면)
- comp_pipe[1] @ T+2 = comp_v @ T = 1
- comp_pipe[k] @ T+k+1 = comp_v @ T = 1

본 문서에서는 항상 "**comp_pipe[k] 는 N=k+1 cycle 지연**" 으로 표기.

### 0.5 FSM 상태

4 states (`fc_fsm.v`):

```
IDLE → COMPUTE → DRAIN → DONE → IDLE
```

| 상태 | 길이 | comp_v | shift_en 등가 | 비고 |
|---|---|---|---|---|
| IDLE | 가변 (start && data_ready 대기) | 0 | — | `start && data_ready` 충족 시 COMPUTE 진입 |
| COMPUTE | 720 cycle (5 pair × 144 spatial) | 1 | — | s_cnt 0..143 5번 반복, 매 pair 마다 wbase += 144 |
| DRAIN | DRAIN_MAX = 8 cycle | 0 | — | pipeline drain 만, comp_v 사라진 후 마지막 데이터 통과 대기 |
| DONE | 1 cycle | 0 | — | 다음 IDLE 로 |

### 0.6 Handshake counter (conv2 와 비교)

| 항목 | Conv2 | FC |
|---|---|---|
| 입력 측 (prior) | `prior_diff` signed 3-bit | `prior_diff` signed 3-bit |
| 출력 측 (after) | `after_diff` signed 3-bit | 없음 (terminal) |
| `data_ready` | `prior_diff < 0` | `prior_diff < 0` |
| `output_avail` | `after_diff < 2` | 항상 true |
| `input_bank_sel` toggle | `rdone` 시 | `rdone` 시 |
| `output_bank_sel` toggle | `wdone` 시 | N/A |

FC 는 마지막 layer 라 출력 측 handshake 불필요. argmax 결과를 `class_idx` / `class_valid` 로 직출.

---

## 1. COMPUTE 진입 — 첫 spatial (cycle T-1 ~ T+8)

### 1.1 게이팅 alignment (2026-05-29 수정 완료)

```
T+0 : comp_v=1 발행, BRAM addr=0 출력
T+1 : BRAM doutb 유효 (sp0 데이터) → PE input 유효
T+2 : PE stage 1 (p_dsp_r) 등록 — pe_en@T+1=1 필요
T+3 : PE stage 2 (p0_out) 등록 — pe_en@T+2=1 필요
T+4 : adder e1 등록 — adder_en@T+3=1 필요
T+5 : adder e2 등록
T+6 : adder e3 등록
T+7 : adder sum0 등록 — adder_en@T+6=1 필요
T+8 : acc 등록 (acc0 += sum0) — acc_en@T+7=1 필요
```

→ **pe_en window**: cycle T+1, T+2 (= `comp_pipe[0] | comp_pipe[1]`)
→ **adder_en window**: cycle T+3 ~ T+6 (= `comp_pipe[2..5]`)
→ **acc_en pulse**: T+7 (= `comp_pipe[6] = comp_pipe[CTRL_DELAY]`)

`CTRL_DELAY = 6`.

```verilog
wire pe_en    = comp_pipe[0] | comp_pipe[1];                        // T+1, T+2
wire adder_en = comp_pipe[2] | comp_pipe[3]
              | comp_pipe[4] | comp_pipe[5];                        // T+3..T+6
wire acc_en   = comp_pipe[CTRL_DELAY];                              // T+7
```

### 1.2 Trace — pair 0 첫 spatial (수정 후)

`spS` = pair 0 의 spatial S. `—` = irrelevant. 셀은 cycle 시작 시점 register 값.

| Cyc | state | s_cnt | comp_v | enb | addr | doutb | x_flat | pe_en | p_dsp_r | p0_out | adder_en | e1 | e2 | e3 | sum0 | acc_en | clear | last | acc0 | 비고 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T-1 | IDLE | 0 | 0 | 0 | — | hold | — | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 마지막 IDLE |
| T+0 | COMP | 0 | **1** | 1 | 0 | hold | — | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | comp_v 첫 cycle, BRAM 읽기 시작 |
| T+1 | COMP | 1 | 1 | 1 | 1 | **sp0** | sp0 | **1** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | pe_en=1 (comp_pipe[0]) ✓ |
| T+2 | COMP | 2 | 1 | 1 | 2 | sp1 | sp1 | 1 | **sp0** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | sp0 stage1 latch ✓ |
| T+3 | COMP | 3 | 1 | 1 | 3 | sp2 | sp2 | 1 | sp1 | **sp0** | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | sp0 stage2 latch ✓; adder_en@T+3=1 |
| T+4 | COMP | 4 | 1 | 1 | 4 | sp3 | sp3 | 1 | sp2 | sp1 | 1 | **sp0** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | sp0 adder e1 latch ✓ |
| T+5 | COMP | 5 | 1 | 1 | 5 | sp4 | sp4 | 1 | sp3 | sp2 | 1 | sp1 | **sp0** | 0 | 0 | 0 | 0 | 0 | 0 | |
| T+6 | COMP | 6 | 1 | 1 | 6 | sp5 | sp5 | 1 | sp4 | sp3 | 1 | sp2 | sp1 | **sp0** | 0 | 0 | 0 | 0 | 0 | |
| T+7 | COMP | 7 | 1 | 1 | 7 | sp6 | sp6 | 1 | sp5 | sp4 | 1 | sp3 | sp2 | sp1 | **sp0** | 1 | **1** | 0 | 0 | acc first sample: acc_en=1, clear=1 (s_first 7-cycle 지연 도달) |
| T+8 | COMP | 8 | 1 | 1 | 8 | sp7 | sp7 | 1 | sp6 | sp5 | 1 | sp4 | sp3 | sp2 | sp1 | 1 | 0 | 0 | **sp0** | clear=1 효과: acc0 <= sp0 ✓ |
| T+9 | COMP | 9 | 1 | 1 | 9 | sp8 | sp8 | 1 | sp7 | sp6 | 1 | sp5 | sp4 | sp3 | sp2 | 1 | 0 | 0 | sp0+sp1 | 누산 시작 |

### 1.3 일반화 invariant (steady-state, sp0..sp143)

| Stage | 도달 cycle (sp S 입력) | 게이팅 |
|---|---|---|
| BRAM addr issue | T+S | `comp_v` |
| doutb 유효 | T+S+1 | — |
| PE stage 1 latch (p_dsp_r) | T+S+2 | `pe_en@T+S+1=1` |
| PE stage 2 latch (p0_out) | T+S+3 | `pe_en@T+S+2=1` |
| adder e1 | T+S+4 | `adder_en@T+S+3=1` |
| adder e2 | T+S+5 | |
| adder e3 | T+S+6 | |
| adder sum0 | T+S+7 | `adder_en@T+S+6=1` |
| acc 누산 (acc0 += sum0) | T+S+8 | `acc_en@T+S+7=1` |

→ **모든 S = 0..143 정상 처리**.

---

## 2. Pair 0 종료 / Pair 1 진입 — boundary (cycle T+143 ~ T+152)

### 2.1 핵심 이벤트

- `s_last = 1` at cycle T+143 (pair 0 마지막 spatial)
- `s_first = 1` at cycle T+144 (pair 1 첫 spatial, s_cnt 0 wrap)
- `comp_v` 는 COMPUTE state 동안 끊김 없이 1 (pair 사이 gap 없음)
- pair 0 sp143 sum0 도달: cycle T+150
- pair 0 logit_valid pulse: cycle T+151 (acc_last edge 다음 cycle)
- pair 1 acc_clear pulse: cycle T+151 (= acc_last 와 동일 cycle; accumulator 의 last+clear 양립 분기 사용 안 함)

### 2.2 Trace — pair 0 후반 + pair 1 첫 spatial (수정 후)

`sp_pK_S` = pair K 의 spatial S. acc0 column 의 셀 값은 "**cycle 시작 시점**의 register 값" (= 직전 edge 에서 latch). logit_valid 는 edge 에서 1 로 set 되어 그 다음 cycle 부터 1.

| Cyc | s_cnt | pair_cnt | wbase | s_first | s_last | doutb | p0_out | sum0 | acc0 | acc_en | clear | last | logit0 | logit_valid | 비고 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T+143 | 143 | 0 | 0 | 0 | **1** | sp141(p0) | sp140(p0) | sp136(p0) | Σsp0..sp135 (p0) | 1 | 0 | 0 | 0 | 0 | last_pipe[0] <= 1 |
| T+144 | 0 | 1 | **144** | **1** | 0 | sp142(p0) | sp141(p0) | sp137(p0) | Σsp0..sp136 (p0) | 1 | 0 | 0 | 0 | 0 | pair 1 시작 (addr=0, weight wbase=144) |
| T+145 | 1 | 1 | 144 | 0 | 0 | sp143(p0) | sp142(p0) | sp138(p0) | Σsp0..sp137 (p0) | 1 | 0 | 0 | 0 | 0 | p0 sp143 doutb 도달 |
| T+146 | 2 | 1 | 144 | 0 | 0 | **sp0(p1)** | sp143(p0) | sp139(p0) | Σsp0..sp138 (p0) | 1 | 0 | 0 | 0 | 0 | p0 sp143 stage1 latch; p1 sp0 doutb 도달 |
| T+147 | 3 | 1 | 144 | 0 | 0 | sp1(p1) | **sp0(p1)** | sp140(p0) | Σsp0..sp139 (p0) | 1 | 0 | 0 | 0 | 0 | p1 sp0 stage2 latch ✓ |
| T+148 | 4 | 1 | 144 | 0 | 0 | sp2(p1) | sp1(p1) | sp141(p0) | Σsp0..sp140 (p0) | 1 | 0 | 0 | 0 | 0 | adder e1 = p1 sp0 |
| T+149 | 5 | 1 | 144 | 0 | 0 | sp3(p1) | sp2(p1) | sp142(p0) | Σsp0..sp141 (p0) | 1 | 0 | 0 | 0 | 0 | |
| T+150 | 6 | 1 | 144 | 0 | 0 | sp4(p1) | sp3(p1) | **sp143(p0)** | Σsp0..sp142 (p0) | 1 | 0 | **1** | 0 | 0 | last_pipe[6]@T+150 = 1; sum0 = sp143(p0) ✓ |
| T+151 | 7 | 1 | 144 | 0 | 0 | sp5(p1) | sp4(p1) | sp0(p1) | **Σsp0..sp143 (p0)** | 1 | **1** | 0 | **Σsp0..sp143 (p0)** | **1** | edge T+150→T+151 latch: `logit0 <= acc0_OLD + sum0_OLD` = sp0..sp143 ✓; acc0 <= sum0@T+150 = sp0(p1) via clear (다음 edge) |
| T+152 | 8 | 1 | 144 | 0 | 0 | sp6(p1) | sp5(p1) | sp1(p1) | **sp0(p1)** | 1 | 0 | 0 | Σsp0..sp143 (p0) | 0 | edge T+151→T+152: acc0 <= sum0@T+151 = sp0(p1) (clear=1). p1 sp0 보존 ✓ |
| T+153 | 9 | 1 | 144 | 0 | 0 | sp7(p1) | sp6(p1) | sp2(p1) | sp0(p1)+sp1(p1) | 1 | 0 | 0 | Σsp0..sp143 (p0) | 0 | p1 누산 시작 |

### 2.3 관찰

**pair 0 logit0** = Σ sp0..sp143 (p0) — 모든 spatial 정상 포함 ✓
**pair 1 logit0** = (cycle T+295 에 동일 패턴으로) Σ sp0..sp143 (p1) ✓

**핵심 수정 2 가지가 함께 동작하는 이유**:
1. `pe_en = comp_pipe[0] | comp_pipe[1]` → sp0 가 PE pipeline 에 진입 (T+1 부터 게이팅 ON).
2. `logit0 <= acc0 + sum0` → acc_last cycle 에 acc0_OLD 가 sp0..sp142 만 갖고 있어도 sum0 (= sp143) 까지 combinational add 로 logit 에 반영.

**clear 와 last 의 cycle 정렬**:
- last_pipe[6]@T+150 = 1 (pair 0).
- first_pipe[6]@T+151 = 1 (pair 1).
- → **다른 cycle 에 fire**. accumulator 의 "if clear and last" 분기 (logit <= sum0) 는 trigger 되지 않음 ✓.

---

## 3. DRAIN → DONE → 최종 출력 (cycle T+719 ~ T+729)

### 3.1 상태 전이

- `s_cnt == 143 && pair_cnt == 4` at cycle T+719 → edge T+719→T+720: state ← DRAIN
- `drain_cnt` 0..7 (DRAIN_MAX = 8), edge T+727→T+728: state ← DONE
- DONE state 1 cycle, edge T+728→T+729: state ← IDLE

### 3.2 pair 4 logit 확정 timeline (CTRL_DELAY=6)

pair 4 의 s_last = 1 at cycle T+719. last_pipe[6]@T+726 = 1.

| Cyc | state | drain_cnt | sum0 | acc0 (cycle 시작) | acc_en | last | logit0 | logit_valid | acc_pair_latch | all_ready | class_idx | class_valid |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T+719 | COMP | — | sp135(p4) | Σsp0..sp134 (p4) | 1 | 0 | — | 0 | (이전 pair) | 0 | — | 0 |
| T+720 | DRAIN | 0 | sp136(p4) | Σsp0..sp135 (p4) | 1 | 0 | — | 0 | (이전 pair) | 0 | — | 0 |
| ... | DRAIN | 1..5 | ... | ... | 1 | 0 | — | 0 | (이전) | 0 | — | 0 |
| T+726 | DRAIN | 6 | **sp143(p4)** | Σsp0..sp142 (p4) | 1 | **1** | — | 0 | (이전) | 0 | — | 0 |
| T+727 | DRAIN | 7 | (hold) | Σsp0..sp143 (p4) | 0 | 0 | **Σsp0..sp143 (p4)** | **1** | **4** | 0 | — | 0 |
| T+728 | DONE | — | (hold) | (hold) | 0 | 0 | Σsp0..sp143 (p4) | 0 | 4 | **1** | — | 0 |
| T+729 | IDLE | — | (hold) | (hold) | 0 | 0 | Σsp0..sp143 (p4) | 0 | 4 | 0 | **best_idx** | **1** |

### 3.3 DRAIN_MAX 적정성

- 마지막 PE valid input cycle = T+721 (drain_cnt=1; pe_en@T+721 = comp_pipe[1] = comp_v@T+719 = 1 의 마지막 cycle. p0_out@T+722 = pair 4 sp143).
- 마지막 sum0 갱신 cycle = T+726 (= sp143 도달).
- acc_last fire = T+726. logit0 latch + logit_valid set = edge T+726→T+727.
- argmax class_valid fire = cycle T+729 (= state IDLE 진입 cycle).

DRAIN_MAX=8 → DRAIN 7 cycles + DONE 1 cycle = 마지막 pipeline drain (sum0 갱신) 까지 안전 cover. DRAIN_MAX=7 로 줄여도 logit 확정 자체에는 영향 없음 (margin 만 1 cycle 감소).

### 3.4 class_valid vs state

class_valid pulse (cycle T+729) 는 state=IDLE 진입과 같은 cycle. 외부 PS 가 `class_valid` polling 으로 결과 capture 하면 무해. 다음 image 의 `start` pulse 는 IDLE state 에서 처리됨.

---

## 4. Handshake — maxpool 패턴 (race-free, 2026-05-29)

### 4.1 prior_diff counter (입력 측, race-free)

```verilog
// next-value combinational 계산
always @(*) begin
    case ({rdone, prior_wdone})
        2'b10:   prior_diff_next = prior_diff + 1;   // 내가 처리 끝남
        2'b01:   prior_diff_next = prior_diff - 1;   // 상대가 보내옴
        2'b11:   prior_diff_next = prior_diff;       // simultaneous → cancel
        default: prior_diff_next = prior_diff;
    endcase
end

wire data_ready = (prior_diff_next < 0);              // ★ next 기준 평가

always @(posedge clk) prior_diff <= prior_diff_next;
```

**왜 next-value?** NBA 의 1-cycle 지연으로 인해 같은 cycle 의 rdone/prior_wdone 이 prior_diff 에 즉시 반영 안 됨. data_ready 가 stale prior_diff 를 보면 race. `prior_diff_next` (combinational) 은 그 cycle 의 rdone/prior_wdone 즉시 반영 → race-free.

상세: [docs/handshake_counter_nba_race.md](../../docs/handshake_counter_nba_race.md)

### 4.2 rdone 생성

```verilog
rdone <= (state == COMPUTE) && (pair_cnt == 4) && (s_cnt == 143);
```

→ cycle T+719 에 조건 fire, edge T+719→T+720 에 `rdone <= 1`. cycle T+720 에 rdone=1 pulse (1-cycle).

cycle T+720 의 rdone=1 와 state=DRAIN 진입이 같은 edge → 무해 (handshake counter 는 다음 edge 에 update).

### 4.3 input_bank_sel toggle

```verilog
if (rdone) input_bank_sel <= ~input_bank_sel;
```

cycle T+720 에 rdone=1 → edge T+720→T+721 에 input_bank_sel toggle. 다음 image 부터 새 bank read.

→ ping-pong handshake 패턴 자체는 conv2 와 정합.

### 4.4 차이점 / 누락 검토

| 항목 | Conv2 | FC | 의도 정합? |
|---|---|---|---|
| 입력 측 prior_diff/rdone/input_bank_sel | ✓ | ✓ | ✓ |
| 출력 측 after_diff/wdone/output_bank_sel | ✓ | ✗ | ✓ (FC=terminal) |
| **NBA race fix (`prior_diff_next` 사용)** | ⚠ 미적용 (우연히 PASS) | **✅ 적용 (2026-05-29)** | maxpool 패턴 적용 |
| LOAD_WEIGHTS state | ✓ (loader_done 대기) | ✗ (PS 직접 write) | ⚠ FC weight 는 PS 가 csr 통해 직접 write 가정. weight loader 모듈 없음. |
| FSM busy 출력 | ✗ | ✓ (미사용) | ⚠ 외부 결선 없음. 제거 가능. |
| DRAIN 진입 조건 | output_pixel_cnt == 575 | s_cnt == 143 && pair_cnt == 4 | ✓ |

### 4.5 Race-free 검증 — `prior_wdone` 과 `start` 같은 edge

| Cyc | state | rdone | prior_wdone | start | prior_diff (reg) | prior_diff_next (comb) | data_ready | 결정 |
|---|---|---|---|---|---|---|---|---|
| T-1 | IDLE | 0 | 0 | 0 | 0 | 0 | 0 | wait |
| **T** | IDLE | 0 | **1** | **1** | 0 (NBA 안 됨) | **−1** ← prior_wdone 즉시 반영 | **1** | `start && data_ready = 1` → COMPUTE 진입 ✓ |
| T+1 | COMPUTE | 0 | 0 | 0 | **−1** ← NBA 적용 | −1 | 1 | computing |

**수정 전 (race-prone)** 이었다면 cycle T 에서 `data_ready = (0 < 0) = 0` 으로 start 손실. 수정 후 정상.

대칭 race (false positive) 도 같은 메커니즘으로 봉쇄 (rdone 와 IDLE 진입 같은 cycle 시): FC 는 DRAIN+DONE buffer 로 rdone 와 IDLE 진입이 9 cycle 떨어져 있어 원래도 없었지만, 동일 패턴이라 추가 보호.

---

## 5. 수정 이력 (2026-05-29)

### 5.1 수정 전 증상

- **각 pair 의 sp0 누락**: `pe_en = comp_pipe[1] | comp_pipe[2]` → cycle T+1 에 pe_en=0 → sp0 가 PE pipeline 에 진입 못함.
- **각 pair 의 sp143 누락**: acc_last cycle 에 sum0 = sp143 이지만 acc0_OLD 는 sp1..sp142. `logit0 <= acc0_OLD` 가 sp143 contribution 못 포함.
- 결과: 각 pair logit = Σsp1..sp142 (sp0 & sp143 모두 누락 가능성).

### 5.2 latent bug mask 사유

`maxpool_output.hex` (= `data/single_img/maxpool_output.hex`) 의 spatial 0 = 16 ch 모두 0. MNIST corner pixel 이 maxpool 후 0 인 특성. TB 가 우연히 PASS 했지만 sp0 ≠ 0 인 입력 (다른 image, conv 결과 분포 다름) 에서는 mismatch 발생 가능.

### 5.3 수정 내용

**fc_engine.v** (§1 의 게이팅 1-cycle 앞당김):

```verilog
localparam CTRL_DELAY = 6;   // 7 → 6

wire pe_en    = comp_pipe[0] | comp_pipe[1];                         // T+1, T+2 (sp0 진입 보장)
wire adder_en = comp_pipe[2] | comp_pipe[3] | comp_pipe[4]
              | comp_pipe[5];                                         // T+3..T+6
wire       acc_en    = comp_pipe [CTRL_DELAY];                        // T+7
wire       acc_clear = first_pipe[CTRL_DELAY];
wire       acc_last  = last_pipe [CTRL_DELAY];
wire [2:0] acc_pair  = pair_pipe [CTRL_DELAY];
```

**accumulator.v** (last cycle 에 sum0 까지 logit 에 반영):

```verilog
if (last) begin
    if (clear) begin
        logit0 <= $signed(sum0);
        logit1 <= $signed(sum1);
    end else begin
        logit0 <= acc0 + $signed(sum0);   // ← acc0 + sum0 (combinational)
        logit1 <= acc1 + $signed(sum1);
    end
    logit_valid <= 1'b1;
end
```

### 5.4 수정 후 검증 권장

1. 기존 `tb_fc_engine.v` (`data/single_img/maxpool_output.hex` 로 hex 경로 업데이트 필요) → 그대로 PASS 해야 함 (sp0=0 이므로 영향 없음).
2. sp0 ≠ 0 인 합성 입력으로 TB 재실행 (Python reference 와 비교) → 수정 전 FAIL, 수정 후 PASS 확인.
3. conv1+conv2+maxpool 합동 TB 와 통합 → end-to-end class_idx 정확성 검증.

---

## 6. Verification anchors 요약 (수정 후)

| # | Cycle | 검증 항목 | 기대값 |
|---|---|---|---|
| A1 | T+1 | sp0 PE pe_en | 1 (comp_pipe[0]@T+1=comp_v@T=1) |
| A2 | T+2 | p_dsp_r | sp0 (stage1 latch) |
| A3 | T+3 | p0_out | sp0 (stage2 latch) |
| A4 | T+7 | acc first sample (clear=1) | sum0 = sp0; edge T+8 에 acc0 ← sp0 |
| A5 | T+150 | pair 0 last sample | sum0 = sp143(p0), acc_last=1, acc0_OLD = Σsp0..sp142 |
| A6 | T+151 | pair 0 logit_valid pulse | logit0 = Σsp0..sp143 (p0) (= acc0_OLD + sum0_OLD via accumulator combinational add) |
| A7 | T+151 | pair 1 acc_clear | acc0 ← sum0@T+151 = sp0(p1) (clear=1 효과로 pair 1 새 누산 시작) |
| A8 | T+720 | DRAIN 진입 | state=DRAIN, rdone=1 pulse (edge T+719→T+720) |
| A9 | T+726 | pair 4 acc_last | sum0 = sp143(p4), acc0_OLD = Σsp0..sp142(p4) |
| A10 | T+727 | pair 4 logit_valid pulse | logit0 = Σsp0..sp143 (p4); acc_pair_latch ← 4 |
| A11 | T+728 | DONE 진입 + all_ready=1 | state=DONE (1 cycle), argmax in_valid=1 |
| A12 | T+729 | IDLE 진입 + argmax class_valid | class_idx = best, class_valid=1 (1-cycle pulse) |

---

## 7. 관련 문서

| 파일 | 역할 |
|---|---|
| `fc_engine.v` | top-level RTL (FSM 인스턴스 + datapath + comp_pipe + argmax) |
| `fc_fsm.v` | FSM RTL (4 state, s_cnt/pair_cnt/wbase, handshake) |
| `pe_cell.v` | DSP48E1 SIMD packing 2-stage PE |
| `pe_array_fc.v` | 16-lane PE array |
| `adder_tree.v` | 4-stage 16:1 adder tree |
| `accumulator.v` | 144-spatial 누산기 + logit_valid |
| `argmax.v` | 10-class argmax + class_idx 출력 |
| `tb_fc_engine.v` | pre-argmax logit 검증 TB |
| `../conv2/conv2_timing.md` | conv2 cycle-by-cycle reference (handshake 패턴 원본) |
| `../../docs/ip_spec/block_memory_generator.md` | BMG IP spec (`bram_pool_to_fc`, `fc_weight_bram` TBD) |

---

## 8. 변경 이력

| Date | Change |
|---|---|
| 2026-05-28 | 초안. BRAM L=1 가정으로 pe_en/adder_en/acc_en 의 1-cycle late 게이팅 분석. `maxpool_output.hex` 의 sp0=0 으로 인한 latent bug mask 확인. spatial 0 non-zero 입력으로 재현 / 수정안은 §5 참조. |
| 2026-05-29 | BMG IP spec 확정 (`bram_pool_to_fc`, `fc_weight_bram` 모두 L=1). §5.3 수정안 적용: `CTRL_DELAY=6`, `pe_en`/`adder_en`/`acc_en` 인덱스 1 cycle 앞당김. accumulator.v 의 `last && !clear` 분기 를 `logit <= acc + sum` 으로 변경하여 sp143 contribution 포함. §1~§3, §6 anchors 모두 수정 후 timing 기준으로 재작성. |
| 2026-05-29 (b) | Handshake counter NBA race fix 적용 — `prior_diff_next` combinational 으로 노출, `data_ready` 가 next 값 기준 평가. maxpool 패턴 차용 (docs/handshake_counter_nba_race.md §5 참조). 같은 cycle 에 `prior_wdone` + `start` 동시 도달 시 start 손실 race 해소. §4 handshake 섹션 재작성. |
