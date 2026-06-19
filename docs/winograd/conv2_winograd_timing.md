# Conv2 Winograd F(4,3) — RTL 타이밍 (cycle-by-cycle)

> ❗ **2026-06-19 정정 — 아래 본문은 carry-bisect(+1) 값, 현행 RTL = baseline 이라 전부 −1**:
> m_valid 2oc+13→**2oc+12**(= issue+11), tag16→**15**, tg_*[16]→**[15]**, 1349→**1348**,
> truncate 2oc+18→**2oc+17**, tile_out 2oc+19→**2oc+18**, oc15 @43/@49→**@42/@48**, tail36→**35**.
> bisect 은 churn 으로 revert(journey **Iter 15**). 최종 = **171.43MHz**(VCO=1200, baseline).

> **현행 반영 (2026-06-15)**: overclock 파이프(IT **3-stage** / OT **4-stage** / gather 2+2 /
> a_q) 로 datapath latency 가 깊어져 **m_valid = 2oc+13 (= grp1 issue +12), tag 16,
> 1349 cyc/img**. 아래 cycle 표·다이어그램은 이를 반영(2026-06-04 판의 G+4/2oc+5/1336 → 정합 갱신).
> **per-hop 파이프라인 anchor(상대) + 안전수정 규칙 = `conv2_winograd_engine_arch.md` §2.1/§5**
> (중복 회피: 본 문서 = 절대 cycle·구조, arch = 상대 anchor·규칙·m_assemble 매핑).

`conv2/conv2_timing.md` 의 winograd 판. **디버깅·타 에이전트 인수인계용 cycle 표**.
알고리즘=`algorithm_complex_f43.md`(§9.1), 구현설계=`conv2_winograd_design.md`, bit-exact 정답=golden
`scripts/golden_sim/1_complex_winograd_f(4,3).py` + hw_model `scripts/weights/winograd_gen.py`.

> 상태(2026-06-04): **engine 까지 iverilog bit-exact 검증완료** — leaf(transform/lane_reduce/
> m_assemble/dsp_mul/mul_array/truncate) + `conv2_winograd_engine` e2e(40/40·100/100).
> 본 문서 = 검증된 RTL 의 cycle 표(디버깅용). FSM 은 별도 모듈 아님 — engine 내부 inline.
> feed=line-buffer(2-set row-buffer ping-pong).

> ## ★ 2026-06-05 갱신 (LUT fit 위한 2개 변경) — 둘 다 iverilog 40/40 재검증 완료
> 100T LUT 초과(78.7K>63.4K) 해결 위해:
> 1. **A. 비트폭 축소** — ±128 가정 → relu 입력 d∈[0,127] 이론 worst+1 margin 으로 재사이징
>    (`relu_bounds()`): **VW16→14, MW32→25, YW36→28, UW14→12, PW32→24, TW16→11**.
>    overflow 없음(삼각부등식 상한, §검증). transform/mul_array/output adder 폭 전반 축소.
> 2. **weight: baked ROM → PS-writable pre-transformed U (BMG+loader)** — 기존 conv2 방식.
>    LUT-heavy 상수 ROM 제거, **`wino_weight_bram`(32b×8192, SDP L=2)** + **`wino_weight_loader`**
>    → wide `wmem`(32 entry×184 op, `ram_style=block`). `wmem[sel] == 옛 ROM[sel]`(bit-identical,
>    동일 operand 순서·L=1 read 타이밍) → **mul array 값·타이밍 불변 = 동작 보존**. 첫 start →
>    **LOAD_WEIGHTS**(loader ~5888+drain cyc, 1회) → image loop. PS 가 `c2w_*` 로 5888 word write.
> 결과(2026-06-05 시점, pre-overclock): conv2 engine **40/40 bit-exact, 1337 cyc/img** (옛 ROM 1336±).
> full pipeline **40/40 logit+readback**. ※ 이후 overclock 파이프(IT3/OT4/gather)로 **현행 1349** (§9).

---

## 0. 한 줄 요약

