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

### 0.2 BRAM L (현재 가정 — TBD)

`fc_engine.v` 주석 및 `tb_fc_engine.v` 의 BRAM 모델은 **L=1 가정**:

```
addr@T → doutb@T+1
```

단, `docs/ip_spec/block_memory_generator.md` 에 `bram_pool_to_fc`, `fc_weight_bram` 의 실제 Vivado BMG IP spec 이 TBD (line 19-20). L=2 로 변경 시 본 문서의 cycle offset 모두 +1.

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

⚠️ "delayed N" 이라는 표현은 모호함. 본 문서에서는 항상 "**comp_pipe[k] 는 N=k+1 cycle 지연**" 으로 표기. fc_engine.v 의 line 134-137 주석은 "delayed N" 을 "N register stages" 로 쓰고 있으나, 실제 게이팅 cycle 과 1 cycle 차이.

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

### 1.1 의도된 timing (fc_engine.v 주석 기반)

```
T+0 : comp_v=1 발행, BRAM addr=0 출력
T+1 : BRAM doutb 유효 (sp0 데이터) → PE input 유효
T+2 : PE stage 1 (p_dsp_r) 등록 — pe_en@T+1=1 필요
T+3 : PE stage 2 (p0_out) 등록 — pe_en@T+2=1 필요
T+4 : adder e1 등록 — adder_en@T+3=1 필요
T+5 : adder e2 등록
T+6 : adder e3 등록
T+7 : adder sum0 등록 — adder_en@T+6=1 필요
T+8 : acc 등록 — acc_en@T+7=1 필요
```

→ **pe_en 필요 window**: cycle T+1, T+2 (= `comp_pipe[0] | comp_pipe[1]`)
→ **adder_en 필요 window**: cycle T+3 ~ T+6 (= `comp_pipe[2..5]`)
→ **acc_en 필요 cycle**: T+7 (= `comp_pipe[6]`)

### 1.2 실제 코드 게이팅

```verilog
wire pe_en    = comp_pipe[1] | comp_pipe[2];   // T+2, T+3
wire adder_en = comp_pipe[3] | comp_pipe[4]
              | comp_pipe[5] | comp_pipe[6];   // T+4..T+7
wire acc_en   = comp_pipe[7];                  // T+8
```

→ 의도 대비 **모두 1 cycle 늦음**.

### 1.3 결과 trace — pair 0 첫 spatial (현재 코드)

`sp_p_S` = pair p 의 spatial S 데이터/곱셈 결과. `—` = irrelevant. 셀은 cycle 시작 시점 register 값.

| Cyc | state | s_cnt | comp_v | enb | addr | doutb | x_flat | pe_en | p_dsp_r | p0_out | adder_en | e1 | e2 | e3 | sum0 | acc_en | clear | last | acc0 | 비고 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T-1 | IDLE | 0 | 0 | 0 | — | hold | — | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 마지막 IDLE |
| T+0 | COMP | 0 | **1** | 1 | 0 | hold | — | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | comp_v 첫 cycle, BRAM 읽기 시작 |
| T+1 | COMP | 1 | 1 | 1 | 1 | **sp0** | sp0 | **0** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | ⚠ **sp0 PE 미진입 (pe_en=0)** |
| T+2 | COMP | 2 | 1 | 1 | 2 | sp1 | sp1 | 1 | 0 (sp0 missed) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | sp1 p_dsp 조합, 이번 edge 에 stage1 latch (sp1) |
| T+3 | COMP | 3 | 1 | 1 | 3 | sp2 | sp2 | 1 | **sp1** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | stage1 = sp1, stage2 는 다음 edge 에 sp1 load |
| T+4 | COMP | 4 | 1 | 1 | 4 | sp3 | sp3 | 1 | sp2 | **sp1** | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | adder e1 first edge (sp1 load 예정) |
| T+5 | COMP | 5 | 1 | 1 | 5 | sp4 | sp4 | 1 | sp3 | sp2 | 1 | **sp1** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | |
| T+6 | COMP | 6 | 1 | 1 | 6 | sp5 | sp5 | 1 | sp4 | sp3 | 1 | sp2 | **sp1** | 0 | 0 | 0 | 0 | 0 | 0 | |
| T+7 | COMP | 7 | 1 | 1 | 7 | sp6 | sp6 | 1 | sp5 | sp4 | 1 | sp3 | sp2 | **sp1** | 0 | 0 | 0 | 0 | 0 | |
| T+8 | COMP | 8 | 1 | 1 | 8 | sp7 | sp7 | 1 | sp6 | sp5 | 1 | sp4 | sp3 | sp2 | **sp1** | 1 | **1** | 0 | 0 | acc 첫 sample, clear=1 (s_first 8 cycle 지연 도달) |
| T+9 | COMP | 9 | 1 | 1 | 9 | sp8 | sp8 | 1 | sp7 | sp6 | 1 | sp5 | sp4 | sp3 | sp2 | 1 | 0 | 0 | **sp1** | clear=1 효과로 acc0 = sp1 (sp0 누락) |
| T+10 | COMP | 10 | 1 | 1 | 10 | sp9 | sp9 | 1 | sp8 | sp7 | 1 | sp6 | sp5 | sp4 | sp3 | 1 | 0 | 0 | sp1+sp2 | 누산 시작 |

