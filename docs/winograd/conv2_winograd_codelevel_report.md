# Conv2 Winograd F(4,3) — 코드 단위 동작 + 정밀 타이밍 레포트

> 작성 기준: **현행 RTL = baseline** (`conv2_winograd_engine.v` + leaf, carry-bisect revert 후 = journey **Iter 15**).
> 권위 수치: **m_valid = issue+11, tag 깊이 15, tile_out = issue+17, 1348 cyc/img @ 171.43 MHz**.
> ※ `conv2_winograd_timing.md` / `conv2_winograd_engine_arch.md` 본문은 한때 carry-bisect(+1) 값(issue+12 / tag16 / 1349)으로
> 적혔으나 두 문서 모두 머리에 "2026-06-19 정정 — 전부 −1" 헤더가 있다. 본 레포트는 **실제 코드 그대로의 baseline 값**으로 통일한다.
> 모든 latency 는 RTL register 를 한 단씩 직접 추적해 재확인했다(§3.1).

---

## 0. 한 줄 요약

`8 IC×26×26 INT8 → 16 OC×24×24 INT8` 직접 conv2 를, **6×6 tile (stride 4) 36개**로 쪼개
복소수 Winograd F(4,3) 로 계산한다. 각 tile 은
`V = Bᵀ·d·B`(입력변환, 곱셈기 0) → `M = Σ_IC U⊙V`(184 DSP) → `Y16 = Aᵀ·M·A`(출력변환, 곱셈기 0)
→ `sat(Y16≫14)+ReLU` → c2pool 으로 흐른다. 곱셈수 144→46(3.13×), DSP 192→184, latency
1798→**1348 cyc/img**(direct conv2 대비 1.33×). 곱셈은 오직 mul array 184 DSP 뿐이고, 입·출력 변환은
전부 add/shift/negate/i-swap 다.

핵심 설계 결정 두 가지:

1. **분산 제어 (handshake)** — conv1·maxpool 과는 데이터 경로 위에 중앙 컨트롤러 없이, 각 엔진이 자체
   FSM + bank-toggle FF 로 `rdone`/`wdone` counter 핸드셰이크만 주고받는다 (§9).
2. **레이어 내부는 핸드셰이크 없이 카운터-구동 FSM** — conv2 winograd 엔진 *내부*에서는 producer ∥ consumer ∥
   writer 세 프로세스가 서로 `done` 신호를 주고받지 않는다. 대신 **타이밍 표로 정확한 사이클을 미리 계산**해
   각 단을 고정 latency 파이프로 만들고, FSM 전이는 전부 **내부 카운터 비교**(`compute_cnt`/`tile_cnt`/
   `trow_cnt`/`pld_*`/`pdrain_cnt`/`mdrain_cnt`)로 유도한다. 높은 클럭에서 핸드셰이크 net 의 route delay 없이
   안전하게 닫기 위함이다. **이 레포트의 핵심이 바로 이 "왜 카운터로 충분하고, 정확히 몇 사이클인가" 이다.**

---

## 1. 모듈 맵 (`RTL/conv2_winograd/`)

| 파일 | 역할 | clk 파이프 깊이 |
|---|---|---|
| `conv2_winograd_engine.v` | top: main FSM + producer FSM + 3 프로세스 결선 | — |
| `wino_row_buffers.v` | 2-set × 6 row × 26 col × 64b line buffer (분산 LUTRAM) | write +1, read comb |
| `wino_input_transform.v` | `V = Bᵀ·d·B` (per IC, 곱셈기 0) | **3-stage** (d→a_flat = +2) |
| `wino_mul_array.v` (×4 lane) | a_q + per-PE weight RAM + 46 DSP + lane_reduce + pre_q | a_q +1, DSP +3, pre_q +1 |
| `wino_dsp_mul.v` | DSP48E1 단일 곱셈기 (SIMD 없음) | **3-stage** (AREG/BREG→MREG→PREG) |
| `wino_lane_reduce.v` | 46 product → 26 position partial (Gauss) | comb |
| `wino_m_assemble.v` | 26 계산값 → 36 M (켤레 확장, 곱셈기 0) | comb |
| `wino_output_transform.v` | `Y16 = Aᵀ·M·A` | **4-stage** (m_valid→out_valid = +4) |
| `wino_truncate.v` | `sat(Y16≫14)+ReLU` → INT8 | 1 |
| `wino_weight_loader.v` | 시작 1회 narrow BMG → wide per-PE wmem 조립 | — |