8 IC×26×26 INT8 → 16 OC×24×24 INT8 conv 을 **6×6 tile(stride4) 36개**로 나눠,
각 tile: `V=BᵀdB`(8 IC 입력변환, 곱셈기0) → `M=Σ_IC U⊙V`(184 DSP, 16 OC×2 group=32 cyc) →
`Y16=AᵀMA`(출력변환, 곱셈기0) → `sat(Y16>>14)+ReLU` → c2pool. **1349 cyc/img 측정**(steady-state; conv2 1798 대비 **1.33×**, DSP 184 vs 192). ※ overclock 파이프 추가로 1336→**1349**(latency tail +13, throughput 불변).

---

## 1. 모듈 / 데이터플로우

```
c1c2 BMG (Port B, 64b=8IC, L=2)
   │  raster read (producer): rows[4ty..4ty+5] × cols[0..25]
[wino_row_buffers]  2-set × 6 row × 26 col × 64b. ping-pong(tile-row 단위)         §6
   │  set_active 에서 tile(ty,tx) 6×6×8IC **comb 추출**(별도 tile_buf 없음 — §3)
[wino_input_transform ×4, 3-stage]  (IT-share: grp d-mux 로 8 IC→4 변환기 time-share)  leaf✓
   │  4 IT × 46 op (★2a a_q lane reg)  →  a_flat(4 lane×46)  →  DSP B-port
[wino_mul_array]  184 DSP(3-stage)+lane_reduce+pre_q(G-1), 16 OC×2 grp=32 cyc → M    leaf✓
   │  (weight: wmem[sel=oc*2+grp] → w_q 4 lane×46.  PS BMG+loader 조립, =옛 ROM)     leaf✓
   │  gather 2+2(gpab/gpcd)→gpre_q(C-1)→grp0/grp1 누적→m_assemble(켤레) → M(complex)
[wino_output_transform 4-stage]  M(6×6 complex) → Y16(4×4 real, 곱셈기0)             leaf✓
   │
[wino_truncate N=16]  sat(Y16>>14)+ReLU → INT8                                      leaf✓
   │  per-OC 16 값 → tile_out[2 bank][16 pixel][16 OC] 수집 (bank=tcol[0], §3)
[c2pool write]  16 OC packed(128b), pixel 당 1 write, addr = (4ty+i)*24+(4tx+j)     §4
```

- **producer**(row-buffer load) 와 **consumer**(tile compute + output + write) 가 **동시 진행**,
  tile-row 단위 ping-pong set 으로 동기 (§5). 곱셈기는 mul_array 184 DSP 뿐(transform=add/shift).
- handshake(prior_wdone/rdone/succ_rdone/wdone)·bank toggle = conv2 와 **동일 의미**(§8). 주변 무변경.
- **weight load 1회**: 첫 start → `LOAD_WEIGHTS`(wino_weight_loader ~5888+drain cyc) → wmem 조립 → image loop. (옛 ROM 안의 "load 없음"에서 복귀 — §갱신.)

> ✅ **검증완료**: `TB/multi_img/tb_conv2_winograd_engine_multi.v` **40/40·100/100 bit-exact**
> vs `data/multi_img/all_c2pool.hex` (winograd==direct). 측정 **1349 cyc/img** (현행 overclock 파이프 반영; pre-overclock 은 1336).
> ★ 발견·해결한 버그 = producer L=2 read drain (§5.1).

---

## 2. 파이프라인 latency (검증된 mul_array 기준)

| 경로 | latency | 비고 |
|---|---|---|
> ★ overclock 으로 datapath 가 깊어짐. 아래는 **절대 latency**(총합), per-hop 상대 anchor 분해는 arch §2.1.

| 경로 | latency | 비고 |
|---|---|---|
| c1c2 addr → dout | 2 (L=2) | BMG output register |
| tile6 comb read → tile6_q | 1 | rb→IT register (monolithic) |
| d-mux → input_transform(★3-stage) → a_flat → a_q | 3+1 | IT 3-stage + ★2a a_q lane reg |
| a_q → DSP(3-stage) → lane_reduce → pre_q → gather 2+2 → gpre_q | 3+3 | reduce 4-cycle 분할(G-1/C-1) |
| **grp1 issue(cyc G) → m_valid & M** | **G+12** | 위 합 (옛 G+4; arch §2.1) |
| M → output_transform(★4-stage) → Y16 | 4 | 옛 0(조합) — OT 파이프화 |
| Y16 → truncate → tile_out (collector) | 2 | ⇒ **M→tile_out 총 6 cyc** (옛 2) |
| tile_out → c2pool write (writer reg) | 1 | c2_we/addr/din 등록 |