### 1.4 일반화 invariant (steady-state, sp1..sp143)

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

→ **S ≥ 1 인 경우 모두 정상**. S = 0 만 `pe_en@T+1 = 0` 으로 인해 누락.

---

## 2. Pair 0 종료 / Pair 1 진입 — boundary (cycle T+143 ~ T+152)

### 2.1 핵심 이벤트

- `s_last = 1` at cycle T+143 (pair 0 마지막 spatial)
- `s_first = 1` at cycle T+144 (pair 1 첫 spatial, s_cnt 0 wrap)
- `comp_v` 는 COMPUTE state 동안 끊김 없이 1 (pair 사이 gap 없음)
- pair 0 logit 확정: edge T+151 → T+152

### 2.2 Trace (pair 0 후반 + pair 1 첫 spatial)

| Cyc | s_cnt | pair_cnt | wbase | s_first | s_last | doutb | p0_out | sum0 | acc0 | acc_en | clear | last | logit0 | logit_valid | 비고 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T+143 | 143 | 0 | 0 | 0 | **1** | sp142(p0) | sp140(p0) | sp137(p0) | Σsp1..sp136 (p0) | 1 | 0 | 0 | 0 | 0 | last_pipe[0] <= 1 |
| T+144 | 0 | 1 | **144** | **1** | 0 | sp143(p0) | sp141(p0) | sp138(p0) | Σsp1..sp137 (p0) | 1 | 0 | 0 | 0 | 0 | pair 1 시작 (addr 0, weight wbase=144) |
| T+145 | 1 | 1 | 144 | 0 | 0 | **sp0(p1)** | sp142(p0) | sp139(p0) | Σsp1..sp138 (p0) | 1 | 0 | 0 | 0 | 0 | pe_en@T+145 = comp_pipe[1] = comp_v@T+143 = 1 ✓ |
| T+146 | 2 | 1 | 144 | 0 | 0 | sp1(p1) | sp143(p0) | sp140(p0) | Σsp1..sp139 (p0) | 1 | 0 | 0 | 0 | 0 | p1 sp0 stage1 latch ✓ |
| T+147 | 3 | 1 | 144 | 0 | 0 | sp2(p1) | **sp0(p1)** | sp141(p0) | Σsp1..sp140 (p0) | 1 | 0 | 0 | 0 | 0 | p1 sp0 stage2 latch ✓ |
| T+148 | 4 | 1 | 144 | 0 | 0 | sp3(p1) | sp1(p1) | sp142(p0) | Σsp1..sp141 (p0) | 1 | 0 | 0 | 0 | 0 | adder e1 = p1 sp0 |
| T+149 | 5 | 1 | 144 | 0 | 0 | sp4(p1) | sp2(p1) | sp143(p0) | Σsp1..sp142 (p0) | 1 | 0 | 0 | 0 | 0 | |
| T+150 | 6 | 1 | 144 | 0 | 0 | sp5(p1) | sp3(p1) | **sp143(p0)** | Σsp1..sp143 (p0) | 1 | 0 | 0 | 0 | 0 | p0 마지막 partial sum 도달 |
| T+151 | 7 | 1 | 144 | 0 | 0 | sp6(p1) | sp4(p1) | **sp0(p1)** | Σsp1..sp143 (p0) | 1 | 0 | **1** | 0 | 0 | last_pipe[7]=1 도달, but sum0 가 이미 p1 sp0 로 진행 |
| T+152 | 8 | 1 | 144 | 0 | 0 | sp7(p1) | sp5(p1) | sp1(p1) | **Σsp1..sp143 (p0) + sp0(p1)** | 1 | **1** | 0 | **Σsp1..sp143 (p0)** | **1** | edge T+151→T+152 latch: logit0=acc0_old (정상), acc0_new += sp0(p1) (오염), but next edge clear=1 으로 덮어씀 |
| T+153 | 9 | 1 | 144 | 0 | 0 | sp8(p1) | sp6(p1) | sp2(p1) | **sp1(p1)** | 1 | 0 | 0 | Σsp1..sp143 (p0) | 0 | clear=1 효과: acc0 <= sum0@T+152 = sp1(p1). **p1 sp0 acc0 에서 사라짐 (clear 가 덮어씀)** |

