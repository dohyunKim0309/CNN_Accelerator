# Conv1 2× DSP (single-round) — RTL 설계서 + 타이밍 표

**목적**: conv2 Winograd 후 새 bottleneck 이 되는 conv1(1634 cyc)을, **DSP 2배(18→36)** 로 2-round→**1-round** 화해 ~837 cyc 로 절반. → conv2-Winograd(~1324)가 bottleneck 이 되어 전체 효과 발휘.
**원칙**: `RTL/conv1` 원본 무변경. 본 엔진은 `RTL/conv1_2x/` 신규, drop-in(동일 c1c2 write·handshake). golden conv1 = bit-exact gate.

---

## 1. 현재 2-round 구조 (왜 2-round 였나)

conv1 = 1 IC → **8 OC**, 3×3, 28×28 → 26×26. PE = DSP48E1 **SIMD INT8×2**(1 PE → `mul0=W0·X`, `mul1=W1·X` = **2 OC**).

```
2 group × 9 PE(3×3) × SIMD(2 OC) = 4 OC / cycle
sel(DEPTH=2) 로 round 전환:  RUN1 sel=0 → OC0~3,  RUN2 sel=1 → OC4~7
→ 8 OC 를 2 round 로 (DSP 18개 재사용)
```

부수물(2-round 때문에 생긴 것):
- `sel` (pe_cell DEPTH=2 round mux)
- `ch_final` 1-cycle latch — **round0/round1 의 1-cycle data shift 차이 보정** (timing_table §2.1/§7)
- `LBRST` state — RUN2 진입 전 line_buffer 클리어(round1 stale 제거)
- FLUSH1/FLUSH2 두 번, c1c2 round 별 부분 write

---

## 2. 1-round 변경 (DSP 2배 = 4 group)

```
4 group × 9 PE(3×3) × SIMD(2 OC) = 8 OC / cycle   ← DEPTH=1 (round 없음)
단일 RUN 으로 8 OC 동시 → RUN2 / FLUSH2 / LBRST 전부 제거
```

| 항목 | 2-round (현재) | 1-round (conv1_2x) |
|---|---|---|
| PE (DSP) | 2 group × 9 = **18** | 4 group × 9 = **36** (정확히 2×) |
| pe_cell DEPTH | 2 (sel round mux) | **1** (sel 제거) |
| OC/cycle | 4 (2 round) | **8** (1 pass) |
| adder_tree | 2개 → 4 ch | **4개 → 8 ch** |
| truncate_relu | N=4 | **N=8** |
| `ch_final` 1-cyc latch | 있음(round 보정) | **제거** (round 없음 → 전 채널 동일 timing) |
| c1c2 write | round 별 4 OC(byte-write) | **8 OC 64b 한 번에** |
| FSM states | 8 (RUN1/2, FLUSH1/2, LBRST) | **5** (단일 RUN/FLUSH) |
| weight load | 36 word(18 PE × depth2, 1회) | 36 word(36 PE × depth1) — **개수 동일** |

★ data-path 깊이(BRAM→PE→adder→trunc)는 **불변** — 채널 수만 2배. 따라서 `PIPE_DELAY`/`FLUSH_LEN` 동일.

---

## 3. 새 FSM (★ 상태머신 먼저)

```
IDLE ──start──▶ LOAD ──loader_done──▶ RUN ──scan_done──▶ FLUSH ──flush_cnt==FLUSH_LEN-1──▶ DONE ──▶ IDLE
```

| state | 의미 | pipe_en | 전이 | 길이 |
|---|---|---|---|---|
| **IDLE** | start 대기, 카운터 0 | 0 | start → LOAD | — |
| **LOAD** | 36 weight 적재 (loader_start→loader_done) | 0 | loader_done → RUN | ~40 |
| **RUN** | 28×28 raster scan. `pixel_valid = row≥2 && col≥2` → 26×26 유효. 8 OC 동시 계산·write | 1 | (row,col)==(27,27) → FLUSH (NBA: rdone←1) | 784 |
| **FLUSH** | pipeline drain. `flush_cnt` 0→FLUSH_LEN-1 | 1 | flush_cnt==FLUSH_LEN-1 → DONE | 12 |
| **DONE** | rdone/wdone pulse, 카운터 reset | 0 | → IDLE | 1 |

**제거된 state**: `RUN2`, `FLUSH2`, `LBRST` (2-round 전용). `sel` 신호도 제거.
**유지**: bank-race fix(`bank_sel_pipe` 3-stage shift, addr_pipe 정렬) — single write 라도 multi-image bank toggle 정합 위해 유지.