### 2.1 mul_array issue → M 정렬 (★ FSM 가 의존)

issue 시퀀스 (compute cycle c=0..31): `oc=c>>1, grp=c&1, sel=c, grp_in=c[0]`.
(sel=oc*2+grp=c 이므로 weight ROM addr = compute counter, grp-mux = c[0].)

```
compute cyc :  0    1    2    3   ...  30   31
 (oc,grp)   : 0,0  0,1  1,0  1,1      15,0 15,1
 grp1@      :       1         3            31     ← grp1 issue cycle G
 m_valid@   :          ..G+12..             43    ← M(oc) valid (oc=0→13, oc=15→43)
```

- grp0(c=2oc): accumulator **load** acc (IC0-3 partial).
- grp1(c=2oc+1): accumulator **add**(=8IC) → `m_assemble`(켤레) → `m_re_flat/m_im_flat` latch,
  `m_valid=1` @ **2oc+13** (= grp1 issue (2oc+1) + **12**; 옛 +4 → overclock 파이프
  a_q/pre_q/gather2+2/gpre_q 로 +7 + ★carry-bisect +1 = +8 깊어짐, 상대 anchor 분해 = arch §2.1).
- ⇒ M(oc) valid at compute cyc **2oc+13**: oc=0→13, oc=15→43. (마지막 issue c=31 → 마지막 M@43.)

---

## 3. consumer: tile 1개 처리 (32-cyc 연속 issue + drain)

set_active(row_buffer) 에서 tile(ty,tx) 6×6 를 **comb 추출**(tile6) → 8 input_transform(comb)
→ mul_array 에 32 cyc 연속 issue. **별도 tile_buf 레지스터 없음** — tile_cnt 가 그 32 cyc 동안
고정이라 comb extract 가 안정(producer 는 다른 set 에 write). M·output·tile_out 은 파이프 지연 stream:

| 단계 | 시점 (compute cyc) | 근거 |
|---|---|---|
| issue (oc,grp) | c = 0..31 | grp1(oc) @ c=2oc+1 |
| `m_valid(oc)` + M latch | **2oc+13** | grp1 issue +12 (§2.1) |
| truncate(oc) out | 2oc+18 | OT 4-stage + trunc (m_valid+5) |
| `tile_out[bank][*][oc]` latch | **2oc+19** | collector +1 (coc=tg_*[16]) |

- oc0: m_valid@13 → tile_out@19.  oc15: m_valid@43 → **tile_out@49 (= tile 완성)**.
- 다음 tile issue 는 cyc 32 부터 **연속**(파이프 안 비움) → tile 당 실효 **32 cyc**.
  마지막 OC 의 M/output drain(@43,@49) 과 §4 write 는 다음 tile compute 그림자에 겹침.

### 3.1 tile_out 수집 상세 (collector)

`m_valid` 마다 그 OC 의 M → output_transform(★4-stage) → wino_truncate(N=16, 1cyc) → collector
가 `tile_out[bank][pix][oc]` 에 등록 (M→tile_out 총 **6 cyc**: OT4+trunc1+coll1; coc=tg_*[16]).
- truncate 입력 = 한 OC 의 16 Y16(=4×4). 출력 16 INT8 = 그 OC 의 16 pixel 값.
- 기록 위치: `tile_out[bank][i*4+j][oc] = trunc(Y16[i][j])`, p=i*4+j (0..15), i=row j=col (tile 내).
- **bank = tcol[0]** (= global tile index[0], 6·ty 짝수). 인접 tile 이 bank 교대 → writer(이전 tile,
  §4)가 한 bank read 하는 동안 collector(현 tile)는 다른 bank write → 충돌 없음 (double-buffer).
- M 의 oc/tile 좌표는 issue 시점에서 4-cyc 지연한 tag(`tg_oc/trow/tcol[4]`)로 추적(cross-tile 정렬).
- oc15 기록(@2·15+7=37) = tile 완성 → `tile_done` → writer trigger.