### 2.3 관찰

**pair 0 logit0** = Σ sp1..sp143 (p0) → **sp0(p0) 누락**
**pair 1 logit0** = Σ sp1..sp143 (p1) → **sp0(p1) 누락** (clear timing 으로)

→ 모든 pair 가 spatial 0 contribution 을 놓침. pe_en 의 1-cycle late 게이팅이 root cause.

**왜 TB 는 PASS 하나?** `maxpool_output.hex` 의 spatial 0 (line 1) = `00000000000000000000000000000000` (16 ch 모두 0). MNIST 의 corner pixel 이 maxpool 후 0 인 특성. **TB 데이터가 우연히 sp0 = 0 이라 latent bug 가 mask 됨**. spatial 0 ≠ 0 인 입력에서는 mismatch 발생.

---

## 3. DRAIN → DONE (cycle T+720 ~ T+728)

### 3.1 상태 전이

- `s_cnt == 143 && pair_cnt == 4` at cycle T+719 → edge T+719→T+720: state ← DRAIN
- `drain_cnt` 0..7 (DRAIN_MAX = 8), edge T+727→T+728: state ← DONE

### 3.2 pair 4 logit 도달 vs DRAIN 길이

pair 4 의 s_last = 1 at cycle T+719. last_pipe[7]=1 at cycle T+727. acc_en@T+727 = comp_pipe[7]@T+727 = comp_v@T+719 = 1. edge T+727→T+728: logit0(pair4) latch + logit_valid=1.

DRAIN state 진입 cycle = T+720. drain_cnt:
- cycle T+720: drain_cnt=0
- cycle T+721: drain_cnt=1
- ...
- cycle T+727: drain_cnt=7 (=DRAIN_MAX − 1)
- edge T+727→T+728: state ← DONE, drain_cnt reset

→ pair 4 logit_valid pulse (cycle T+728) 와 state == DONE (cycle T+728) 가 **동일 cycle**. 외부에서 `class_valid` 와 함께 `class_idx` 를 sample 하는 데 문제 없으나, DRAIN 길이가 8 cycle 로 딱 맞는 (margin 0) 상태.

### 3.3 DRAIN_MAX 적정성

마지막 valid PE input cycle = T+719 (s_cnt=143). 끝단 acc latch cycle = T+727 → T+728 edge. → DRAIN 8 cycle 이 logit 확정과 정확히 일치. argmax 의 추가 1 cycle latency (combinational best_idx → registered class_idx) 는 DONE 이후에도 동작.

argmax: `in_valid = all_ready`. `all_ready <= logit_valid && (acc_pair_latch == 4)`. → cycle T+729 에 all_ready=1, edge T+729→T+730 에 class_idx + class_valid 확정.

→ class_valid pulse 는 DONE state 이후 1 cycle 후. 외부 PS 가 `class_valid` 를 polling 한다면 무해.

---

## 4. Handshake — Conv2 패턴 정합성