비트폭 (relu-range 재사이징, `localparam` in engine):
`VW=14`(activation/V) · `UW=12`(weight/U) · `PW=24`(DSP product) · `MW=25`(lane partial/M) · `YW=28`(Y16).

---

## 2. 데이터플로우 (한 tile 의 일생)

```
c1c2 BMG (Port B, 64b = 8 IC, L=2)
   │ producer: raster read rows[4ty..4ty+5] × cols[0..25]
[wino_row_buffers]  2-set × 6row × 26col × 64b, tile-row 단위 ping-pong
   │ consumer: set_active 에서 tile(ty,tx) 6×6×8IC 를 comb 추출 (tile6)
[tile6_q]  rb 읽기 register (+1)
   │ grp_q 로 8 IC → 4 IT time-share (d-mux)
[wino_input_transform ×4, 3-stage]  V=Bᵀ·d·B  → a_flat (46 operand × 4 lane)
   │
[wino_mul_array ×4 lane]  a_q → 46 DSP(×4=184) → lane_reduce → pre_q
   │ engine: gather 2+2 (gpab/gpcd) → gpre_q → grp0 acc load / grp1 acc+gp
[wino_m_assemble]  26 계산값 → 36 M (켤레), grp1 cycle 에 m_*_flat latch + m_valid
   │
[wino_output_transform 4-stage]  M(6×6 complex) → Y16(4×4 real)
   │
[wino_truncate N=16]  sat(Y16≫14)+ReLU → 16 INT8 (1 OC 의 16 pixel)
   │ collector: tile_out[bank=tcol[0]][pixel][oc]
[writer]  tile_out → c2pool (pixel 당 1 write, 16 write/tile)
```

producer(row load) ∥ consumer(tile compute) ∥ writer(c2pool write) 가 **동시에** 돈다. tile-row 경계에서
row-buffer set 을 ping-pong 으로 swap 한다.

---

## 3. ★ 정밀 타이밍 — issue 에서 출력까지 (cycle-by-cycle)

이 절이 레포트의 심장이다. mul array 의 **issue cycle** 을 기준점 T 로 잡고, 각 datum 이 register 를 몇 단
지나는지 RTL 그대로 센다.

### 3.0 issue 시퀀스

`compute_cnt` 가 0..31 로 매 cycle 1씩 증가한다. 한 tile = 32 cycle.

```
oc   = compute_cnt[4:1]   (0..15)
grp  = compute_cnt[0]     (0=IC0-3 group, 1=IC4-7 group)
sel  = compute_cnt        (per-PE weight RAM read addr, =oc*2+grp)
```

즉 issue cycle `c` 에서 `(oc, grp) = (c≫1, c&1)`. 한 OC 의 M 은 **grp0(IC0-3) → grp1(IC4-7) 2 cycle 누적**으로
완성되며, grp1(oc) 은 `c = 2oc+1` 에서 issue 된다.

### 3.1 issue → m_valid = **+11** (register 단위 검증)

아래는 grp1 datum 이 issue 된 cycle 부터 `m_*_flat` latch + `m_valid` 까지 RTL register 를 한 단씩 센 것이다.