---

## 4. consumer: c2pool write (tile_out → BMG)

tile_out 완성 후, **pixel 당 1 write** (16 OC packed 128b). 16 write/tile.
- pixel p (p=0..15, i=p/4, j=p%4): c2pool_din = {tile_out[p][15],…,tile_out[p][0]} (OC15..OC0).
- c2pool_addr = {output_bank_sel, (4ty+i)*24 + (4tx+j)} (10-bit local = output pixel raster index).
- 16 write 는 다음 tile 의 32-cyc compute 와 겹침 (16<32). write port 는 c1c2 read 와 독립.

> ★ conv2 는 raster 순차 write_addr++ 였지만 winograd 는 tile 단위라 **addr 명시 계산**(r*24+c).
> maxpool 은 wdone 후 bank 전체를 read → tile 내/간 write 순서 무관 (576 pixel 다 쓰이면 됨).

---

## 5. tile-row ping-pong (producer ∥ consumer)

2-set row-buffer. tile-row ty 동안:
- **consumer**: set_active(=ty%2) 에서 6 tile(tx=0..5) 처리 = 6×32 = **192 cyc**. tile_cnt wrap 시
  trow_cnt++ → set swap (**무조건** 진행 — RUN 중 producer 대기 없음).
- **producer**: set_load(=~ty%2) 에 tile-row ty+1 의 6 row(rows 4(ty+1)..4(ty+1)+5) load = **156 read**(+L2),
  consumer trow_cnt 보다 1 tile-row 앞서 적재(`pld_can_start`: trow_cnt+1≥pld_trow).
- **156 < 192 → producer 가 항상 먼저 끝나 stall 없음** (이 timing margin 이 정확성 전제;
  set_ready gate 는 LOAD_INIT→RUN 진입에만 사용, RUN tile-row 경계엔 미사용).

```
tile-row:   ty=0           ty=1           ty=2          ...   ty=5
consumer:   [compute set0] [compute set1] [compute set0] ... [compute set1]
producer: [load set0]→[load set1]    →[load set0]    →...        (ty=5 후 load 없음)
            (초기 160)    (192 그림자) (192 그림자)
```

- 초기 set0 load(rows 0..5) = 1(PIDLE entry) + 156(PLOAD) + 2(PDRAIN L2) + 1(set_ready→RUN) = **160 cyc**(이 구간 consumer idle).
- 이후 tile-row 마다 max(192 compute, 156 load) = 192.

### 5.1 ★ producer L=2 read drain (PDRAIN) — 필수 (버그픽스)

c1c2 BMG 는 **L=2 + enb-gated** (`if(enb){pre<=mem[addr]; doutb<=pre;}`). row load 의 마지막
addr(row5,col25) 를 issue 한 직후 `c1c2_re`(=enb)를 내리면, 그 read 가 doutb 까지 전파 못 함
→ **마지막 cell(rb[5][25]) stale**. 이는 tile(ty,**tx=5**) 의 d[5][5] → V[5][5] → M[5][5] →
**Y16[3][3] (=pixel p15) 만** 오류 (M[5][5]=∞-점, Aᵀ col/row 5 가 오직 Y16[3][3] 에만 기여).
data-dependent(stale≠정답일 때만) → 일부 image 의 addr (4ty+3)·24+23 1픽셀 오류로 발현.

**해결**: producer FSM 에 `PDRAIN`(2 cycle, `c1c2_re` 유지, addr=(row5,col25) hold) 추가 →
마지막 2 read 가 doutb→rb write 까지 완료. set_ready/pld_trow++ 는 PDRAIN 종료 후.
([[bmg-l2-regceb-abrupt-stop]] 와 동일 class — L=2 read 는 항상 enb 2-cyc drain 필요.)

---

## 6. wino_row_buffers (2-set × 6 row × 26 col × 64b)

- 저장: `reg [63:0] rb [0:1][0:5][0:25]` (2 set, 6 row, 26 col, 8 IC packed). ~20Kb.
- **write**(producer): set_load 에 (row rr, col cc) ← c1c2 dout. nested counter rr 0..5, cc 0..25.
- **read**(consumer, comb): tile(ty,tx) → tile6[rr][cc] = rb[set_active][rr][4*tx+cc] (rr,cc 0..5).
  6×6×8IC = 2304-bit comb 추출 → **바로** input_transform (tile_buf 레지스터 없음, §3).
