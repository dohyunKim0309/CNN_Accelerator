# Winograd conv2 Overclock Journey — 문제 → 해결 → 결과

> 복소수 Winograd F(4,3) conv2 (184 DSP) 를 Arty A7-100T 에서 **200MHz drop-in** 으로 닫기
> 위한 반복 기록. 각 iteration = **문제 → 해결 → 결과**. 정적 타이밍 카탈로그(§A) 포함.
>
> **목표 latency** (full pipeline 1341 cyc/img, baseline direct-conv2 = 98ms@200MHz):
> | freq | latency | vs baseline |
> |---|---|---|
> | 150MHz | 89.4ms | 1.10× |
> | 175MHz | 76.6ms | 1.28× |
> | **200MHz** | **67.0ms** | **1.46×** |
>
> 검증 원칙: 모든 변경 = **bit-exact 보존**(register 위치/latency 만, 데이터 값 불변).
> iverilog standalone(`tb_conv2_winograd_engine_multi`, 40/40) + full pipeline
> (`tb_cnn_accelerator_multi`, 40/40 logit+readback) 매 단계 검증 후 Vivado.

---

## Iteration 0 — baseline (출발점)
- **상태(journey 시작점, pre-overclock)**: winograd conv2 engine iverilog bit-exact (1337 cyc/img). DSP 184(=4 lane×46). drop-in (conv2 자리, c1c2/c2pool/handshake 동일). ※ 최종(Iter 15): **baseline 1348 cyc/img @ 171.43MHz** (bisect 은 churn 으로 revert).
- golden = `scripts/golden_sim/1_complex_winograd_f(4,3).py` (10000장 bit-exact). 생성기 `scripts/weights/winograd_gen.py` = 단일 진실원(transform/lane_reduce/m_assemble + weight hex emit).

---

## Iteration 1 — Place LUT overflow
- **문제**: Vivado place 실패 `[Place 30-487]`, LUT **78.7K > 63.4K**(100T). area(LUT) 초과, timing 아님. 상수 weight ROM 이 LUT-heavy.
- **해결**:
  1. **A. 비트폭 축소** (`relu_bounds()`): conv2 입력 d=relu(conv1)∈[0,127] 이론 worst-case → VW16→14, MW32→25, YW36→28, UW14→12, PW32→24, TW16→11. 삼각부등식 상한이라 overflow 없음.
  2. **weight ROM → PS-writable BMG**: 상수 ROM 제거, `wino_weight_bram`(32b×8192) + `wino_weight_loader` → wide `wmem`. PS 가 pre-transformed U 를 write.
- **결과**: place fit (**LUT 85%**), 그러나 **route_design 무한 hang** (200MHz 50분, 150MHz 4h 동일 줄에서 멈춤). → 알고리즘 아닌 **routing congestion**.

---

## Iteration 2 — Route congestion: weight read 버스
- **문제**: route hang. 진단 = `wmem` 단일 BRAM → **2208-bit weight read 버스가 매 cycle 184 DSP 로**. BRAM column(고정·희소)→흩어진 DSP = routing track oversubscribe. ★user 통찰: baseline(192 DSP + weight-stationary SIMD)는 route 됨 → **알고리즘 아닌 구현방식 문제**.
- **해결** (복붙 = engine + loader):
  1. **per-PE 분산 LUTRAM**: `wmem` 단일 2208-bit 배열 → operand별 `(* ram_style="distributed" *) reg[UW-1:0] wmem_op[0:31]` **184개**(generate). 각 RAM 이 자기 DSP 근처(SLICEM) 배치 → read 완전 local, 2208-bit 단일 broadcast 소멸.
  2. **narrow loader**: wide assembly+한방 write → operand 1개씩 narrow(`wm_op`+`wm_addr`+`wm_data` 12b).
  3. **compute_cnt 4-copy** (lane, lockstep next-state, `keep`): read addr fanout 184→~46/lane 단계화.
- **결과**: route **진행**(hang 탈출). place **LUT84 / LUTRAM16 / FF42 / BRAM42**(BRAM 65→42 = weight 버스 발원지 제거 확인). 그러나 **WNS −10.276 @150MHz** (timing 실패).

---

## Iteration 3 — WNS −10.5: 출력변환 + 5부류
- **문제**: `report_design_analysis -timing` → **실패경로 5부류**(전부 net 65~96% + 초고fanout):
  - **A** (최악 −10.5): `m_*_flat_reg → wino_output_transform(Aᵀ·M·A) → wino_truncate` = **20 logic level 단일 cycle**.
  - **B** (−7.8 대량): `tile_cnt/trow_cnt_rep(fanout 302) → rb 36-way read → input transform → a_flat_q`.
  - **C**: `compute_cnt_l(fanout 552) → per-PE RAMD32 read`.
  - **D** (~40%): `wm_* → RAMD32 write` (startup-only).
  - **E**: mul_array accumulator (`acc→m_*_flat`, 14단).
- **해결** (복붙 = output_transform + engine + loader):
  1. **A 출력변환 2-stage 파이프라인**: `emit_output_transform` clocked(in_valid→out_valid+2, y=Aᵀ·M reg, Y16=y·A reg). 엔진 tag 5→7, collector `tg[7]`, `u_tr` en=ot_valid.
  2. **★B 재정렬-0 fix**: register 를 `a_flat_q`(transform 뒤)→**`tile6_q`(transform 앞)** 이동. `[rb_read]`|`[transform→DSP BREG]` 분할 — **DSP 입력 register(BREG)가 2번째 단** → latency·tag 완전 불변(a_flat comb 로 mul array 직결, grp_q 추가).
  3. **C/D max_fanout**: `compute_cnt_l`=64, `wm_*`=24, `tile_cnt`/`trow_cnt`=40.