| 누적 | 단계 | RTL 근거 |
|---|---|---|
| +1 | `tile6_q` (rb read register) | engine: `tile6_q <= tile6` |
| +1 | input_transform **stage1** `t = Bᵀ·d` reg | `wino_input_transform`: `tre/tim <= tre_c/tim_c` |
| +1 | input_transform **stage2a→2b** 부분합 reg | `vre_*_q <= vre_*` (stage2b 는 comb → a_flat) |
| +1 | `a_q` (★2a activation register) | `wino_mul_array`: `a_q <= a_flat` |
| +1 | DSP **AREG/BREG** | `wino_dsp_mul` DSP48E1, AREG=BREG=1 |
| +1 | DSP **MREG** | MREG=1 |
| +1 | DSP **PREG** | PREG=1 (P=M) |
| +1 | `pre_q` (★G-1 lane-local reg) | `wino_mul_array`: `pre_q <= lpre` |
| +1 | `gpab/gpcd` (gather 2+2 reg) | engine: `gpab_re[xk] <= lpre_q[0]+lpre_q[1]` 등 |
| +1 | `gpre_q` (★C-1 cross-lane reg) | engine: `gpre_q[kk] <= gpre[kk]` |
| +1 | `m_*_flat` latch (grp1) | engine: grp1 cycle 에 `m_re_flat <= asm_re_flat; m_valid<=1` |
| **=11** | **issue(grp1) → m_valid** | |

- input_transform 이 "3-stage" 인데 위에서 **+2** 만 차지하는 이유: stage1 reg(+1), stage2a→2b reg(+1),
  그리고 stage2b 는 **comb** 라서 `a_flat` 까지가 d 기준 +2 다. 모듈 헤더 주석 "a_flat = d_flat + 2" 와 일치.
- DSP 의 P=M (OPMODE `7'b0000101`, Z=0) 이므로 곱 a*b 가 그대로 P 로 나온다 — 3단 곱셈기.

**절대 cycle(tile 내):** grp1(oc) 은 `c = 2oc+1` 에 issue 되므로 M(oc) 는 compute-cyc `(2oc+1)+11 = 2oc+12`
에서 유효하다.

```
oc= 0 : grp1 @c= 1 → m_valid @c=12
oc=15 : grp1 @c=31 → m_valid @c=42   (마지막 issue c=31 → 마지막 M @42)
```

### 3.2 m_valid → tile_out = **+6** (총 issue → tile_out = **+17**)

| 누적 | 단계 | RTL 근거 |
|---|---|---|
| +4 | output_transform 4-stage → `ot_valid` | `wino_output_transform`: in_valid→out_valid = +4 |
| +1 | `wino_truncate` (en = ot_valid) → `trunc_out` | 1-cycle |
| +1 | collector: `tile_out[bank][pix][oc]` 기록 | engine: `cwe<=ot_valid`, `if(cwe) tile_out<=trunc_out` |
| **=6** | m_valid → tile_out | |

output_transform 4-stage 내부:
- stage1a→1b reg: `y = Aᵀ·M` 의 2-term 부분합 reg(`yre_*_p*_q`, v1) → `y` 합 reg(`yre[i][l]`, v2).
- stage2a→2b reg: `Y16 = y·A` 의 부분합 reg(`y16_*_q`, v3) → `Y16` 합 reg(`y16_flat`, out_valid).
- 각 stage 가 add ≤ 2단 (200MHz 목표로 잘게 쪼갬).

따라서:
```
oc=15 : m_valid @c=42 → tile_out @c=48   ⇒ tile 완성 (oc15 기록 = tile_done 트리거)
issue → tile_out = 11 + 6 = 17
```

### 3.3 tag 파이프라인 (좌표 추적) — 깊이 **15**

M 의 oc/tile 좌표는 issue 시점에서 흘러간 만큼 지연돼야 collector 가 올바른 `tile_out[*][*][oc]` 에 쓴다.
engine 의 `tg_oc/tg_trow/tg_tcol` 는 `[1:15]` shift register 다.

```
tg_oc[1] <= issue_oc(=compute_cnt[4:1]); ... tg_oc[15] <= tg_oc[14];
collector: coc <= tg_oc[15]   (cwe 와 같은 cycle 에 정렬)
```