### 4.1 prior_diff counter (입력 측)

```verilog
case ({rdone, prior_wdone})
    2'b10:   prior_diff <= prior_diff + 1;   // 내가 처리 끝남
    2'b01:   prior_diff <= prior_diff - 1;   // 상대가 보내옴
    default: prior_diff <= prior_diff;
endcase
```

conv2 와 동일 패턴. `prior_wdone` (maxpool wdone in 으로 가정) 가 미리 와도 prior_diff 가 −1, −2, ... 로 누적 → IDLE 에서 자동 dequeue.

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
| LOAD_WEIGHTS state | ✓ (loader_done 대기) | ✗ (PS 직접 write) | ⚠ FC weight 는 PS 가 csr 통해 직접 write 가정. weight loader 모듈 없음. |
| FSM busy 출력 | ✗ | ✓ (미사용) | ⚠ 외부 결선 없음. 제거 가능. |
| DRAIN 진입 조건 | output_pixel_cnt == 575 | s_cnt == 143 && pair_cnt == 4 | ✓ |

---

## 5. 발견된 timing 의심점

### 5.1 pe_en / adder_en / acc_en 1-cycle late

**증상**: 각 pair 의 spatial 0 contribution 이 logit 누락.

**원인** (§1 기반):
- pe_en = `comp_pipe[1] | comp_pipe[2]` → cycle T+2, T+3 active
- 의도: pe_en active @ cycle T+1, T+2 (= `comp_pipe[0] | comp_pipe[1]`)

**왜 mask 되었나**: `maxpool_output.hex` 의 sp0 = 전체 0 → sp0 누락이 logit 에 0 영향. TB 데이터 의존.

**수정안 (BRAM L=1 가정 유지 시)**:
```verilog
localparam CTRL_DELAY = 6;   // 7 → 6

wire pe_en    = comp_pipe[0] | comp_pipe[1];
wire adder_en = comp_pipe[2] | comp_pipe[3] | comp_pipe[4] | comp_pipe[5];

wire       acc_en    = comp_pipe[CTRL_DELAY];  // = comp_pipe[6]
wire       acc_clear = first_pipe[CTRL_DELAY];
wire       acc_last  = last_pipe[CTRL_DELAY];
wire [2:0] acc_pair  = pair_pipe[CTRL_DELAY];
```

**대안 (BRAM L=2 였다면)**: 현재 코드 그대로. 단 `fc_engine.v` line 19-21 주석 ("BRAM read latency: 1 cycle") 과 `tb_fc_engine.v` 의 L=1 BRAM 모델을 L=2 로 수정.

**우선 확정 필요**: `bram_pool_to_fc` / `fc_weight_bram` 실제 Vivado BMG IP spec (`docs/ip_spec/block_memory_generator.md` line 19-20 TBD).

### 5.2 검증 방법

1. spatial 0 이 non-zero 인 합성 입력 (`maxpool_output_nonzero_sp0.hex`) 으로 TB 재실행
2. 기대 logit 값 재계산 (Python reference) → mismatch 확인
3. §5.1 수정안 적용 후 동일 입력으로 PASS 확인

---

## 6. Verification anchors 요약

| # | Cycle | 검증 항목 | 현재 코드 동작 | 의도된 동작 |
|---|---|---|---|---|
| A1 | T+1 | sp0 PE stage1 latch | latch 안 함 (pe_en=0) | latch (pe_en=1) |
| A2 | T+8 | acc first sample | sum0 = sp1(p0) (sp0 누락) | sum0 = sp0(p0) |
| A3 | T+151 | pair 0 last sample (logit0 latch 전 edge) | acc0_old = Σsp1..sp143 | acc0_old = Σsp0..sp143 |
| A4 | T+152 | pair 0 logit_valid pulse | logit0 = Σsp1..sp143 (deficient) | logit0 = Σsp0..sp143 |
| A5 | T+720 | DRAIN 진입 | state=DRAIN, rdone=1 pulse | (정상) |
| A6 | T+728 | DONE 진입 + pair 4 logit_valid | 동시 fire | (정상) |
| A7 | T+730 | argmax class_valid | class_idx + class_valid pulse | (정상) |

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