- **결과**: **WNS −10.5 → −6.337 @150MHz** (~4ns↑). **고친 5부류 전부 top-10 탈출**(전부 먹힘). 새 worst = 입력변환(13단, B 재정렬의 period 2).

---

## Iteration 4 — WNS −6.3: 입력변환 + reduce chain (현재)
- **문제**: 정적 전체 리뷰(§A) 결과, **단일 cycle 깊은 조합 블록**이 근본. 남은 2곳:
  - **B 입력변환** `Bᵀ·d·B` = **13단** (현 worst). ★V 는 tile당 32-cyc 상수 → per-cycle 경로에 있을 이유 없음.
  - **C mul_array reduce chain** `lane_reduce→cross-lane→msum→m_assemble` = **~14단**.
  - 근본 = 생성기가 변환을 순수 조합 emit. + net 60%+ 지속 = **98% DSP 배치분산(congestion)** = logic 과 별개 벽.
- **해결** (복붙 = input_transform + mul_array + engine):
  1. **B-1 입력변환 파이프라인**: `emit_input_transform` clocked(stage1 t=Bᵀd → reg → stage2 V=t·B+assembly, +1). 재정렬: per-PE `w_q_op2`(weight +1, local) + `grp_q2` + `mul_en_q2`/`mul_grp_q2` + tag 7→9 + drain.
  2. **C-1 reduce chain register**: `wino_mul_array` cross-lane 합 `gpre/gpim` → `gpre_q/gpim_q`(register), `grp_pipe`/`vld_pipe` 3→4-deep([3]). +1.
- **결과**: **iverilog 40/40 (engine 1341 cyc/img, full pipeline 40/40 logit+readback)**. cyc/img 1337→1341(파이프 +4, throughput 불변). **Vivado route 재시도 PENDING**.
  - 예상: B·C 로 logic 벽 200급 제거. 단 **net(congestion) 잔존 → 175~200 경계**. 200 확정은 floorplan(§B) 성패.

---

## Iteration 5 — 근본원인 재정의 + V-stationary 시도 → 면적 기각 (2026-06-11, Claude/Fable 5)
- **문제 재정의**: Iter 4 로 깊은 조합블록은 제거됐으나 200MHz 미달 지속. 근본원인 재분석
  (`WINOGRAD_200MHZ_CLOSURE_PLAN.md`): 남은 벽은 max_fanout 으로 복제 *불가능한* 부류 —
  **fanout-1 광폭 distinct-data 버스의 per-cycle 전역 이동** (a_flat 2576b scatter +
  184-DSP product gather)이 변환 logic 과 한 cycle 에 직렬. baseline 이 닫힌 이유 = 그쪽
  벽은 전부 "동일값 broadcast"(복제 가능 부류)였기 때문.
- **시도 (V-stationary)**: per-PE V 더블버퍼(4×VW)+prefetch(dist1→dist2)+PRIME 으로
  per-cycle scatter 완전 제거. **iverilog 100/100 ×2 (1347 cyc/img) 통과**했으나 Vivado
  **`Place 30-487` 면적 기각**: slices 12813 > 9894, FF 87.7K, LUT 69K(total),
  **control set 2272** (prefetch CE × max_fanout 복제가 control set 폭증 → FF packing 불가).
- **★교훈**: max_fanout 복제는 route 를 사지만 **CE 에 쓰면 control set 으로 면적을 지불**.
  99% DSP + LUT 85% 칩에선 FF/CE/control set 예산이 1급 제약. (구현본은 git 이력에 보존 —
  200T 급에선 유효한 안.)

## Iteration 6 — ★2a per-lane activation reg + G-1 gather 분할 (2026-06-11, 채택)
- **해결** (1/10 면적으로 같은 원인 처리 — die 횡단 net 에 전용 cycle 부여):
  1. **★2a** (`aflat_locality.md` 레버 2a): `a_q_l[0:3]`(per-lane registered grp-mux,
     2576b, reset/CE-free) → [stage2+grp-mux→a_q_l] | [a_q_l→46 DSP BREG] 분할.
     B-port +1 정렬 = w_q_op3(per-PE) + mul_en/grp_q3 + tag 11단.
  2. **G-1**: mul_array lane-local lpre_q/lpim_q (free-run, CE-free) → [PREG→lane_reduce]
     | [cross-lane 합] 분리. +1.
  - 신규 CE 0개(전부 free-run) → control set 불변. ΔFF ≈ +10K (a_q_l 2.6K + w_q_op3 2.2K
    + lpre/lpim 5.2K), LUT ±0.
- **결과**: iverilog standalone **100/100** + full pipeline **100/100** bit-exact,
  **1343 cyc/img** (+2, latency-only).
- **2차 place 기각 (LUT 벽)**: slices 10373 > 9531, **LUT combined 95%** (FF 는 69K 로
  해소 확인). post-synth LUT 90.25% — 이번 벽은 LUT.
- **★IT-share (입력변환 8→4)**: grp-mux 가 매 cycle 8개 변환 출력 중 4개만 소비 →
  변환기 절반이 상시 낭비였음. grp-mux 를 출력(46×VW)에서 **입력(36×8b) d-mux** 로
  옮기고 변환기 4개로 반감 — d-mux@(T+1)=grp_q 로 타임라인 동일(tag/drain 무변경).
  LUT −~6K, FF −3.2K. iverilog 100/100 ×2 재검증 (1343 cyc/img 불변).