깊이 15 의 근거: cwe(=tile_out write) 가 일어나는 cycle 에서 본 issue context. issue→m_valid=11, m_valid→ot_valid=4
이므로 ot_valid 는 issue+15. collector 는 `cwe<=ot_valid` 로 한 cycle 더 늦게 쓰지만, 그 cycle 에 쓰는 좌표는
**바로 직전 등록된** `tg_*[15]`(=issue+15 context)이다. ⚠️ 이 때문에 **M 경로 latency 를 ±1 바꾸면 tag 깊이도
±1, collector 인덱스 `tg_*[15]` 도 ±1** 을 동시에 고쳐야 한다 (carry-bisect 가 +12/tag16 으로 갔다가 revert 된 게
바로 이 정렬 묶음이다).

### 3.4 한 tile 의 타이밍 표 (정리)

| 사건 | compute-cyc | 식 |
|---|---|---|
| issue (oc,grp) | c = 0..31 | grp1(oc) @ c = 2oc+1 |
| `m_valid(oc)` + M latch | 2oc+12 | grp1 issue + 11 |
| `ot_valid(oc)` (Y16 유효) | 2oc+16 | + OT 4-stage |
| `trunc_out(oc)` | 2oc+17 | + truncate 1 |
| `tile_out[*][*][oc]` 기록 | 2oc+18 | + collector 1 |

- oc0: m_valid@12 → tile_out@18.  oc15: m_valid@42 → **tile_out@48 = tile 완성**.
- 다음 tile 의 issue 는 cyc 32 부터 **연속**(파이프 안 비움) → tile 당 실효 **32 cycle**. 마지막 OC 의 M/output
  drain(@42/@48)과 §4 의 16 write 는 **다음 tile compute 의 그림자**에 겹친다.

---

## 4. consumer: 한 tile 처리 (32-cyc 연속 issue + drain)

- `set_active`(= `trow_cnt[0]`)의 row buffer 에서 tile(ty,tx) 의 6×6×8IC 를 **comb 추출**(`tile6`). 별도 tile_buf
  레지스터가 없어도, 그 32 cycle 동안 `tile_cnt`/`trow_cnt` 가 고정이라 comb extract 가 안정적이다(producer 는
  다른 set 에 write 중). M·output·tile_out 은 파이프 지연 stream 으로 흘러나온다.
- **issue 가 멈추지 않는다**: 한 tile 의 마지막 issue(c=31) 직후, 다음 tile 의 issue(c=0)가 바로 이어진다.
  파이프를 비우지 않으므로 throughput = **32 cyc/tile** (latency 와 무관).

### 4.1 c2pool write (writer)

`tile_done`(oc15 tile_out 기록 = issue+17 of last OC) 이 뜨면 writer 가 16 pixel 을 1 cycle 당 1개 write 한다.

```
pixel p (0..15): i=p/4, j=p%4
c2pool_din  = {tile_out[bank][p][15], …, tile_out[bank][p][0]}  (16 OC packed 128b)
c2pool_addr = {output_bank_sel, (4ty+i)*24 + (4tx+j)}           (row*24+col raster)
```

- 16 write < 32 compute → 다음 tile compute 그림자에 완전히 겹친다.
- conv2(direct)는 raster 순차 `addr++` 였지만 winograd 는 tile 단위라 **addr 를 명시 계산**(`pix_addr = row*24+col`,
  `{1'b0,row,4'b0}+{2'b0,row,3'b0}+col` = row*16+row*8+col = row*24+col).
- **bank = tcol[0]** double-buffer: 인접 tile 이 bank 를 교대하므로 writer(이전 tile, 한 bank read)와
  collector(현 tile, 다른 bank write)가 충돌하지 않는다.

---

## 5. ★ 레이어 내부 FSM — 핸드셰이크 없이 카운터로만 (왜 안전한가)

엔진 내부에는 **두 개의 FSM 이 병행**한다: main FSM(consumer/compute) + producer FSM(row load). 둘은 서로
`done` 을 주고받지 않는다. 대신 **타이밍 표로 producer 가 항상 consumer 보다 앞선다는 것을 증명**한 뒤, FSM 전이를
전부 카운터 비교로 유도한다.

### 5.1 main FSM