### 3.1 파이프라인 깊이 (data path 불변)

| 구간 | stage | 비고 |
|---|---|---|
| bram_input read (L=2) | 2 | Primitives Output Register |
| pe_cell (DSP 3 + out 1) | 4 | SIMD INT8×2 |
| conv1_adder_tree (4-stage) | 4 | 200MHz refactor |
| truncate_relu | 1 | shift>>? + ReLU |
| **valid_sr / OUT_DELAY = PIPE_DELAY** | **10** | = L(2)+adder(4)+4 |
| **FLUSH_LEN** | **12** | = PIPE_DELAY+2 (마지막 픽셀 완전 drain) |
| we_pipe / addr_pipe / bank_sel_pipe | **2** | `ch_final` 제거로 3→2 (확정 §5). 10+2 = D_hw 12 |

---

## 4. 타이밍 표 — cycle budget (per image)

| phase | 2-round (현재) | 1-round (conv1_2x) | Δ |
|---|---|---|---|
| LOAD (weight) | 40 | 40 | 0 |
| RUN1 (scan, OC0~3) | 784 | — | |
| FLUSH1 | 12 | — | |
| LBRST | 1 | — | |
| **RUN (scan, OC0~7)** | — | **784** | |
| **FLUSH** | — | **12** | |
| RUN2 (scan, OC4~7) | 784 | — | |
| FLUSH2 | 12 | — | |
| DONE | 1 | 1 | 0 |
| **합계** | **1634** | **837** | **−797 (1.95×)** |

> 절감분 = RUN2(784) + FLUSH2(12) + LBRST(1) = 797. data-path 가 동일해 RUN/FLUSH/LOAD 단가는 그대로, **scan 을 한 번만** 하는 것이 핵심.

### 4.1 전체 latency 영향 (10000장, @200MHz compute floor)

| 구성 | conv1 | conv2 | bottleneck | floor |
|---|---|---|---|---|
| 현재 (conv2 SIMD) | 1634 | 1798 | conv2 1798 | ~90ms (측정 98ms) |
| conv2-wino 만 | 1634 | ~1324 | **conv1 1634** | ~82ms |
| + **conv1_2x** | **~837** | ~1324 | **conv2-wino 1324** | **~66ms** |

conv1_2x 단독(conv2 그대로)으론 conv2(1798)가 여전히 bottleneck → latency 영향 0. **conv2-Winograd 와 한 세트** 일 때만 의미 (README).

---

## 5. 엔진 변경 목록 (`RTL/conv1_2x/`)

| 파일 | 변경 |
|---|---|
| `conv1_2x_fsm.v` | §3 FSM (5-state, sel 제거, RUN2/FLUSH2/LBRST 삭제). PIPE_DELAY/FLUSH_LEN 동일 |
| `conv1_2x_engine.v` | 2 group→**4 group(36 PE, DEPTH=1)**, adder_tree 2→4, truncate_relu N=8, `ch_final` 제거, c1c2_din 8 OC 64b 단일 write, `sel` 배선 제거 |
| `conv1_adder_tree.v` | **재사용**(9:2 토폴로지 동일, group 마다 인스턴스) |
| `conv1_2x_weight_loader.v` | 36 PE 에 36 word 1회 load (DEPTH index 불필요). weight 헤더(`conv1_weights_simd[36]`) **포맷 동일**, 매핑만 18→36 PE |

### ★ 확정 완료 (실제 conv1 RTL 대조 — 2026-06-04)

**1. LOAD cycle = 40 (불변).**
`conv1_weight_loader` 는 36 word 를 **self-timed handshake**(`load_start`→`load_done`)로 적재 — 고정 카운트가 아니라 FSM 이 `load_done` 을 기다림. 내부 구조: BRAM L=2 + `latch_valid`→`_d`→`_dd` 2-cycle shift + `latch_cnt` 0..35 → 헤더 기준 `load_done` ≈ T+39(≈40 cyc). `conv1_2x_weight_loader` 는 **동일 타이밍 구조**(36 word, 동일 L=2, 동일 shift) 유지하고 **목적지 PE 매핑만** 18 PE×depth2 → 36 PE×depth1 로 바꿈. FSM 이 `load_done` 으로 동기하므로 LOAD 길이 = conv1 과 **완전 동일**. (§4 LOAD=40 유효.)