- **3차 synth (Vivado 실측)**: Slice LUTs **48,110 (75.9%)** / FF 62,221 (49.1%) / control set
  2,101 — 면적 벽 통과 확인. conv2(wino) 단독 = 32.2K LUT / 41.3K FF / 184 DSP.

## Iteration 7 — 첫 routed: WNS −2.037 → row buffer 구조 교체 (2026-06-11)
- **첫 route 완주** (phys_opt 미사용): clk_out3(200MHz) **WNS −2.037 / TNS −31,373 /
  failing 42,776** (+clk_out1 −0.166/32). worst path =
  `u_rb` **write data broadcast**: wr_data 1bit → rb word FF 312개(2set×6row×26col) D핀,
  **logic 0단 / route 93% (6.33ns)**, SLICE_X60Y84→X39Y185 (세로 2+ 클럭리전).
  = baseline 의 reset/shift_en 과 같은 "동일값 broadcast" 부류 + rb 20K-FF 산개가 근원.
  failing 42K 는 rb D핀(312×64=20K) + 주변 congestion 피해자 — baseline 의
  "reset 하나 닫자 1343→44개" 패턴과 동형 구조.
- **해결 (복붙 = wino_row_buffers + engine)**:
  1. **rb → 분산 LUTRAM 구조 교체**: 6 row-bank × 64-deep(2set×26col) × 64b
     `ram_style="distributed"`. FF 20K + 12:1 read-mux 트리(~5K LUT) 제거 → ~1.3K LUTRAM.
     col-mux 는 RAM 주소({set,4tx+cc})로 흡수(read gather 소멸), write 는 bank-local
     narrow(fo=312 broadcast 소멸). weight per-PE LUTRAM(Iter 2)과 동일 처방.
  2. **write +1 register(wr_*_q, max_fanout=32)** + engine **PDRAIN 2→3 cycle**
     (set_ready/rdone 가 실제 landing 후 발화).
- **검증**: iverilog standalone **100/100 (1344 cyc/img, +1)** + full **100/100** +
  듀얼클럭 CDC **10/10**. 다음 run 은 phys_opt(AggressiveExplore) 포함 권장.
- **+ 계층 리팩터 (2026-06-12 확정형)**: `wino_mul_array` = **46-DSP lane 단위 모듈**
  (★2a a_q reg + per-PE weight RAM/op3 정렬 + 46 DSP + lane_reduce + ★G-1 pre_q —
  "lane 에 local 인 모든 것"). engine 이 **4개 인스턴스**(`conv2/lane[N].u_mul`,
  pblock/LOC 핸들)하고 cross-lane 누적(gpre_q/acc/msum/m_assemble/vld·grp pipe)은
  engine 이 직접 보유. netlist 동일 — 3 TB 동일 결과 재확인.
  **top 모듈명 = 파일명 일치**: `cnn_accelerator_winograd` (baseline `cnn_accelerator`
  와 중복모듈 함정 해소 — 단 Vivado BD module reference 재생성 필요).
  ※ `TB/winograd/tb_wino_mul_array.v` 는 옛 wrapper 인터페이스용 → DEPRECATED 표기
  (회귀 gate = engine/full/2clk 3종).
- **★듀얼클럭 시스템 CDC 검증 (보드 반납 후 무보드 검증)**: 신규
  `TB/multi_img/tb_system_axi_winograd_multi_2clk.v` — CSR AXI-Lite@100MHz +
  datapath@200MHz (정확 2:1, t=0 동시 출발 = MMCM 위상정렬 worst-case), winograd U
  5888-word Port A 적재 포함. **10/10 logit bit-exact + 10/10 bram_output readback,
  img_cnt 정확 +1 (2배카운트/펄스손실/데드락 없음)** — baseline 보드 실측이 검증한 BD
  껍데기 위에서, 새로 바뀐 부분(가속기+wino weight 경로+CDC)의 시스템 동작 증거.
  상세/fallback ladder = 프로젝트 루트 `WINOGRAD_200MHZ_CLOSURE_PLAN.md`.

---

## Iteration 8 — 2차 routed: WNS −1.735 → 변환 파이프 심화 (2026-06-12)
- **2차 route** (rb LUTRAM 반영, phys_opt 無): WNS **−1.735** / ~27K EP (−2.037 에서 개선,
  rb 부류 top-30 소멸 = Iter 7 적중). 30 worst 분포 (`docs/overclock/winograd/03_*`):
  **29/30 = 출력변환** (m_flat→y 27 + y→y16 2, logic 10-12단 = CARRY4 6-8 직렬 ~3.3ns
  + route ~3.2ns), 1/30 = IT stage2→a_q (−1.4).
- **해결 (생성기 갱신 — 단일 진실원 유지, `winograd_gen.py` emitter 수정 후 재생성)**:
  1. **OT 2→4-stage**: `_lincomb_chunks`(2-term 부분합 분할) → 1a 부분합 reg → 1b y=Σ reg
     → 2a 부분합 reg → 2b Y16=Σ reg. stage당 add ≤2단. out_valid = in_valid+4.
  2. **IT 2→3-stage**: stage2 를 2a 부분합 reg / 2b 최종합+assembly 로 분할. a_flat = d+2.
  3. engine/array 정렬: B-port +4 (w_q_op4/mul_*_q4), m_valid = issue+**10**, tag **14단**.
  - 부분합 폭 = 전체 삼각부등식 상한 이하라 동일 폭 안전. 전부 reset/CE-free.