```
IDLE         : start 대기. start → LOAD_WEIGHTS.
LOAD_WEIGHTS : 첫 start 1회. wino_weight_loader 가 narrow BMG → wide per-PE wmem 조립
               (~5888 + drain cyc). loader_done → WAIT_IMG. (image loop 에선 재진입 안 함.)
WAIT_IMG     : ready_to_compute (data_ready & output_avail, §9) 대기.
LOAD_INIT    : tile-row0(set0) row load 완료(set_ready[0]) 대기 — 이 구간만 consumer idle.
RUN          : tile-row 0..5 처리. consumer(compute) ∥ producer(다음 row load) 동시.
               compute_cnt/tile_cnt/trow_cnt 진행. last_issue → DRAIN.
DRAIN        : 마지막 tile 의 M drain(mul_en window 유지) → tile_done → 16 write → wdone → WAIT_IMG.
```

주요 카운터:

| 카운터 | 범위 | 의미 / 전이 |
|---|---|---|
| `compute_cnt` | 0..31 | tile 내 issue cycle. =weight sel, [0]=grp. wrap 시 tile_cnt++ |
| `tile_cnt` (tx) | 0..5 | tile-row 내 tile. wrap 시 trow_cnt++ |
| `trow_cnt` (ty) | 0..5 | tile-row. `set_active = trow_cnt[0]` |
| `pld_trow/pld_row/pld_col` | 0..6 / 0..5 / 0..25 | producer load 위치. `set_load = pld_trow[0]` |
| `pdrain_cnt` | 0..2 | L=2 read drain + rb write reg landing (3 cycle) |
| `mdrain_cnt` | 0..7 | DRAIN 중 mul array en 유지 window |
| `wr_pix` | 0..15 | writer pixel index |

`last_issue = compute_active && trow_cnt==5 && tile_cnt==5 && compute_cnt==31`. 즉 마지막 tile 의 마지막 issue
를 **순수 카운터 비교**로 검출해 DRAIN 으로 전이한다.

### 5.2 producer FSM (row load) + PDRAIN

```
PIDLE  : pld_can_start 대기.
PLOAD  : (pld_row,pld_col) raster 진행, c1c2_re=1, rb 에 write pipe(pw_v1→pw_v2) 로 적재.
PDRAIN : 마지막 read(row5,col25) 후 c1c2_re 를 3 cycle 더 유지(§7.3) → doutb→wr_data_q→rb landing 완료.
         pdrain_cnt==2 에서 set_ready[pld_trow[0]]=1, pld_trow++.
```

`pld_can_start` 가 producer-consumer 동기의 핵심인데, **핸드셰이크가 아니라 카운터 부등식**이다:

```verilog
pld_can_start = (pld_trow<=5) &&
   ( (pld_trow==0) ? (state==LOAD_INIT)
                   : (state==RUN && (trow_cnt+1 >= pld_trow)) );
```

즉 producer 는 consumer 의 `trow_cnt` 를 **읽기만** 하고, "내가 적재하려는 tile-row(pld_trow)가 consumer 가
지금 처리 중인 것(trow_cnt)보다 최대 1 앞이면 진행" 한다. consumer 가 producer 에게 보내는 신호도, 그 반대도 없다.

### 5.3 ★ 왜 핸드셰이크 없이 안전한가 — 타이밍 margin 증명

레이어 내부에서 핸드셰이크를 뺄 수 있는 **유일한 근거**는 다음 부등식이다:

```
consumer 가 한 tile-row 처리하는 시간 = 6 tile × 32 cyc = 192 cyc
producer 가 한 tile-row 적재하는 시간 = 6 row × 26 col = 156 read (+ L2 drain)
156 < 192  →  producer 가 항상 먼저 끝난다 → consumer 가 set swap 할 때 데이터는 이미 준비됨.
```

이 36 cyc margin(192−156) 덕분에 RUN 중 tile-row 경계에서 consumer 가 **producer 를 기다릴 필요가 없다**
(무조건 진행). `set_ready` gate 는 오직 **최초** LOAD_INIT→RUN 진입(첫 tile-row0 가 채워졌는지)에만 쓰인다.
이후 RUN 의 tile-row 경계엔 set_ready 를 보지 않는다 — 타이밍 표가 이미 producer 우위를 보장하기 때문이다.