- comb read(36-way) → distributed RAM/FF + mux. (v1: 정확성 우선, 자원 최적화는 후속.)
- iverilog: generate+assign 의 3D 동적 index 가 충돌 → read 는 `always @(*)` 루프로 구현.

> row rr (0..5) = tile-row 내 상대 행. set_active 의 rb[.][rr][.] = input row (4ty+rr).
> tile(ty,tx) 의 d[rr][cc] = rb[set][rr][4tx+cc] = input(4ty+rr, 4tx+cc). ✓ (golden d 와 동일 인덱스.)

---

## 7. FSM 상태 + 카운터 (conv2_winograd_engine 내부 — 별도 모듈 아님)

main FSM + producer FSM(PIDLE/PLOAD/PDRAIN, §5.1) 병행. weight load = LOAD_WEIGHTS 1회.

```
main FSM:
IDLE        : reset 후 start 대기 (start=PS 1-cyc pulse)
LOAD_WEIGHTS: 첫 start 1회. wino_weight_loader(narrow BMG→wmem, ~5888+drain) → loader_done
              → WAIT_IMG. (이후 image loop 에선 재진입 안 함.)
WAIT_IMG    : ready_to_compute(data_ready & output_avail) 대기 (handshake §8)
LOAD_INIT   : tile-row0(set0) row load 완료(set_ready[0]) 대기 — consumer idle
RUN         : tile-row 0..5 처리. consumer(compute) + producer(다음 row load) 동시.
              compute_cnt(0..31)/tile_cnt(tx)/trow_cnt(ty). last_issue 시 → DRAIN
DRAIN       : 마지막 tile M drain(mul_en window) → tile_done → 16 c2pool write → wdone
              → WAIT_IMG.  RUN 뒤 노출 span = **36** cyc(§9; tile_out@2oc+19 의 +49 은 tile 내
              index 라 이미 1152 에 포함, 16 write 는 36 안). (rdone 은 마지막 c1c2 read 후 = RUN 중)
```

주요 카운터:
| 카운터 | 범위 | 의미 |
|---|---|---|
| `compute_cnt` | 0..31 | tile 내 mul issue cycle. =sel(wmem read addr), [0]=grp |
| `tile_cnt` (tx) | 0..5 | tile-row 내 tile. compute_cnt wrap 시 ++ |
| `trow_cnt` (ty) | 0..5 | tile-row. tile_cnt wrap 시 ++. set_active=trow_cnt[0] |
| `pld_trow`/`pld_row`/`pld_col` | 0..6 / 0..5 / 0..25 | producer load 위치 (set_load=pld_trow[0]) |
| `wr_pix` | 0..15 | tile_out → c2pool write pixel index |

control → datapath:
- mul_array: `en`(RUN compute 중 1), `grp_in`=compute_cnt[0], weight ROM `sel`=compute_cnt.
- grp-mux: compute_cnt[0] (0→IC0-3, 1→IC4-7).
- truncate `en`: m_valid (per-OC).
- c2pool write: wr_pix 진행 중 we=1.

---

## 8. Handshake (conv2_fsm 미러 — race-free)

```
prior_diff = (conv2w rdone count) - (conv1 wdone count)   ; data_ready  = prior_diff_next < 0
after_diff = (conv2w wdone count) - (maxpool rdone count) ; output_avail= after_diff_next < 2
ready_to_compute = data_ready && output_avail   (combinational next-value, NBA race 회피)
input_bank_sel  toggle on rdone   (c1c2 read bank)
output_bank_sel toggle on wdone   (c2pool write bank)
```
- `rdone` (1-cyc pulse): image 의 **마지막 c1c2 read** 후 (= tile-row5 row load 끝, RUN 중). conv1 이 그 bank refill 가능.
- `wdone` (1-cyc pulse): image 의 **마지막 c2pool write**(tile-row5,tile5,pixel15) 후. maxpool 이 read 가능.
- 속도 가정 없음 (counter backpressure). conv2 와 동일 의미 → maxpool/conv1 무변경.

---