- **검증**: standalone **100/100 (1347 cyc/img, +3)** + full **100/100** + 2clk CDC **10/10**.
  (raw 리포트 폴더 = `docs/overclock/winograd/NN_<단계>_<핵심결과>/` 로 개명, README 색인 추가.)

## Iteration 9 — 지층 일괄 처리 (2026-06-12, `wino_strata.tcl` 분석 기반)
- **신규 진단 도구**: `wino_strata.tcl` (routed design 에서 source) — 실패 endpoint 전체를
  클래스별 [worst slack | count] 지층표로 집계 + OT 제외 worst 100 상세.
  ("OT 들어내면 뭐가 남나"를 run 돌리기 전에 확인 — `03_*/wino_strata_summary.rpt`.)
- **OT(−1.73) 아래 지층과 처방** (Iter 8 의 IT3/OT4 가 이미 잡은 a_q −1.53 제외):
  | slack | 클래스 | 처방 |
  |---|---|---|
  | −1.42 | `w_q_op2_srl2` (cnt_l→RAM read→**SRL 흡수**) | **`shreg_extract="no"`** — op 체인이 SRL16 로 합쳐져 물리 재배치 자유도 상실. FF 강제 |
  | −1.40 | loader wm_* → 184 RAM write 버스 (1.2K EP, startup-only) | lane 입구 **wm_*_q +1 재타이밍** |
  | −1.38 | trunc_out → `tile_out` 4096 FF (950 EP) | `out_flat`/`cwe`/`coc` **max_fanout=16** |
  | −1.34 | pre_q×4 → 4-add → gpre_q (219 EP) | **2+2 트리**(gpab/gpcd reg, +1) → m_valid issue+**11**, tag **15단**, pipe 6단 |
  | −1.37/−1.35 | conv1_2x weight bc / pe_en_sr | `PE_BC_DELAY=2` (top 인스턴스, FSM 무변경) + packed_w max_fanout 16→8 |
  | −1.31 | gpre_q→acc (소수) | congestion 완화 + phys_opt 관망 |
- **심층 재분석 추가분** (지층표 전수 + 거시집계):
  | slack | 클래스 | 처방 |
  |---|---|---|
  | −1.23~−0.93 | **rst_l1→rst_leaf hop 자체** (~60 EP) — baseline #1 교훈 재림 | **reset 3-level 트리**: rst_l2 삽입 + l1 mf 32→16 (deassert +1, idle-start 무해) |
  | −1.31~−1.19 | u_rb bank RAM write (779 EP) | wr_*_q **mf 32→8** (bit당 sink ~12 라 32 론 복제 미발동이었음) |
  | −1.29~−1.1 | u_wload wm_addr replica 사슬 (~80 EP) | (wm_*_q lane 재타이밍이 구조적으로 해소 — 추가조치 無) |
  | −1.26 | tile6_q (110 EP, rb read) | **관망** — 잔류 시 ra 사전 register(+1 재정렬) 예비 |
  | −1.24/−1.11 | IT stage1→treg (26 EP) | **관망** — 잔류 시 stage1 도 2+2 분할 (생성기 1줄) |
  | −1.2/−1.14 | msum→m_flat (49), maxpool p01 (19), fc adder/pe (35), c2_din_r (14) | congestion 피해자 추정 — phys_opt 후 재평가 |
  ※ 지층표는 MAXP=6000 캡처라 **−0.9~0 구간(~21K EP)은 이번 표 밖** — 대부분 위
  클래스들의 congestion 피해자로 추정 (baseline "reset 닫자 1343→44" 패턴).
- **검증**: standalone **100/100 (1348 cyc/img, +1)** + full **100/100** + 2clk CDC **10/10**.

## Iteration 10 — 3차 routed: WNS −0.417 → wm equiv-merge 함정 (2026-06-12)
- **3차 route**: WNS **−1.735 → −0.417** (Iter 8+9 의 3개 지층 일괄 제거 적중,
  failing 7,195 / TNS −596 = 평균 −0.083 의 잔불). phys_opt AggressiveExplore "did not
  improve" — 복제/재배치로 안 줄어드는 worst 라는 신호.
- **진단** (`docs/overclock/winograd/04_route_wns-0.41_wm-equiv-merge/`): worst 30 이 전부 한 클래스 —
  **`lane[0].u_mul/wm_we_q → lane[1..3] RAM/WE`** (route 85%, logic 2단).
  Iter 9 의 lane별 wm_*_q 재타이밍이 **4 lane 등가 register 라 합성이 1벌로 merge** →
  die-spanning write 버스가 +1 cycle 어긋난 채 부활. 병합된 wm_addr_q net **fanout 2,944**
  (fanout 리포트 실측). compute_cnt_l 의 "keep=equiv-merge 방지" 함정과 동일 — wm 에만 누락.
- **해결**:
  1. wm_*_q 에 **`(* keep = "true", max_fanout = 16 *)`** — lane별 4벌 물리 보존.
  2. (fanout 리포트 2차 발견) rb **bank WE 사전 디코드**: 옛 [wr_en_q & row==gr] 디코드
     LUT 출력이 bank 당 fanout 516 (−0.19) → row decode 를 q단 앞으로, `wr_bank_we_q[6]`
     등록 WE + max_fanout=64. landing cycle 불변 (PDRAIN 3 유지).
- **검증**: standalone 100/100 (1348 cyc/img 불변) + full 100/100 + 2clk CDC 10/10.
- ★교훈 (재발 2회차): **동일 신호의 의도적 다중 copy 에는 반드시 keep** — max_fanout 은
  "복제를 만들" 수는 있어도 "이미 쓴 복제를 지키지" 못한다.