> **이것이 "통신 대신 타이밍 표를 그려 정확한 사이클을 계산하고, 내부 카운터로 FSM 전이를 유도" 의 정체다.**
> 핸드셰이크 net 은 die 전역 control net 이라 높은 클럭에서 route delay 벽이 된다(direct conv2 overclock 교훈).
> 레이어 내부는 latency 가 결정적(data-independent)이므로, 미리 계산한 고정 사이클이 핸드셰이크보다 안전하고
> 빠르다. 핸드셰이크는 **레이어 간**(conv1↔conv2↔maxpool, 속도 가정 불가)에만 남긴다(§9).

```
tile-row: ty=0           ty=1           ty=2          ...  ty=5
consumer: [compute set0] [compute set1] [compute set0] ... [compute set1]
producer:[load set0]→[load set1]   →[load set0]   →...      (ty=5 후 load 없음)
           (초기 160)    (192 그림자) (192 그림자)
```

---

## 6. ★ cycle budget — 정확히 1348 cyc/img 가 어떻게 나오는가

steady-state period = `wdone ↔ wdone` 간격. 한 image 의 비용을 카운터 그대로 더한다.

| 항목 | cycle | 근거 |
|---|---|---|
| WAIT_IMG | 1 | ready_to_compute 판정 1 cycle |
| LOAD_INIT (tile-row0 row load) | 160 | 1 (PIDLE entry) + 156 (PLOAD = 6row×26col) + 3 (PDRAIN) + 0 (set_ready→RUN 동일 edge) |
| compute (36 tile × 32) | 1152 | RUN 본체 |
| 마지막 tile DRAIN tail | 35 | last-tile M drain → tile_done → 16 write → wdone (RUN 뒤 노출분) |
| **steady-state period** | **1348** | 1 + 160 + 1152 + 35 |

검증: `python` 으로 `1 + (1+156+3) + 36*32 + 35 = 1348` 확인. iverilog full-pipe 측정 avg cyc/img = **1348** 와 일치.

### 6.1 왜 tail 이 35 인가 (steady-state 와 last-tile 의 차이)

steady-state 의 tile-내 drain(M @2oc+12, tile_out @2oc+18, 16 write)은 **다음 tile 의 32-cyc compute 그림자에
완전히 숨는다** → period 에 double-count 되지 않는다. 오직 **마지막 tile**(다음 tile 이 없는)의 drain 만 RUN 끝에
노출된다. 그 노출분 = 마지막 issue(c=31) 이후 [m_valid +11 → OT/trunc/collector +6 → tile_done → writer 16] 의
꼬리 = 35 cycle.

> 참고: carry-bisect 판(revert 됨)에서는 M 경로가 +1 깊어 tail=36, period=1349 였다. **현행 baseline = tail 35,
> 1348.** 코드의 `tg_*[1:15]` 와 주석 "issue+11 / 1348" 이 baseline 임을 못박는다.

### 6.2 throughput 이 latency 와 무관한 이유

throughput 은 **issue rate(1 issue/cyc, FSM 고정)** 가 결정한다. 파이프 깊이를 늘려도(overclock 으로 IT 3-stage,
OT 4-stage, gather 분할 등 추가) cyc/img 는 거의 불변이고, 늘어난 latency 는 **마지막 tile tail** 에만 노출된다.
그래서 pre-overclock 1337 → 현행 1348 의 차이(+11)는 전부 tail 의 파이프 깊이 증가분이지 throughput 손실이 아니다.

---

## 7. 정확성을 지키는 세 가지 미세 타이밍 (버그-픽스 포인트)

### 7.1 grp0/grp1 2-cycle 누적과 vld_pipe stale 마스킹

