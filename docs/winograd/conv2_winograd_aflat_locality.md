# conv2 Winograd — activation(`a_flat`) lane-locality 설계 (route congestion / WNS 레버 2)

> 상태: **설계만** (RTL 미적용). weight per-PE LUTRAM 화(레버 1) 후에도 남은
> congestion·WNS 의 주범 = 활성 `a_flat`(2576-bit) → 184 DSP. 이를 lane-local 로.

## 0. 배경 (왜 이게 다음 레버인가)
레버 1(weight per-PE distributed RAM + narrow loader + compute_cnt 4-copy) 적용 후 Vivado:
- place 성공: LUT 84% / LUTRAM 16% / FF 42% / BRAM 42% (BRAM 65→42, weight 버스 발원지 제거 확인).
- route: 예전 무한 hang → **phase 넘어가며 진행**(weight 가 주범 하나였음 확인). overlaps 83242→1437 수렴.
- **그러나 `Route 35-447`(congestion, timing 포기 모드) + 중간 WNS = −10.276 ns / TNS −185083 ns.**
  → 5ns(200MHz)에서 경로 ~15ns. **route 가 끝나도 못 쓰는 비트스트림.** 한 경로가 아니라 수천
    endpoint(TNS 거대) → congestion detour 가 다수 경로를 망친 것 = `a_flat` 광폭 버스의 흔적.

## 1. 현재 활성 경로 구조 (as-is)
```
wino_row_buffers → tile6 (6×6 × 64b = 2304b, 36-way comb read)
  → 8× wino_input_transform (per IC, d 288b → a_ic[ic] 644b)      [conv2_winograd_engine.v:161-171]
  → grp-mux: a_flat[lane] = grp ? a_ic[lane+4] : a_ic[lane]  (4 lane)  [:172-177]
  → a_flat_q (단일 2576-bit register)                                 [:263-267]
  → wino_mul_array (a_flat 2576b 단일 입력)                           [:272-274]
```
`wino_mul_array` 내부는 **이미 lane별**: `generate for L=0..3 { 46 DSP each, a=a_flat[(L*46+i)] }`
+ lane_reduce → cross-lane 합 → accumulator. (`wino_mul_array.v:52-72`)

### 병목
- **단일 `a_flat_q`(2576b)가 184 DSP 로 fan-out** → DSP 가 die 에 흩어지면 2576 net 이 die 횡단 → track oversubscribe(weight 와 동일 병). critical path = `a_flat_q → DSP B-port`.
- 추가로 `a_flat_q` **입력측** 경로: `tile6 comb read → transform(2-stage adder) → grp-mux` 가 한 cycle 조합 → logic depth 도 길 수 있음(아래 §4).

## 2. 설계 — 레버 2a: per-lane 활성 register (primary, 저위험)
weight per-PE 와 동형. **mul array 가 이미 lane 구조**라 `a_flat_q` 만 lane별로 쪼개면 됨.

단일 `a_flat_q` → **4개 lane register**(`keep`)로 분할 + grp-mux 를 각 lane register 입력에 fold:
```verilog
// conv2_winograd_engine.v  (a_flat_q 블록 교체)
//   각 lane register 가 자기 2개 IC(transform[L], [L+4])에만 의존 → placer 가
//   {transform[L],[L+4] + grp-mux + register + 46 DSP + lane_reduce} 를 lane 클러스터로 묶음.
(* keep = "true" *) reg [46*VW-1:0] a_flat_q_l [0:3];
integer la;
always @(posedge clk) begin
    if (rst) for (la=0; la<4; la=la+1) a_flat_q_l[la] <= {46*VW{1'b0}};
    else     for (la=0; la<4; la=la+1)
        a_flat_q_l[la] <= mul_grp ? a_ic[4+la] : a_ic[la];   // grp-mux fold
end
// mul array 입력은 4개 register concat (netlist 상 4개 distinct → 각자 자기 lane DSP 로만)
wire [4*46*VW-1:0] a_flat_q = {a_flat_q_l[3], a_flat_q_l[2], a_flat_q_l[1], a_flat_q_l[0]};
```
- **`wino_mul_array` 무변경** (a_flat 슬라이싱 그대로 = lane L 이 a_flat_q_l[L] 소비).
- 단일 fanout-184 → **4 × fanout-46 lane-local**. weight(compute_cnt_l)와 같은 클러스터링.
- **bit-exact 불변**: register 값 동일, 분할만. iverilog 재검증 형식적(동일값) — 그래도 40/40 재확인.
- 주의: 기존 `a_flat`(comb wire, :172) 과 `a_flat_q`(:263) 제거/치환. `mul_grp`(=issue grp)
  타이밍은 기존 a_flat_q 와 동일 stage 유지(현 `mul_grp` 가 곧 a_flat 의 grp 와 같은 cycle).
  → 현 코드의 grp-mux 가 `grp`(comb) 였으므로, register 입력에서 `mul_grp`(=현 grp) 사용해
    동일 cycle 정렬 보존. (구현 시 grp 정렬 1줄 확인.)