## Iteration 11 — 4차 routed: WNS −0.341 / **40 EP** → 막판 3클래스 (2026-06-12)
- **4차 route**: keep 수정 적중 — failing **7,195 → 40 EP**, TNS −596 → **−4.585**.
  (baseline 의 −0.154/44 EP 국면과 동형.) phys_opt AggressiveExplore 무반응 지속.
- **40 EP 분류** (`docs/overclock/winograd/05_*/wino_paths40.rpt`) + 처방 (전부 zero-latency):
  | slack | 클래스 (EP) | 처방 |
  |---|---|---|
  | −0.34~−0.23 | IT stage2b **c+d assembly** → a_q (9) — [vre최종+vim최종+합] 3-chain 직렬 | 생성기: cmul 슬롯 c+d 를 stage2a **전용 부분합**으로 (c+d = Σ tre·(RE+IM)+tim·(RE−IM), Bᵀ 단성분이라 계수 {0,±1,±4} 유지) → 2b 가 자기 partial 의 balanced 합 |
  | −0.23~−0.15 | tile6_q→IT stage1 (route 66%, 11) | tile6_q/grp_q **max_fanout=8** |
  | −0.13 | lane 내 wm_op_q→RAM WE (16, startup) | wm_*_q mf **16→4** |
  | −0.08~−0.03 | gpab/gpcd→gpre_q (4) | 관망 (압력완화+phys_opt 영역) |
- **검증**: standalone 100/100 (1348 cyc/img 불변) + full 100/100 + 2clk CDC 10/10.

## Iteration 12 — 5차 routed: WNS −0.094 / **7 EP** → class B 분할 (2026-06-15)
- **5차 route** (Iter 11 처방 일괄 반영 후): WNS **−0.341 → −0.094**, failing **40 → 7 EP**.
  (스크린샷 −0.146/13 은 그 직전 route; 재route 로 −0.094 까지 좁혀짐.)
  ★ phys_opt AggressiveExplore **여전히 무반응** — 남은 3클래스가 phys_opt 영역 밖임을 확정.
- **7 EP 분류** (`docs/overclock/winograd/06_route_wns-0.094_MBD-baseline/` : strata/paths/da — ★현재 baseline):
  | slack | 클래스 (EP) | 성질 | 처방 |
  |---|---|---|---|
  | **−0.094** | `gpim_q`→`m_im_flat` (M 켤레조립 허수, 3) | 25-bit `-(acc+gp)` **단일 carry chain**(7×CARRY4), logic 58% | carry chain 컬럼고정 → phys_opt 불가. carry-select(no-lat) 또는 negate-fold(OT 흡수) 또는 bisect(+1) — **B 재route 후 잔류 시** |
  | −0.088 | `grp_q·tile6_q`→`u_it/tre` (IT stage1, 3) | **route 68%**, monolithic tile6_q 1벌이 4 IT 산포 | ✅ **class B v2**: tile6_q 를 IT 별 576b 로 분할(FF 불변), grp_q_ic keep 복제 |
  | −0.037 | `gpab_im`→`gpim_q` (gather 허수, 1) | route 58% | 관망 (M 과 같은 reduce 영역) |
- **★ class B v2 적용** (`conv2_winograd_engine.v` gic generate): monolithic `tile6_q`(2304b)
  + `grp_q` 제거 → IT 별 `tile6_q_ic`(36×16b=576b, byte{ic,ic+4}만) + `grp_q_ic`(keep).
  per-bit fanout≈1 인데도 단일 블록이라 placer 가 3/4 IT 를 멀리 둔 게 원인 → 분할로 각
  partition 이 자기 u_it 근처 co-locate. **총 FF 2304 불변**, 값·timeline bit-exact.
- **검증**: full `tb_cnn_accelerator_winograd_multi` **100/100** (logit+readback, 1348 cyc/img 불변).
- **다음**: B 만 복붙(`conv2_winograd_engine.v` 1개) → 재route. M/D 는 reduce 영역이라
  B(입력측)와 다른 region — congestion 상속 불확실.
- **★ 시도·기각 기록 (M 처방, 2026-06-15)**:
  - **negate-fold 기각**: −sim 의 negate 가 −0.094 원인이라 봤으나 오판. `wino_m_assemble`
    은 덧셈기 0(순수 routing+negate), 7×CARRY4 는 **25-bit `-(acc+gp)` = `~a+~b+2` 단일
    add**(negate 가 입력반전으로 fused). 반례 = Path #5 `gpab_im→gpim_q`(negate 無 순수
    25-bit add)도 **−0.037 실패** → negate 떼도 −0.04 권, 불충분. 진짜 벽 = **25-bit
    carry chain + reduce congestion**.
  - **im carry-bisect(13+12, +1 latency) 시도→0/100 실패→복구**: engine reduce-tail 을
    re=m_assemble(+1 정렬)·im=2-stage bisect(stage1 low13+carry/high snapshot, stage2
    high12+assemble), tag 15→16, collector tg[16] 로 재작성. iverilog **0/100**
    (cyc 1348→1349 = +1 latency 는 적중, 값/정렬 어긋남 원인 미확정). 추측성 패치 대신
    **이번 턴 이전(검증된 class B 100/100)으로 전량 복구**. → bisect 재시도 시 **standalone
    `tb_conv2_winograd_engine_multi` 로 reduce-tail 단독 디버그**부터 (full-pipe 0/100 은
    원인 격리 불가). 또는 **B 재route 가 M/D 닫으면 불필요**.