```verilog
grp_pipe <= {grp_pipe[4:0], mul_grp_q4};   // grp 비트를 6단 따라 흘림
vld_pipe <= {vld_pipe[4:0], 1'b1};         // en burst 동안 valid 채움
if (vld_pipe[5]) begin
   if (grp_pipe[5]==0)  acc <= gpre_q/gpim_q;          // grp0: IC0-3 partial 적재
   else { m_*_flat <= asm_*; m_valid<=1; }             // grp1: 8-IC 완성 latch
end
```

image 경계(en=0)에 `grp_pipe/vld_pipe` 를 0 으로 clear → 다음 burst 가 stale 값으로 잘못 latch 하는 것을
`vld_pipe[5]` gate 가 막는다. en 이 0→1 로 refill 될 때 처음 5 cycle 은 vld_pipe[5]=0 이라 무시된다.

### 7.2 mul array drain window (DRAIN 의 mdrain_cnt)

마지막 issue(c=31) datum 의 M 이 latch 되려면 그 이후로도 array en 이 유지돼야 한다. issue→m latch 경로 중
DSP/accumulator 가 en(CE) gated 이므로, DRAIN 에서 `mul_en = (mdrain_cnt < 8)` 로 8 cycle 더 en 을 켜둔다
(마지막 datum 이 m latch 되는 데 필요한 깊이 + 마진). 순수 카운터 — 어떤 done 도 안 본다.

### 7.3 producer L=2 read drain (PDRAIN, 필수 버그픽스)

c1c2 BMG 는 **L=2 + enb-gated** (`if(enb){pre<=mem[addr]; doutb<=pre;}`). 마지막 addr(row5,col25)를 issue 한
직후 `c1c2_re`(=enb)를 내리면 그 read 가 doutb 까지 전파되지 못해 **마지막 cell(rb[5][25]) 이 stale** 가 된다.
이는 tile(ty, **tx=5**)의 d[5][5] → V[5][5] → M[5][5] → **Y16[3][3](pixel p15)만** 오류로 나타난다(Aᵀ 의 row/col 5
가 오직 Y16[3][3] 에만 기여). data-dependent 라 일부 image 의 1 pixel 만 틀린다.

**해결 = PDRAIN 3 cycle**: 마지막 read 후 `c1c2_re` 를 유지(addr 도 hold)해 doutb→`wr_data_q`→rb landing 까지
완료시킨 뒤 set_ready 를 올린다. (rb 의 write +1 register `wr_data_q` 때문에 L2 drain 2 + landing 1 = 3 cycle.)
이 3 cycle 이 위 LOAD_INIT 160 의 일부다.

---

## 8. weight 경로 — startup 1회 (image loop 와 분리)

- PS 가 pre-transformed `U = G·g·Gᵀ` 5888 word(= 32 entry × 184 operand, 1 op/word, UW=12)를
  `wino_weight_bram`(32b×8192 SDP) Port A 에 write.
- 첫 start → `LOAD_WEIGHTS` → `wino_weight_loader` 가 narrow BMG 를 순차 read(L=2, dvalid 3-cycle 정렬)해
  per-PE 분산 RAM(`wmem_op[0:31]` ×184)에 operand 1개씩 narrow write. ~5888 + drain cycle, **1회뿐**.
- compute read 는 `wmem_op[rd_sel]`(L=1) → `w_q_op→op2→op3→op4`(+4 정렬, a_q 와 동시 DSP capture).
- `wmem[sel] == 옛 baked ROM[sel]`(bit-identical) → mul array 값·타이밍 불변. weight 는 startup-only 라
  image latency(1348)에 안 들어간다.

---

## 9. 레이어 간 handshake (conv2_fsm 미러 — race-free)

레이어 *내부*는 카운터(§5)지만, **레이어 간**은 속도 가정을 할 수 없어 counter backpressure 핸드셰이크를 쓴다.

```verilog
prior_diff = (conv2w rdone count) − (conv1 wdone count); data_ready  = prior_diff_next < 0
after_diff = (conv2w wdone count) − (maxpool rdone count); output_avail= after_diff_next < 2
ready_to_compute = data_ready && output_avail   // combinational next-value (NBA race 회피)
input_bank_sel  toggle on rdone   // c1c2 read bank
output_bank_sel toggle on wdone   // c2pool write bank
```