## 9. cycle budget (img 1장, @200MHz floor)

| 항목 | cycle |
|---|---|
| WAIT_IMG | 1 |
| LOAD_INIT (tile-row0 row load) | 160 |
| compute (36 tile × 32) | 1152 |
| 마지막 tile DRAIN tail (last-tile M drain → tile_done → 16 write → wdone) | **36** |
| **steady-state period (= wdone↔wdone)** | **1349** |
| **측정 (iverilog full-pipe, avg cyc/img)** | **1349** ✅ |

> ★ 정정: pre-overclock 1336(tail 23) → 현행 **1349**(tail **36**). tail +13 = overclock 파이프
> (m_valid 2oc+5→2oc+13, tile_out@2oc+7→**@2oc+19**, OT 4-stage) 가 **마지막 tile** drain 을 깊게 함
> (steady-state 의 tile-내 drain 은 다음 tile 그림자에 겹쳐 double-count 아님 — RUN 뒤 노출은
> 마지막 tile 1개분). LOAD_INIT 160(=1 PIDLE + 156 PLOAD + 2 PDRAIN + 1 set_ready→RUN), compute
> 1152(36×32) 는 불변. **1+160+1152+36 = 1349.**

- conv2 1798 대비 **1.33×** (1349 cyc, DSP 184 vs 192). conv1_2x(~837)·maxpool(~590)·FC(~640) 와 함께 conv2-wino 가 bottleneck.
- 후속 최적화: image 간 LOAD_INIT 겹치기(다음 image 의 tile-row0 를 현 image 끝물에 load) → ~1200.

---

## 10. 검증

1. ✅ leaf 단위: transform(2000)/mul_array(1000)/truncate(4000) vs hw_model, iverilog.
2. ✅ **engine e2e**: `tb_conv2_winograd_engine_multi` (tb_conv2_engine_multi 변형) — c1c2 주입(all_c1c2.hex),
   c2pool == `data/multi_img/all_c2pool.hex` (winograd==direct 라 **기존 golden 재사용**). **100/100 bit-exact**.
   ★ TB 의 c2pool 비교는 `c2pool_bram.mem` **직접** read (BMG L=2 read-port timing 배제 → DUT write 정확성 직접 확인).
3. ✅ **full pipeline**: `cnn_accelerator.v` 의 conv2 → `conv2_winograd_engine` swap (+ conv1_2x) →
   `tb_cnn_accelerator_multi` **40/40 logit bit-exact + bram_output readback**, overlap **1337 cyc/img**
   (2026-06-05 A 폭축소 + PS weight 재검증).  표준 conv2 engine 도 **40/40, 1337 cyc/img**.
4. ☐ (남음) Vivado: dsp48e1_model/bmg_sim_models 제외, **wino_weight_bram** = 실 BMG IP(32b×8192,
   SDP, L=2 regceb, Port A byte-write).  c2w_* AXI BRAM Ctrl 유지(depth 1024→8192 재구성),
   firmware 가 `conv2_winograd_weights[5888]` write.  DSP 238/240.

## 11. open risks / 후속
- ✅ (해결) producer L=2 read drain — §5.1 PDRAIN.
- ✅ (해결) **LUT fit**: A 폭축소 + weight ROM→BRAM(BMG+loader) → §갱신. (synth WNS/util 은 Vivado 재확인.)
- **Vivado 미검증** (iverilog bit-exact 만). row_buffer 는 comb-read reg array(2×6×26×64b≈20Kb) →
  FF/LUTRAM 추론 (100T 여유). 여전히 후속 BRAM/registered-read 로 자원·타이밍 최적화 검토(다음 LUT 레버).
- 200MHz: transform adder·184 DSP route → max_fanout/register 후속(overclock 교훈). weight 는 이제
  BRAM read(L=1, w_q) → comb ROM 경로 제거됨(§갱신 #1 register stage 와 정렬).
- image 간 LOAD_INIT(160) 비중첩 → 후속 다음 image tile-row0 prefetch 로 ~1200 가능.
- cnn_accelerator drop-in: conv2 instance → conv2_winograd_engine, **c2w_* Port A 결선**(PS pre-transformed
  U write), wino_weight_bram IP. 나머지 배선·handshake 동일.