## Iteration 13 — 5차 routed (class B): WNS −0.150 → **class B regression 확정·revert** (2026-06-16)
- **5차 route** (class B v2 적용본): WNS **−0.094 → −0.150**, failing **7 → 23 EP**, TNS −0.85 → **−1.044**.
  → **class B 는 닫은 게 아니라 악화** (3 지표 전부 후퇴).
- **23 EP 분류** (`docs/overclock/winograd/07_route_wns-0.150_classB-reverted/`):
  | slack | 클래스 (EP) | 성질 |
  |---|---|---|
  | **−0.150** | `grp_q_ic·tile6_q_ic`→`gic[*].u_it/tre` (IT stage1, 22) | **route 60~70%**, logic 5~6단(CARRY4 2+LUT) |
  | −0.021 | `tile_cnt`→`trow_cnt` (counter, 1) | route 83% |
- **원인**: per-IT 분할이 **배치를 갈아엎음** → ✅ reduce 영역(M −0.094/D −0.037) 닫힘(실패목록서 소멸)
  / ❌ 대신 **IT stage1(tre) 3 EP −0.088 → 22 EP −0.150** 노출(4 IT 전부). 순 WNS −0.056 악화.
- **★ 패턴 = congestion whack-a-mole**: reduce↔IT 두 route-bound(60~70%) 벽이 배치마다 교대 노출
  (~−0.1). 99% DSP + conv2 국소혼잡이 근본 → 점픽스는 벽을 옮길 뿐.
- **조치**: **class B revert** (monolithic `tile6_q` 복귀, bit-exact). iverilog full **100/100(1348)** 재확인.
  → 다시 −0.094(M 벽) 기점. 다음 전략(점픽스 IT 2+2 / 구조 floorplan·area / 171.4MHz fallback) **미정**.

## Iteration 14 — M·D carry-bisect (im) 성공 + ★이전 0/100 진짜 원인 발견 (2026-06-16)
- **결정**: M(logic 벽) = **carry-bisect**(사용자), B(net 벽) = floorplan-only(다음). reduce-tail 의
  25-bit `-(acc+gp)`(M −0.094) 을 **13+12 분할(+1 latency)**.
- **★안전 refactor 방법론** (이전 bisect 0/100 재발 방지): 원본 동결(`/tmp`) + **standalone TB 단독**
  검증 + **2단계 격리**:
  - **Step A** = 정렬만 +1 (msum register, bisect 산술 無) → standalone **100/100** → **정렬(+1·tag 16·
    collector tg[16]·m_valid issue+12) 정답 확정.** (이전 0/100 이 정렬인지 산술인지 분리.)
  - **Step B** = bisect 산술(상수 index) → standalone **0/100**(5483, **data-dependent**) → **full-±sim
    diag**(bisect 빼고 full 슬라이스)로 버그를 **carry 로 격리** → 정밀 원인 발견.
- **★ 진짜 버그 (이전 0/100 의 원인)**: **−sim low `~a+~b+2` 가 14-bit `lo_n` 에서 overflow.**
  `~a[12:0]+~b[12:0]+2` 의 max = **2¹⁴** (a,b low ≈ 0 일 때) → high 로의 carry 가 **2 까지** 가능한데
  `car_n` 1-bit 가 truncate. (+sim 은 max 2¹⁴−2 라 carry 0/1, 1-bit OK.) **수정 = `lo_n` 15-bit +
  `car_n` 2-bit.** 데이터 의존(특정 값)이라 ~55/img 만 틀렸던 것.
- **검증**: standalone `tb_conv2_winograd_engine_multi` **100/100** + full `tb_cnn_accelerator_winograd_multi`
  **100/100**(logit+readback). **1348→1349 cyc/img**(+1, throughput 불변).
- **정렬 변경(영구)**: m_valid issue+11→**+12**, tag 15→**16**, collector tg[15]→**tg[16]**.
  → arch §2.1·timing.md cycle 표 갱신 **완료**(+12/2oc+13/tile_out 2oc+19/1349/tail 36; README·design·memory 포함).
- **교훈**: **bisect 의 negate(`~a+~b+2`) low 는 carry 가 2 까지** → carry register 2-bit 필수.
  그리고 **standalone+2단계 격리**가 없었으면 또 "0/100 원인불명"이었다(이번엔 30분에 정밀 격리).
- **남음**: ① Vivado 재route → M 닫힘 확인 ② B floorplan. **→ Iter 15 에서 ①②  모두 기각(아래).**

---

## Iteration 15 — Vivado 결산: bisect 순손해 → floorplan 사망(밀도 벽) → **171.43MHz 확정** (2026-06-17~19)

**(a) bisect HW 첫 합성 = 순손해 → revert.** Iter 14 bisect 를 Vivado 합성: M(`m_im_flat`)은 **닫혔으나**(실패목록서 사라짐), +1 lat + 신규 레지(siml/simh/accH/gpH/car ×10)가 **unpinned 배치를 churn** → WNS **−0.342**(`gic.u_it/tre` B벽 99EP) + 신규 **−0.302**(`wm_we_q→wmem_op/WE` 가중치램 write, route 85%) + gpre/tile6. **Fmax 187 < baseline 196** = 순손해. → baseline 복원(`/tmp/ORIG` 526줄, bisect=`conv2_winograd_engine.bisect.bak` 572줄 보존), iverilog standalone+full **100/100, 1348 cyc/img** 재확인. (리포트 `docs/overclock/winograd/08_route_wns-0.342_bisect-churn/`.)