## 3. 레버 2b: transform 까지 lane 블록화 (2a 로 부족할 때만)
2a 는 connectivity 로 placer 를 유도하지만, 더 강제하려면 transform 을 mul array lane generate
안으로 이동:
- lane 블록 L = { `wino_input_transform`(IC L) + (IC L+4) + grp-mux + register + 46 DSP + lane_reduce }.
- lane 으로 들어오는 신호 = row buffer d(IC L, L+4) 576b 뿐(644b 출력은 lane 내부 유지).
- 비용: mul array 포트가 a_flat(2576b) → tile6 d(또는 a_ic 8개) 로 바뀜. 재검증 필요.
- **netlist connectivity 는 2a 와 동일** → 보통 2a + (필요시)pblock 으로 충분. 2b 는 최후수단.

## 4. 레버 3: transform 파이프라인 (WNS 가 logic-depth-bound 일 때)
중간 WNS −10ns 는 **congestion(net delay)** 이 큰 몫이지만, `a_flat_q` 입력측
`tile6 read → Bᵀd → ·B → grp-mux` 가 **한 cycle 조합**이라 logic depth 도 의심.
- **진단 먼저** (이번 route 끝/중단 후, design open 상태):
  ```tcl
  report_timing -setup -max_paths 10 -slack_lesser_than 0 -input_pins -nets
  ```
  실패 경로가 **NET delay 지배** → congestion → 레버 2a/2b 로 충분.
  **LOGIC(cell) delay 지배** → 레버 3 필요.
- 레버 3 = transform 2-stage 사이에 register 삽입(t=Bᵀd latch):
  `tile6→Bᵀd→[reg]→·B→grp-mux→a_flat_q`. **+1 cycle latency** →
  tag pipeline(현 +5)·`mul_en` DRAIN window·producer/collector 정렬 +1 재조정(기계적, 재검증 필수).
- 참고: baseline direct conv2(adder tree 다수)는 200MHz 닫았으므로 transform adder depth 자체는
  치명적이지 않을 가능성 높음 → **레버 3 는 진단 후 결정**.

## 5. 적용 순서 (Vivado run 아끼기)
1. **레버 2a** 적용(저위험, iverilog 40/40 재확인) → route.
2. route 통과 + WNS 진단:
   - WNS ≥ 0 → 끝.
   - WNS < 0, NET-bound → 레버 2b 또는 pblock(4 lane region) 추가.
   - WNS < 0, LOGIC-bound → 레버 3(transform pipeline).
3. 보조: `phys_opt_design -directive AggressiveExplore` (예전 200MHz WNS +0.011 닫은 레버).

## 6. 불변 원칙
- 원본 conv2/conv1 무변경, drop-in 유지. winograd_u.hex/BMG/BD/firmware 무변경.
- 모든 레버는 **bit-exact 보존**(register 분할·재배치·파이프라인 latency 조정뿐, 데이터 경로 값 불변).
- 검증 = iverilog standalone(40/40, cyc/img) + full pipeline(40/40 logit+readback). 레버 3 는 cyc/img +1 예상.