**2. we_pipe = 2 (현재 conv1 은 3). `ch_final` 제거 → control pipe −1.**
- data-path latency `D_hw`(in_addr 제시 → tr_out 유효) = BRAM L(2) + window_register(1) + pe_cell(4) + conv1_adder_tree(4) + truncate_relu(1) = **12 cyc**.
- FSM `PIPE_DELAY=10` = pixel_valid → out_valid 지연. **단일 RUN 에선 FSM row/col 카운터 == engine in_addr** (둘 다 pipe_en 으로 0 부터 증가, RUN1 식 정합) → pixel_valid 가 in_addr 제시와 같은 cycle.
- write 는 tr_out 이 결과를 들고 있는 cycle 에 발사해야 함: pixel_valid→write 총 지연 = `D_hw` = 12 → **we_pipe = D_hw − PIPE_DELAY = 12 − 10 = 2**.
- 현재 2-round 가 we_pipe=3 + `ch_final`(1-cyc data 지연) 을 쓴 **이유는 오직 RUN1/RUN2 skew**: LBRST 가 pipe_en 을 1-cycle 더 0 으로 잡는 동안 FSM 카운터는 계속 증가 → RUN2 의 in_addr 이 FSM 카운터보다 **1 behind** → RUN2 데이터가 1 cycle 늦음. 그래서 write@out_valid+3 에서 RUN2 는 tr_out 직접(+13 정합), RUN1 은 `ch_final`(tr_out 1지연, +13 정합) → 두 round 가 같은 cycle/addr 에 byte-merge.
- **conv1_2x 는 RUN2/LBRST 없음 → in_addr skew 없음 → ch_final 불필요, we_pipe=2, tr_out 직접.** (clean: 2-round 잔재가 사라짐.)
- **FLUSH_LEN = 12 불변**: 마지막 valid pixel(scan_done S) 의 input read 가 S 에 일어남(aligned), tr_out@S+12, write(we_pipe[1])@S+12. FLUSH 가 pipe_en=1 을 S+12 까지 유지(flush_cnt 0..11) → 정확히 충분.
- **bank_sel_pipe = 2** (addr_pipe 와 동일 단수). bank-race 안전: 마지막 write@S+12, wdone-driven bank flip @≈S+15 → **3-cycle margin** (현재 conv1 의 "1-cycle 전 flip" race 보다 안전. timing_table §3 참조).
- ⚠️ `conv1_timing_table.md §2.1` 의 "9 = valid_sr(6)+we_pipe(3)" 은 **stale**(구 adder 1-stage + L=1 기준). 현재 conv1 = PIPE_DELAY(10)+we_pipe(3)+ch_final(1); conv1_2x = PIPE_DELAY(10)+we_pipe(2)+ch_final(0).