**(b) floorplan-only on baseline = 밀도 벽으로 사망.** geography(`new_new/`): conv2 가 칩 전폭(SLICE X0-89, Y12-199, **~49K 셀=칩 절반**) 산개. reduce(m_im_flat)조차 X13-81. `pb_reduce`(reduce 만 ~5.5K 셀) → CR 압축 3회 시도 전부 실패:
  - **1 CR(X1Y2)**: place 실패 — X1Y2 가 이미 DSP열+lane 으로 LUT 88% → reduce 추가 시 **slice 158% overflow**.
  - **3~4 CR(X1Y1:Y3)**: 여전히 실패 — **글로벌 util**(8 FF/slice, control-set 빽빽, `Place 30-4`).
  - **hard + skipUtilizationCheck + unplace**: place 는 됐으나 **WNS −1.116** (10× 악화!).
  - **★ 근본원인 (다신 floorplan 금지)**: reduce 는 **흩어진 DSP lane 4개(X0/X1/X2 열)에서 gather** 하는 노드 → `gpim_q` 가 ①흩어진 lane 입력 ②m_im 출력 **양쪽으로 찢김**. **−0.094 는 나쁜 배치가 아니라 placer 의 최적 타협점**. 한 곳에 모으면 입력쪽 route 폭발(−1.116). 즉 **gather→central-reduce dataflow + 76% LUT 밀도 = floorplan 압축 intrinsic 불가**. (사용자 통찰: *"분산돼야 할 걸 모으려 한 게 잘못."*)

**(c) 188MHz = clk_wiz SNAP (silent fail), CDC 는 무죄.** §3 "188 은 존재하지 않는다": clk_out1=100+clk_out2=200 이 VCO 고정 → 정수분주만. 과거 188 silent 버그 = §5 의 **요청≠실제**: 188 요청 → clk_wiz 가 **200 으로 silent snap** → 200 에서 reset 위반 → handshake 깨짐. **CDC 자체는 §2 무죄 확정**(dual-clock TB 10/10). 비정수 *비율* 은 안전, 함정은 **snap**. fractional(÷6.375=188.235)도 이 구성(clk_out3 정수분주 전용)에선 스냅 → 기각.

**(d) VCO −1 한계 = 1200 (DS181) → 171.43 이 천장.** MMCM_FVCOMAX: **−1=1200** / −2=1440 / −3=1600. 칩=`xc7a100t-csg324-1`. 기본 VCO=1000(→166.67) 을 **CLKFBOUT_MULT M=12 로 VCO=1200** 올리면 clk_out3=1200/7=**171.43**(200 아래 최대 정수분주). 177.8(VCO=1600)·190 은 −3 칩에서나.

**결정·현황**: **winograd @ 171.43MHz** (VCO=1200, **baseline RTL**, bisect out). conv2/conv1(accel 도메인) 5→5.833ns 라 **+0.7ns 로 닫힘**. impl 진행 중. ★silent-fail 방지 = impl 후 `report_clocks` 로 **clk_out3 period=5.833ns 실측 확인**(≠5.0 이면 snap=버림). 잔여 = 100MHz AXI `M_AXI_WDATA` −0.146(accel 무관, placement-marginal — 클린 배치면 양수 기대).

**교훈**: ① **floorplan 으로 conv2 압축 = intrinsic 불가**(gather dataflow + 밀도). ② 클럭은 **요청≠실제(snap)** 검증 필수. ③ −1 칩 200 아래 천장 = **171.43(VCO=1200)**. ④ bisect 는 churn 으로 순손해(200 닫혀도 −0.342, 무의미). ⑤ −0.094 는 placer 최적 = 더 못 줄임.

---

## §A. 정적 타이밍 카탈로그 (전 모듈 리뷰)

### A.1 per-cycle datapath stage 맵 (개요 — 절대 cycle·latency 정확값은 arch §2.1 / timing §2.1)
```
S0 FSM       compute_cnt/tile_cnt/trow_cnt/grp                                  (reg)
S1 rb_read   tile_cnt/trow_cnt → wino_row_buffers 분산 LUTRAM → tile6_q (reg, monolithic)
S2 IN-XFORM  d-mux(grp_q) → 4× wino_input_transform [★3-stage Bᵀd·tB] → a_q(★2a)
             → DSP B-port                                                       (+4 파이프)
S3..S5 DSP   AREG/BREG → MREG → PREG (wino_dsp_mul 3-stage)                     (reg)
S6 REDUCE    PREG → wino_lane_reduce → pre_q(★G-1) → gather 2+2 → gpre_q(★C-1)
             → grp0/grp1 누적 → wino_m_assemble → m_re/m_im_flat                (파이프)
S7..S10 OUT  m_*_flat → wino_output_transform [★4-stage] → trunc → tile_out (tag[15])  (reg)
S11 writer   tile_out → c2pool                                                  (reg)
```
issue→m_valid = **+11**, →tile_out = **+17** (baseline; carry-bisect 의 +12/+18 은 revert됨 = Iter 15).
inter-image overlap 으로 throughput 무손실 (1348 cyc/img).

### A.2 깊은 조합 블록 (근본 문제)
| 블록 | 원래 깊이 | slack | 처리 |
|---|---|---|---|
| 출력변환 Aᵀ·M·A | 20단 | 2-cyc | ✅ 2-stage 파이프 (A) |
| 입력변환 Bᵀ·d·B | 13단 | **tile당 32-cyc** | ✅ 2-stage 파이프 (B-1) |
| mul_array reduce chain | ~14단 | 2-cyc | ✅ 1 register (C-1) |
→ **셋 다 곱셈기 0 adder network 를 한 cycle 에 둔 것**. 생성기 clocked 화 + 엔진 register 로 분할.

