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
- **상태**: winograd conv2 engine iverilog bit-exact (40/40, **1337 cyc/img**, conv2 direct 1798 대비 1.35×). DSP 184(=4 lane×46). drop-in (conv2 자리, c1c2/c2pool/handshake 동일).
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

## §A. 정적 타이밍 카탈로그 (전 모듈 리뷰)

### A.1 per-cycle datapath stage 맵 (현재)
```
S0 FSM       compute_cnt/tile_cnt/trow_cnt/grp                                  (reg)
S1 rb_read   tile_cnt/trow_cnt → wino_row_buffers 36-way mux → tile6_q          (reg)
S2 IN-XFORM  tile6_q → 8× wino_input_transform [stage1 Bᵀd→reg→stage2 tB] → grp-mux(grp_q2)
             → a_flat → DSP B-port                                              (B-1 파이프)
S3..S5 DSP   AREG/BREG → MREG → PREG (wino_dsp_mul 3-stage)                     (reg)
S6 REDUCE    PREG → wino_lane_reduce → cross-lane → gpre_q(reg, C-1) → msum
             → wino_m_assemble → m_re/m_im_flat                                 (C-1 파이프)
S7..S8 OUT-X m_*_flat → wino_output_transform [y=AᵀM→reg→Y16=yA→reg]            (A 파이프)
S9 trunc     y16 → wino_truncate(>>14+sat) → trunc_out                         (reg)
S10 collect  trunc_out → tile_out[bank][pix][oc]   (tag[9] 정렬)               (reg)
S11 writer   tile_out → c2pool                                                  (reg)
```
issue→M latency = +7, →collector = +10 (모두 inter-image overlap 으로 throughput 무손실).

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

★ `docs/overclock_journey_100_to_200mhz.md` 의 결정적 교훈: **이 칩(100T)의 datapath net 벽은
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