- `rdone`(1-cyc pulse): image 의 **마지막 c1c2 read** 후 = PDRAIN 종료 & `pld_trow==5` 시점(RUN 중). conv1 이
  그 bank 를 refill 가능해진다.
- `wdone`(1-cyc pulse): image 의 **마지막 c2pool write**(tile-row5,tile5,pixel15) 후. maxpool 이 read 가능.
- `ready_to_compute` 를 **next-value(조합)** 로 본다 — counter 가 NBA 로 갱신되기 전 값을 보면 한 박자 늦는
  race 가 생기므로 `*_next` 로 평가한다.
- conv2 winograd 는 conv2(direct)와 **동일한 핸드셰이크 의미** → 주변 conv1/maxpool 무변경 (drop-in).

---

## 10. 검증 상태 (현행 기준)

1. **leaf 단위**: input/output transform, lane_reduce, m_assemble, dsp_mul, truncate 전부 hw_model 대비 iverilog bit-exact.
2. **engine e2e**: `TB/multi_img/tb_conv2_winograd_engine_multi.v` → c1c2 주입(all_c1c2.hex), c2pool ==
   `data/multi_img/all_c2pool.hex` (winograd==direct 라 기존 golden 재사용). **100/100 bit-exact**, 측정 1348 cyc/img.
3. **full pipeline**: `tb_cnn_accelerator_winograd_multi` (logit + bram_output readback) **100/100**.
4. **dual-clock CDC**: `tb_system_axi_winograd_multi_2clk` (CSR 100MHz + datapath 200MHz, 2:1) **10/10**.
5. **Vivado**: floorplan 압축 intrinsic 불가(gather dataflow + 76% LUT 밀도) + −1 칩 VCO 천장 1200 →
   **171.43 MHz(VCO=1200, baseline RTL) 확정** (journey Iter 15). carry-bisect 는 200 닫혀도 churn 으로 순손해 → revert.

---

## 부록 A. 알고리즘 측 핵심 (왜 곱셈이 46개인가)

- 6×6 tile, F(4,3) → 36 position 의 complex element-wise mult, 8 IC 누적.
- `G_IM` 이 i,−i 행에만 존재 → U 의 다수 position 이 **real-only**(im=0). 그래서 36 position 중:
  - real×real 16개 → 각 1 mul = 16.
  - complex 켤레쌍 10개 → Gauss 3-mul 씩 = 30. (켤레 position 은 conj 로 무료, 계산 안 함.)
  - 합 **46 real-mul / (IC,OC,tile)**.
- **Gauss trick** (복소수 1회 = 3 real-mul): `k1=a(c+d), k2=c(b−a), k3=d(a+b)` → `Re=k1−k3, Im=k1+k2`.
  - 그래서 input_transform 이 cmul position 마다 `(c+d)=vcd_*`, `c=vre_*`, `d=vim_*` 3개 operand 를 만들고
    (`a_flat[16..45]` 의 3개씩), weight 도 `(a, b−a, a+b)` 3개를 미리 박는다. lane_reduce 가 `pre=k1−k3,
    pim=k1+k2` 로 합친다.
- 분배: **(IC=4, OC=1, Tile=1) = 46×4 = 184 DSP, util 100%**. (OC,tile) 당 8 IC/4 = 2 cycle, 16 OC ×2 = 32 cyc/tile.

## 부록 B. 좌표 인덱싱 정리

| 항목 | 식 |
|---|---|
| input row | `4*ty + rr` (rr=tile 내 행 0..5) |
| input col | `4*tx + cc` (cc=tile 내 열 0..5) |
| rb read | `tile6[rr][cc] = rb[set_active][rr][4*tx+cc]` |
| c2pool write addr | `(4*ty+i)*24 + (4*tx+j)`, i=p/4, j=p%4 |
| bank (collector/writer) | `tcol[0]` = global tile index[0] (인접 tile 교대) |
| weight sel | `compute_cnt = oc*2 + grp` |
```