### A.3 high-fanout net
| net | fanout | 처리 |
|---|---|---|
| tile_cnt/trow_cnt → rb read mux | 302 | max_fanout=40 |
| compute_cnt_l → per-PE RAMD32 read | 552/lane | 4-copy + max_fanout=64 |
| wm_* → per-PE RAMD32 write | 184/163/32 | max_fanout=24 (startup-only) |

### A.4 wide-bus (배치 분산 시 net delay)
| bus | 폭 | 비고 |
|---|---|---|
| a_flat | 2576b | 변환→184 DSP. 근본 활성 분배. lane-cluster 안 되면 net↑ |
| w_q | 2208b | per-PE local 화 완료 |
| tile6_q | 2304b | rb→8 transform |
| m_re/m_im_flat | 900b×2 | mul_array→출력변환 |
모든 실패경로 net 60~96% = **98% DSP 배치분산(congestion)** = 다음 벽.

### A.5 slack 원리 (파이프라인이 "무료")
throughput = issue rate(1 issue/cyc, FSM 고정) → **파이프 깊이↑ 해도 cyc/img 불변**(inter-image overlap).
→ B(입력변환, tile당 32-cyc 상수)·C(reduce, 2-cyc)·A(출력, 2-cyc) 파이프라인은 전부 latency-only.

---

## §B. 남은 벽 = high-fanout net (★ baseline 교훈으로 재구성)

★ `docs/overclock/direct/journey.md` 의 결정적 교훈: **이 칩(100T)의 datapath net 벽은
거의 전부 "die 전역 high-fanout 제어/리셋 net 의 route delay"이고, 해법은 floorplan 이 아니라
`max_fanout` driver 복제**다. baseline 은 **DSP 94%에서 floorplan 없이** 200MHz 를 닫았다
(state/kw_cnt/shift_en/reset max_fanout + phys_opt). → winograd 의 net 60%+ 도 "congestion
이라 floorplan 필요"가 아니라 **특정 high-fanout net 을 찾아 복제**하는 문제로 봐야 함.

### winograd high-fanout broadcast (baseline pe_en/shift_en/reset 동류)
| net | fanout | 상태 |
|---|---|---|
| **grp_q2** (grp-mux select) | **2576** (4 lane×46×VW) | ✅ max_fanout=32 (최대 broadcast) |
| **mul_en_q2** (DSP CE: 184×{CEA2,CEB2,CEM,CEP}) | **736** | ✅ max_fanout=32 (baseline pe_en 동류) |
| compute_cnt_l (per-PE read) | 552/lane | ✅ 4-copy + max_fanout=64 |
| tile_cnt/trow_cnt (rb read) | 302 | ✅ max_fanout=40 |
| wm_* (per-PE write) | 184 | ✅ max_fanout=24 (startup) |
| **rst** (datapath 전 reg) | 大 | rst_l1/rst_leaf 트리 상속(cnn_accelerator) — winograd reg 증가분 **다음 run 에서 watch**(baseline 의 −1.94 최대벽이었음) |

### 우선순위 (cheap → 비쌈)
- **B-1 max_fanout 복제** (위 표, grp_q2·mul_en_q2 신규 적용): net 벽의 1차 처방. cheap·iverilog-neutral.
- **B-2 `phys_opt_design -directive AggressiveExplore`**: baseline 의 마지막 한 끗(−0.098→+0.011).
  ★ **impl strategy 의 post-route phys_opt 에 넣을 것** — interactive 로 하면 impl 재실행 시 사라짐(재현성 함정).
- **B-3 reset 트리 보강** (reset 이 worst 로 뜨면): rst_leaf max_fanout↓ 또는 winograd-local leaf 추가. (winograd 의 순수 파이프 reg tre/tim·yre/yim·tile6_q·w_q_op 는 이미 reset-free → reset fanout 증가 억제됨.)
- **B-4 margin lever**: max_fanout 32→16→8 (baseline 도 16→8 언급).
- **B-5 (logic 더 필요시)**: 출력/입력변환 3-stage 심화 — throughput 무료.
- **B-6 (최후수단) floorplan pblock**: baseline 이 안 쓴 만큼 마지막. DSP 고정열이라 효과 불확실.

### 양파 까기 예상 (baseline 패턴)
worst 하나 닫으면 다음 노출. 매 run `report_design_analysis -timing` 워스트의 **logic% vs net%**
+ start/end + **High Fanout** 열을 보고: net 지배 + 특정 net 고fanout → 그 net max_fanout(cheap);
순수 분산이면 floorplan(최후). 대부분 전자였다(baseline).

상세 정적 분석 = `docs/winograd/conv2_winograd_timing_review.md`.

---

## §C. 진행 요약 (WNS @150MHz)
| Iter | 변경 | WNS | 비고 |
|---|---|---|---|
| 1 | A 폭축소 + weight BMG | (place fit) | route hang |
| 2 | per-PE LUTRAM + narrow loader + cc 4-copy | (hang→진행) | −10.276 |
| 3 | 출력변환 파이프 + B 재정렬 + max_fanout | **−6.337** | 5부류 탈출 |
| 4 | 입력변환 파이프(B-1) + reduce register(C-1) | PENDING | logic 벽 제거 |

★ 다음 = Vivado 재합성 → 새 WNS. net-bound 면 §B floorplan, logic 잔여면 §B-4.