**3. c1c2 = 8 OC 64b 단일 write (wea=8'hFF).**
현재는 같은 c1c2 word 에 2회 write(RUN1 wea=`0x0F` byte0-3=OC0-3 ← ch_final, RUN2 wea=`0xF0` byte4-7=OC4-7 ← tr_out) → BMG byte-write 가 merge. conv1_2x 는 4 group 으로 **8 OC 를 한 pass 에** 산출: `ch_i = OC_i`(i=0..7). `truncate_relu N=8` 의 `out_flat[8i+:8] = OC_i` 가 c1c2 byte layout 과 정확히 일치 → **`c1c2_din = tr_out_flat`(64b), `c1c2_wea = 8'hFF`, 단일 write**. weight BRAM 내용은 **byte-identical**(word k 가 같은 OC pair 를 pack) — loader 목적지만 word0-8→g1, 9-17→g2, 18-26→g3, 27-35→g4 (= PE k 직결).

---

## 6. 검증 (golden = bit-exact gate)

1. **golden**: `reference_core.Conv2D_Spec(w1)` (conv1) 출력 = RTL c1c2. iverilog 로 단일/멀티 이미지 bit-exact.
2. gate: 기존 `tb_cnn_accelerator_multi`(conv1 자리 conv1_2x) → 40/40 logit bit-exact 유지가 PASS 기준.
3. **bank-race 회귀 주의**(timing_table): single write 라도 multi-image bank toggle 시 마지막 write vs bank flip 정합 — `bank_sel_pipe` 정렬 유지, multi-image TB 로 img1+ 확인.
4. DSP 36 배치/200MHz: conv2 overclock 교훈(max_fanout 복제) 선제 적용.

---

## 7. 빌드 순서
① FSM(`conv1_2x_fsm.v`) — 5-state, cycle budget 표(§4) 기준 → ② engine(4 group/N=8/ch_final 제거) → ③ weight_loader(36 PE) → ④ iverilog golden bit-exact(단일→멀티, bank-race) → ⑤ `cnn_accelerator.v` drop-in → ⑥ 200MHz fanout 리팩토링(§8) → Vivado(DSP +18, 200MHz).

**구현 상태 (2026-06-04, ✅ 완료)**: ①~⑥ 전부 완료. `tb_cnn_accelerator_multi` (conv1_2x_engine swap) **40/40 logit bit-exact + 40/40 bram_output readback**(img1+ 포함 → bank-race 없음). 원본 conv1_engine 베이스라인 대비 img0 6730→5933 = **−797 cyc 정확 일치**(conv1 1634→837). PE_BC_DELAY=0/1/2 모두 bit-exact. Vivado PENDING.

---

## 8. 200MHz fanout 리팩토링 (conv2 overclock 선례 적용)

DSP 18→36 으로 broadcast net 의 fanout·route span 이 커짐 → intra-clock 병목 우려. conv2(`RTL/conv2/conv2_engine.v` §5.5/§7.5)와 **동일 2단계** register-staging + max_fanout 복제를 `conv1_2x_engine.v` 에 선제 적용. **FSM·weight_loader 무변경**(engine 만).

### 8.1 Step1b — 가중치 로드 broadcast +1 register
- `pe_packed_w`(25b)·`pe_load_idx`(1b) 가 36 PE(die 전역 DSP 컬럼)로 fanout → `*_r` 1-register 복제(`(* max_fanout=16 *)`). `pe_load_en` 은 PE 별 fo=1 (복제 불필요, 정렬 위해 동일 +1).
- weight-load 는 image 당 1회, 첫 valid compute(RUN+58cyc)보다 수십 cycle 앞서 끝남 → **+1 cycle 무해**(첫 valid 픽셀 전에 36 PE 전부 latch 완료).

### 8.2 Step2 — 연산 broadcast pipeline (depth = `PE_BC_DELAY`, 기본 1)
- `pipe_en`·activation(`kx` 9×8b) 을 36 PE 입력 직전에 N register 복제(`pe_en_bc` `(* max_fanout=16 *)`, `kx` slice 는 fo=4 라 미복제). line_buffer/window/카운터/BRAM read 는 원래 timeline 유지(kx 출력만 지연).
- **★정렬 불변식**: `en`·`x` 를 *동일* N 지연 → PE 가 보는 {weight, x} tuple = N cycle 전과 동일 → 곱셈 시퀀스 **bit-exact**(latency 만 +N). adder/trunc `en` 도 `pe_en_bc` 사용 → downstream 전체 +N 균일 시프트.

### 8.3 정렬·드레인 (왜 FSM 무변경인가)
- **write pipe = `WR_PIPE = 2 + PE_BC_DELAY`**: PE 출력이 +N 늦으므로 `we_pipe`/`addr_pipe`/`bank_sel_pipe` 를 (2+N) stage 로. `out_valid`@S+10 → write@S+10+(2+N) = S+12+N = `tr_out`(=S+12+N) 정합.
- **drain 자동 +N**: `pe_en_bc` = `pipe_en` 지연 N → 마지막 픽셀 `tr_out`@S+12+N 까지 `pe_en_bc`=1 보장(pipe_en=1@S+12 → pe_en_bc=1@S+12+N). **FLUSH_LEN=12 불변**.
- **write 주소가 engine addr_pipe 로 전달**(conv2 처럼 FSM 카운터 reset 에 안 걸림) → DRAIN 연장 불필요(conv2 는 FSM DRAIN +N 필요했음 — c2pool write_addr 가 FSM-counter 였기 때문).
- **bank-race 안전**: `bank_sel_pipe` 가 addr_pipe 와 동일 (2+N) 지연 → 마지막 write 의 {bank,addr} coherent. wdone-driven bank flip 은 FSM-timed(S+15 근처)라 N 무관.
- **★net latency 0**: `wdone`(=conv2 trigger)는 FSM-timed(S+13)이라 N 무관 → conv2 시작 시점 불변. 마지막 c1c2 write(high addr)는 conv2 가 그 addr 를 raster 끝에서 읽기 한참 전에 완료 → 시스템 latency 영향 0 (iverilog img0 @5933, N=0/1/2 동일).

### 8.4 검증
iverilog `tb_cnn_accelerator_multi`: **PE_BC_DELAY=0/1/2 모두 40/40 logit + 40/40 readback bit-exact**. N=0 = 리팩토링 전과 동일(passthrough 회귀). 기본값 1 채택. Vivado 에서 200MHz route-bound 지속 시 PE_BC_DELAY 2~3 으로 상향(또는 max_fanout 값 하향) — 전부 bit-exact 보존.
