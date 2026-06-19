#import "../helpers.typ": *

= Implementation — Baseline (INT8 Direct) <sec-impl-base>

본 장은 @sec-impl-base 직전(§2)에서 내린 설계 결정을 RTL·블록 디자인·메모리 맵·FSM으로 *어떻게 실현했는지*에 집중한다. "왜 이 구조인가"는 반복하지 않고 §2의 해당 항목을 가리킨다. 구성은 공통 시스템 골격(@sec-common), 레이어별 엔진(@sec-engines), 그리고 오버클럭 이후(§5 위임) 순이다.

== 공통 시스템 골격 — 분산 데이터플로우 제어 <sec-common>

Baseline과 Winograd가 공유하는 골격이다. 설계 결정과 근거는 @sec-pipeline ~ @sec-multiclock 에 있다.

=== PS-PL 블록 구성

전체 시스템은 Vivado Block Design 상에서 PS 영역(MicroBlaze + local memory), AXI Interconnect, 메모리 접근용 AXI BRAM Controller, 이미지 feed용 AXI CDMA, 제어용 CSR(AXI-Lite slave), 클럭 생성용 Clocking Wizard, DRAM 접근용 MIG(DDR3), 그리고 가속기 본체 `cnn_accelerator`(PL)로 구성된다. 명세 제약대로 모든 신경망 연산은 PL에서 수행되고, PS는 메모리 read/write와 start/done 제어, 타이머 측정만 담당한다. MNIST 10,000장 테스트셋은 빌드 시 C 헤더 배열로 DRAM에 적재되며, MicroBlaze가 이를 읽어 AXI 경로로 PL의 입력 BRAM에 전달한다.

#figbox("figures/existing/abstract_system_block_diagram.png",
  [PS-PL 시스템 블록 다이어그램 (전체 결선은 첨부 PDF의 F2 참조)], w: 92%)

PL 본체 `cnn_accelerator`는 다음을 외부로 노출한다 — (1) PS가 write하는 4개 BMG(Input / Conv1 weight / Conv2 weight / FC weight)의 Port A, (2) PS가 read하는 결과 BMG(Output)의 Port B, (3) CSR와 주고받는 제어 신호 `enable`/`start`/`img_ready`(PS→PL)와 `img_done`/`input_consumed`(PL→PS)다. 이 중 stage 사이 ping-pong 버퍼(Input / C1C2 / C2Pool / PoolFC)와 결과 BMG는 본체가 직접 인스턴스화하고, 레이어별 weight BMG는 각 엔진 내부에 인스턴스화하여 Port A만 본체로 passthrough한다 — weight 결선을 엔진에 응집해 top-level 배선을 단순화한 것이다. FC weight는 512-bit폭이라 32-bit MicroBlaze가 write하려면 *32→512 datawidth converter*와 512-bit AXI BRAM Controller를 경유한다(@sec-bram).

`.coe`로 BMG를 초기화하는 것이 명세상 금지되므로 모든 weight·image는 PS가 C 헤더 배열에서 AXI를 통해 BRAM으로 전송한다. 멀티클럭은 @sec-multiclock 의 결정대로, PS·AXI·CSR는 100 MHz(`aclk`), datapath는 별도 클럭(`clk`)으로 분리하고 두 도메인 경계 신호를 CDC 동기화기로 건넌다. 클럭 분리·CDC의 구현과 동작은 오버클럭 로드맵의 전제이므로 상세는 @sec-optim 에 둔다.

=== 메모리 구조 — 비대칭 폭 BRAM과 ping-pong 버퍼 <sec-mem>

모든 데이터 이동은 Block Memory Generator(BMG) IP로 실현된다. 각 BMG는 *Simple Dual Port(SDP)* 구성으로 write 포트(Port A)와 read 포트(Port B)를 분리하며, stage 사이 버퍼는 2 bank ping-pong으로 둔다 — 한 engine이 한 bank에 다음 이미지를 쓰는 동안 다음 engine이 다른 bank에서 이전 이미지를 읽는다. bank 선택은 각 엔진 내부의 toggle FF가 관리하고, 물리 주소의 MSB로 prepend된다.

핵심은 *비대칭 폭(asymmetric width)* 설계다(근거는 @sec-bram). PS가 접근하는 두 끝단 BMG(Input, Output)는 Port A/B의 폭이 다르다.

- *Input BRAM* (`bram_input`): Port A = 32-bit × 512 word (PS가 AXI burst로 4 byte/cycle write), Port B = 8-bit × 2048 (Conv1이 픽셀 단위 byte read). 총 2 KB = 2 bank × 1024 byte. Vivado asymmetric BMG의 기본 *little-endian* 매핑에 따라 Port A의 word $k$ 가 byte $4k, 4k{+}1, 4k{+}2, 4k{+}3$ 를 담고, Port B의 주소 $4k{+}j$ read는 word $k$ 의 $j$ 번째 byte를 돌려준다. 한 장(28×28 = 784 byte)은 정확히 196 word로 나누어떨어져 padding이 필요 없다.
- *Output BRAM* (`bram_output`): Port A = 8-bit × 16384 (PL이 `img_done`마다 분류 결과 1 byte 누적 write), Port B = 32-bit × 4096 (PS가 종료 후 4 결과/word로 burst read). per-image read를 없애 파이프라이닝 중 결과 손실을 막는다.

#figure(
  grid(
    columns: 2, column-gutter: 8pt,
    image("../figures/existing/bram_input-portA.png", width: 100%),
    image("../figures/existing/bram_input-portB.png", width: 100%),
  ),
  caption: [`bram_input`의 비대칭 포트 구성 — (좌) Port A Width 32 / Depth 512 = PS의 AXI burst write 측, (우) Port B Width 8 / Depth 2048 = Conv1의 byte read 측. 같은 메모리를 PS는 32-bit word로, Conv1은 8-bit byte로 접근한다.],
)

stage 간 ping-pong 버퍼와 weight BMG의 구성을 표로 정리한다. (read latency $L$ 은 현재 구성값이며, $L{=}2$ 채택의 타이밍 근거는 @sec-optim 과 부록에 둔다.)

#figure(
  table(
    columns: 6, align: (left, center, center, center, center, left),
    table.header[BMG][Port A (write)][Port B (read)][Depth][$L$][write → read],
    [`bram_input`], [32b], [8b], [512 / 2048], [2], [PS → Conv1],
    [`bram_c1_to_c2`], [64b (byte-we)], [64b], [2048], [2], [Conv1 → Conv2],
    [`bram_c2_to_pool`], [128b], [128b], [2048], [2], [Conv2 → MaxPool],
    [`bram_pool_to_fc`], [128b], [128b], [512], [2], [MaxPool → FC],
    [`bram_output`], [8b], [32b], [16384 / 4096], [1], [PL → PS],
  ),
  caption: [데이터-패스 BMG (ping-pong + 입출력). Port 폭이 다른 `bram_input`·`bram_output`이 비대칭 구성이다.],
)

#figure(
  table(
    columns: 5, align: (left, center, center, center, left),
    table.header[weight BMG][폭][Depth(사용)][적재 시점][소비],
    [`conv1_weight_bram`], [32b], [64 (36)], [시스템 시작 1회], [Conv1 weight\_loader → 18 PE],
    [`conv2_weight_bram`], [32b], [1024 (576)], [시스템 시작 1회], [Conv2 weight\_loader → 192 PE],
    [`fc_weight_bram`], [512b], [1024 (720)], [시스템 시작 1회], [FC streaming read → 16 lane],
  ),
  caption: [레이어별 독립 weight BMG. Conv1·Conv2는 적재 후 PE 레지스터에 stationary 고정, FC는 spatial마다 streaming read한다. 1 word는 16ch × 32-bit SIMD-A(A = W1·2¹⁷ + W0).],
)

데이터-패스 BMG의 폭은 모두 "한 주소에 한 spatial 위치의 전 채널"을 담도록 잡혀, 엔진이 채널을 병렬로 한 번에 read한다 — C1C2 64-bit = 8 IC × 8b, C2Pool·PoolFC 128-bit = 16 ch × 8b. 이미지 한 장의 데이터 이동 경로는 다음과 같다: PS → Input BRAM → Conv1 → C1C2 → Conv2 → C2Pool → MaxPool → PoolFC → FC → Output BRAM → PS.

#figbox("figures/diagrams/F4_dataflow.svg",
  [단일 이미지 데이터 이동 경로 (feature-map shape 포함)], w: 95%)

=== Sliding-window 생성 — line buffer / window register 구현 <sec-window>

두 컨볼루션 엔진은 @sec-pipeline 의 line-buffer 스트리밍 원리를 동일한 두 공용 모듈로 구현한다 — `line_buffer`(`RTL/core/line_buffer.v`)와 `window_register`(`RTL/core/window_register.v`).

`line_buffer`는 깊이 `DEPTH`의 순환 버퍼다. `en=1`인 매 사이클에 현재 포인터 위치를 등록 출력으로 읽고(`dout <= mem[ptr]`) 같은 자리에 새 입력을 덮어쓴 뒤(`mem[ptr] <= din`) 포인터를 순환시킨다. 따라서 한 줄(row)을 통째로 지연시키는 FIFO처럼 동작하며, 등록 출력 1사이클을 합쳐 실효 지연이 `DEPTH+1` 사이클이 된다. Conv1은 28픽셀 행이라 `DEPTH=27`(→ 28사이클 = 1행), Conv2는 26픽셀 행이라 `DEPTH=25`(→ 26사이클)로 인스턴스화한다.

```verilog
// 코드 발췌 — line_buffer.v: 순환 버퍼 1행 지연 (등록 출력)
always @(posedge clk) begin
    if (rst) begin ptr <= 0; dout <= 0; /* mem 클리어 */ end
    else if (en) begin
        dout     <= mem[ptr];                          // 현재 위치 읽기(1사이클 지연)
        mem[ptr] <= din;                               // 새 데이터 쓰기
        ptr      <= (ptr == DEPTH-1) ? 0 : ptr + 1;    // 순환
    end
end
```

`line_buffer` 2개를 직렬로 두면(BRAM → lb1 → lb2) 세 개의 *연속한 행*이 동시에 가용해진다. `window_register`는 이 세 행을 받아 각 행마다 3-cell 좌측 시프트 레지스터(`win_r2`=최신 행, `win_r1`=lb1, `win_r0`=lb2)를 굴려, 매 `en` 사이클에 3×3 윈도우 한 개(9탭 `k0`~`k8`)를 완성한다. 즉 BRAM에서 한 클럭에 한 픽셀씩 raster-scan으로 흘려보내면, fill 이후 매 사이클 새 윈도우 하나가 나온다. Conv1은 IC가 1개라 이 체인을 1세트, Conv2는 IC가 8개라 8세트(line\_buffer 16개 + window\_register 8개)를 병렬로 둔다. Conv1은 출력 채널 round를 바꿀 때(@sec-eng-conv1) `lb_rst`로 line buffer와 window를 클리어해 이전 round의 잔류 데이터가 다음 round 윈도우를 오염시키지 않게 한다.

=== 데이터플로우와 분산 FSM 제어 <sec-fsm-impl>

데이터플로우는 *Weight Stationary + Output Stationary, Activation Flowing* 으로 실현된다. 각 PE는 weight를 자기 레지스터에 적재해 추론 동안 고정하고(weight stationary), 부분합(psum)을 누적기에 모으며(output stationary), activation만 BRAM → line buffer → window register → PE로 매 사이클 흐른다(activation flowing).

@sec-pipeline 의 결정대로 stage 사이를 ping-pong BRAM 버퍼로 분리하여, 한 engine이 다음 이미지를 쓰는 동안 다음 engine이 이전 이미지를 읽는다. 중앙 컨트롤러는 없으며, 각 engine이 자체 FSM과 bank-toggle FF를 가지고 stage 간 `write_done`/`read_done`(각 1-cycle pulse) 핸드셰이크로만 동기한다.

핸드셰이크는 두 방향의 *signed 3-bit 차이 카운터*로 구현된다. 입력 측은 `prior_diff = (자신의 read 완료 수) − (이전 stage의 write 완료 수)`로, `prior_diff < 0`이면 처리할 이미지가 이전 버퍼에 남아있음을 뜻한다(`data_ready`). 출력 측은 `after_diff = (자신의 write 완료 수) − (다음 stage의 read 완료 수)`로, `after_diff < 2`면 출력 bank에 여유가 있음을 뜻한다(`output_avail`). 두 조건이 모두 참일 때만 다음 이미지 처리를 시작하므로, 어느 stage가 빠르거나 느려도 카운터 자체가 backpressure를 만든다. 카운터는 register이지만 진입 판단은 *next-value를 조합 논리로* 평가하여, 같은 사이클의 pulse가 NBA 1사이클 지연으로 누락되는 race를 막는다(상세는 `docs/handshake_counter_nba_race.md`).

#figbox("figures/diagrams/F3_handshake_pingpong.svg",
  [stage 간 ping-pong 버퍼 + 분산 FSM 핸드셰이크 (중앙 컨트롤러 없음)], w: 85%)

== 오버클럭 이전 — Baseline 레이어 엔진 <sec-engines>

각 레이어 엔진은 "FSM(제어) + 공용/전용 datapath 하위 모듈"로 구성된다. 먼저 모든 엔진이 공유하는 연산 primitive를 보이고, 이어 엔진별로 하위 모듈 구성·역할과 정확한 FSM 상태·전이를 제시한다.

=== 공유 연산 primitive — PE cell과 truncate/ReLU <sec-prim>

*PE cell* (`pe_cell.v`). 모든 컨볼루션·FC가 공유하는 MAC 단위다. DSP48E1 한 개와 parameterized weight 레지스터로 구성되며, A 포트(25-bit)에 packed weight, B 포트(18-bit)에 activation을 싣고 48-bit P에서 두 곱 `mul0 = W0·X`, `mul1 = W1·X`를 분리 추출한다(@sec-packing). 파라미터 `DEPTH`로 weight 슬롯 수를 정해 레이어별로 재사용한다 — Conv1은 `DEPTH=2`(OC round mux), Conv2는 `DEPTH=3`(K_col time-mux), FC는 `STREAM=1`(weight 레지스터 우회, A 포트 직결). DSP 내부 3단(A/B → M → P) + 모듈 출력 레지스터 1단 = 4-cycle latency다.

```verilog
// 코드 발췌 C1 — pe_cell.v: 48-bit P에서 두 곱 분리 + carry 보정 (-128 없음 가정)
wire signed [16:0] p0_raw     = P[16:0];                  // W0·X
wire signed [16:0] p1_slot    = {{1{P[32]}}, P[32:17]};  // W1·X 슬롯
wire signed [16:0] carry_corr = {16'd0, p0_raw[16]};     // [P0<0] carry 보정
wire signed [16:0] p1_raw     = p1_slot + carry_corr;
```

*Truncate/ReLU* (`truncate_relu.v`). 모든 레이어 출력 직후의 양자화 단이다. 24-bit signed 누적값을 `>>>10`(산술 우측 시프트)한 뒤 $[-128, 127]$로 saturation하고 ReLU를 적용해 8-bit로 출력한다. 음수 분기에서 ReLU와 음수 saturation이 함께 처리된다. 동시 출력 채널 수 `N`은 Conv1에서 4, Conv2에서 16이다. (양자화 규칙의 명세 정합은 @sec-quant-hw.)

```verilog
// 코드 발췌 C2 — truncate_relu.v: >>>10 → saturate(±127) → ReLU (음수 분기 통합)
function signed [7:0] sat_relu;
    input signed [13:0] val;          // 24-bit 누적을 >>>10 한 14-bit
    begin
        if      (val > 14'sd127) sat_relu = 8'sd127;   // 양수 saturation
        else if (val < 14'sd0)   sat_relu = 8'sd0;     // ReLU + 음수 saturation
        else                     sat_relu = val[7:0];  // 0~127 그대로
    end
endfunction
```

=== Conv1 엔진 <sec-eng-conv1>

입력 (1, 28, 28) → 출력 (8, 26, 26). @sec-conv2-alloc 의 분배대로 *18 DSP* $= "K"9 times "OCpair"2 times "SIMD"2$ 를 쓴다. 9탭 윈도우를 9 PE로 한 번에 곱하고, SIMD packing으로 한 PE가 두 출력 채널을 내므로 한 round에 4 OC가 나온다. 출력 8채널은 PE를 복제하지 않고 2-round(round0 = OC0–3, round1 = OC4–7)로 나눠 처리하며, round 사이에 line buffer·window를 리셋한다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[하위 모듈][인스턴스][역할],
    [`conv1_fsm`], [1], [8-상태 제어 FSM. raster-scan 카운터·flush·round 전환·핸드셰이크·출력 주소 지연],
    [`conv1_weight_bram`], [1], [Conv1 SIMD weight BMG (엔진 내부, Port A passthrough)],
    [`conv1_weight_loader`], [1], [시작 1회 weight를 read해 18 PE에 1-hot 분배],
    [`line_buffer`], [2], [3행 윈도우 생성 (`DEPTH=27`)],
    [`window_register`], [1], [3×3 윈도우 9탭 생성],
    [`pe_cell`], [18], [9 PE × 2 group(`DEPTH=2`). round당 4 OC MAC],
    [`conv1_adder_tree`], [2], [9탭 곱 → 24-bit 누적 (9:2 토폴로지, 4-stage)],
    [`truncate_relu`], [1], [`N=4`, 4채널 동시 양자화],
  ),
  caption: [Conv1 엔진 하위 모듈 구성.],
)

데이터패스는 `bram_input` byte read → line buffer ×2 + window → 18 PE → `conv1_adder_tree` ×2 → `truncate_relu` 순이며, 출력 4채널은 `c1c2_din`의 byte 위치에 실려 같은 주소에 round별 byte-write로 병합된다. FSM은 8상태이며 전이는 다음과 같다.

#figure(
  table(
    columns: 3, align: (left, left, left),
    table.header[상태][동작][다음 상태 (조건)],
    [`IDLE`], [대기 (`pipe_en=0`)], [`LOAD` (`data_ready` & `output_avail`)],
    [`LOAD`], [weight 적재 대기], [`RUN1` (`load_done`)],
    [`RUN1`], [`sel=0`, 28×28 스캔 (OC0–3)], [`FLUSH1` (`scan_done`)],
    [`FLUSH1`], [파이프라인 drain], [`LBRST` (`flush_cnt` 만료)],
    [`LBRST`], [line buffer·window 리셋, `sel=1`], [`RUN2` (무조건)],
    [`RUN2`], [`sel=1`, 28×28 재스캔 (OC4–7), 끝에 `rdone`], [`FLUSH2` (`scan_done`)],
    [`FLUSH2`], [파이프라인 drain], [`DONE` (`flush_cnt` 만료)],
    [`DONE`], [`wdone` pulse], [`IDLE`],
  ),
  caption: [Conv1 FSM 상태 전이. `RUN1`/`RUN2`가 두 OC round, `FLUSH`가 파이프라인 drain, `LBRST`가 round 전환 클리어다.],
)

#placeholder([Conv1 FSM 상태 전이도], h: 4.5cm)

=== Conv2 엔진 <sec-eng-conv2>

입력 (8, 26, 26) → 출력 (16, 24, 24). @sec-conv2-alloc 의 분배대로 *192 DSP* $= "OCpair"8 times "IC"8 times "Krow"3$ 를 쓴다. 즉 커널 행(K_row 3)은 공간적으로 펼치고, 커널 열(K_col 3)은 3사이클에 걸쳐 시분할 누적한다. 8 IC를 한 번에 병렬 처리한다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[하위 모듈][인스턴스][역할],
    [`conv2_fsm`], [1], [8-상태 제어 FSM. read 좌표·K_col phase·row wrap·drain·핸드셰이크],
    [`conv2_weight_bram`], [1], [Conv2 SIMD weight BMG (엔진 내부)],
    [`weight_loader_conv2`], [1], [시작 1회 576 weight를 read해 192 PE에 ID 디코딩 분배],
    [`line_buffer`], [16], [IC당 2개(`DEPTH=25`) — 8 IC 병렬],
    [`window_register`], [8], [IC당 1개, 3×3 윈도우],
    [`pe_cell`], [192], [`DEPTH=3`(K_col 슬롯). `pe_id = (OC_pair·8 + IC)·3 + K_row`],
    [`krow_ic_adder_tree`], [16], [K_row3 × IC8 = 24입력을 22-bit로 합산 (5-stage)],
    [`kcol_accumulator`], [16], [K_col 3개를 3사이클에 24-bit로 누적, 마지막에 `out_valid`],
    [`truncate_relu`], [1], [`N=16`, 16 OC 동시 양자화],
  ),
  caption: [Conv2 엔진 하위 모듈 구성. 누적 경로가 `krow_ic_adder_tree`(행·IC 합) → `kcol_accumulator`(열 누적)로 2단이다.],
)

한 출력 픽셀은 K_col 위상 3개(HOLD/HOLD/ADVANCE)에 걸쳐 완성된다 — `COMPUTE_HOLD`에서 윈도우를 멈춘 채 K_col 0·1을, `COMPUTE_ADVANCE`에서 윈도우를 한 열 진행시키며 K_col 2를 처리하고, 이때 `kcol_accumulator`가 세 위상의 부분합을 합쳐 한 픽셀을 낸다. 출력 행이 바뀌는 경계에서는 `COMPUTE_WRAP`(3사이클)이 PE를 멈추지 않고 윈도우만 진행시켜 다음 행 첫 픽셀을 준비한다. 마지막 출력 픽셀 뒤에는 `DRAIN`이 PE→adder→누적기→BRAM write 파이프라인을 비운다.

#figure(
  table(
    columns: 3, align: (left, left, left),
    table.header[상태][동작][다음 상태 (조건)],
    [`IDLE`], [start 대기], [`LOAD_WEIGHTS` (`start`)],
    [`LOAD_WEIGHTS`], [576 weight 적재 (1회)], [`DONE` (`loader_done`)],
    [`DONE`], [다음 이미지 대기], [`PIPELINE_FILL` (`data_ready` & `output_avail`)],
    [`PIPELINE_FILL`], [line buffer·window 초기 채움], [`COMPUTE_HOLD` (`row,col`=(2,4))],
    [`COMPUTE_HOLD`], [윈도우 정지, K_col 0/1], [`COMPUTE_ADVANCE` (`kw_cnt`=1)],
    [`COMPUTE_ADVANCE`], [윈도우 1열 진행, K_col 2], [`DRAIN`(마지막 픽셀) / `COMPUTE_WRAP`(행 경계) / `COMPUTE_HOLD`],
    [`COMPUTE_WRAP`], [행 전환, 윈도우만 진행 (3사이클)], [`COMPUTE_HOLD` (`wrap_cnt`=2)],
    [`DRAIN`], [파이프라인 drain], [`DONE` (`drain_cnt` 만료)],
  ),
  caption: [Conv2 FSM 상태 전이. `HOLD`/`HOLD`/`ADVANCE`가 한 픽셀의 K_col 3위상, `WRAP`이 출력 행 경계 처리, `DRAIN`이 파이프라인 비움이다.],
)

#placeholder([Conv2 FSM 상태 전이도 (K_col 위상·WRAP·DRAIN 포함)], h: 5cm)

=== MaxPool 엔진

입력 (16, 24, 24) → 출력 (16, 12, 12). 2×2 stride-2 최댓값 풀링을 16채널에 대해 동시에 수행한다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[하위 모듈][인스턴스][역할],
    [`maxpool_fsm`], [1], [4-상태 제어 FSM. 7-phase로 2×2 윈도우 4픽셀 read·캡처·출력 주소 생성],
    [`max_compare_tree`], [1], [16채널 각각 4-way 최댓값을 2-stage 비교로 계산],
  ),
  caption: [MaxPool 엔진 하위 모듈 구성.],
)

FSM은 `IDLE → RUN → FLUSH → DONE`의 4상태다. `RUN`은 내부 7-phase(0–6)로, 2×2 윈도우의 네 픽셀 주소를 차례로 발행하고 BMG read latency를 고려해 도착분을 `p00`/`p01`/`p10`/`p11`로 캡처한 뒤 비교를 시작한다. `max_compare_tree`는 1단에서 `(p00,p01)`·`(p10,p11)`의 행별 최댓값을, 2단에서 그 둘의 최댓값을 구해 채널당 4-way max를 2사이클에 낸다. 144개 출력 픽셀을 모두 내면 `FLUSH`로 파이프라인을 비우고 `DONE`에서 `rdone`/`wdone`을 pulse한다.

=== FC 엔진 <sec-eng-fc>

입력 2,304(= 16 ch × 144 spatial) → 출력 10 클래스. SIMD packing을 출력 클래스 방향으로 적용해, 한 PE lane이 같은 activation에 대해 두 클래스(even/odd) 기여를 동시에 낸다. 따라서 10 클래스를 5 pair로 묶어 순차 처리한다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[하위 모듈][인스턴스][역할],
    [`fc_fsm`], [1], [4-상태 제어 FSM. 5 pair × 144 spatial 스캔, 핸드셰이크],
    [`fc_weight_bram`], [1], [FC SIMD-A weight BMG (512b, 엔진 내부)],
    [`fc_pe_array`], [1], [16 lane (`pe_cell` `STREAM=1`). lane당 `p0=W0·X`(even), `p1=W1·X`(odd)],
    [`fc_adder_tree`], [1], [16 lane 곱을 even/odd 각각 20-bit로 합산],
    [`fc_accumulator`], [1], [pair별 144 spatial 부분합을 logit으로 누적],
    [`fc_argmax`], [1], [10 logit의 최댓값 인덱스 (4-round 토너먼트)],
  ),
  caption: [FC 엔진 하위 모듈 구성. weight를 레지스터에 적재하지 않고 BMG에서 streaming read해 lane에 직결한다 (spatial마다 weight가 바뀌어 stationary 불가).],
)

weight는 한 word(512-bit)가 16채널 × 32-bit SIMD-A이며, 각 lane이 `[ch*32 +: 25]`를 `pe_cell`의 packed weight로 직결받는다. `fc_pe_array`의 even/odd 출력은 각각 짝수·홀수 클래스 기여이고, `fc_adder_tree`가 16채널을 합쳐 한 pair의 even/odd 부분합을, `fc_accumulator`가 144 spatial을 합쳐 두 클래스 logit을 만든다. 5 pair를 모두 돌면 10 logit이 모이고, `fc_argmax`가 최댓값 인덱스를 낸다 — 1-cycle combinational 10-way 비교는 타이밍 위반이므로 10→5→3→2→1의 4-round 토너먼트로 분해해 각 round를 레지스터로 끊었고, strict `>` 비교로 동률 시 낮은 인덱스를 유지한다.

#figure(
  table(
    columns: 3, align: (left, left, left),
    table.header[상태][동작][다음 상태 (조건)],
    [`IDLE`], [다음 이미지 대기], [`COMPUTE` (`data_ready` 또는 `start_pulse`)],
    [`COMPUTE`], [5 pair × 144 spatial 스캔 (`s_first`/`s_last` strobe)], [`DRAIN` (pair4의 `s_cnt`=143)],
    [`DRAIN`], [파이프라인 drain], [`DONE` (`drain_cnt` 만료)],
    [`DONE`], [`rdone` pulse], [`IDLE`],
  ),
  caption: [FC FSM 상태 전이. `COMPUTE`가 pair·spatial 이중 스캔, `DRAIN`이 누적기까지의 파이프라인 비움이다. FC는 terminal layer라 출력 측 핸드셰이크가 없다.],
)

#placeholder([FC FSM 상태 전이도 (pair·spatial 스캔 + argmax)], h: 4.5cm)

=== PS-PL 인터페이스 (CSR와 main.c)

CSR는 AXI-Lite slave(`csr_axi.v`)로, PL과의 인터페이스 신호로 `enable`/`start`/`img_ready`(PS→PL)와 `img_done`/`input_consumed`(PL→PS)를 노출한다. 타이머는 명세 정의대로 "첫 weight write부터 마지막 output read까지"를 PL에서 카운트하여 PS가 읽을 수 있게 노출한다. (레지스터 주소 맵·비트 필드 표 T2는 `csr_axi_slave_lite_v1_0_csr.v`와 대조해 부록에서 확정.)

PS 측 펌웨어(`main.c`)의 흐름은 다음과 같다: weight를 한 번 전송한 뒤 타이머를 시작하고, 10,000장 루프에서 다음 이미지를 반대 bank에 preload하면서 `img_ready`를 주고 `done`을 polling한다. 입력 bank 여유(`input_consumed` 기반 backpressure)를 확인하며 진행하고, 모든 이미지가 끝나면 결과를 Output BRAM에서 일괄 read하고 타이머를 멈춰 총 latency를 보고한다. 데이터는 `.npy`를 C 헤더로 변환해 빌드 시 DRAM에 올리며, 명세 권고대로 UART 전송은 측정 경로에서 배제한다. (코드 발췌 C6은 부록.)

=== 양자화 메커니즘의 HW 구현 <sec-quant-hw>

양자화는 @sec-quant 의 명세 규칙(`>>10` → saturate(±127) → ReLU)을 24-bit 누적 → 산술 시프트 → saturation 경로로 비트-정확하게 재현한다(`truncate_relu`, @sec-prim 의 코드 C2). 이는 단순 비트-절단이 아니라 명세 규칙의 정확한 모사이며, 본 과제는 이미 INT8로 양자화된 파라미터의 추론을 정확히 재현하는 문제이지 scale-factor 선형 양자화나 재학습이 아니다(@sec-quant). INT8 정밀도에 맞춘 하드웨어 구성은 SIMD-2 packing PE(@sec-packing), 24-bit accumulator, truncate/round 로직, 비대칭 BRAM 포트·대역폭(@sec-mem)이다.

== 오버클럭 이후

Baseline의 200 MHz timing closure에 적용한 RTL·제약·구조 변경(reset 분배 트리, high-fanout 제어 net 복제, BMG read latency 정렬 등)은 무엇·결과(WNS)·왜를 한 흐름으로 다루기 위해 @sec-optim 에 모았다. 본 장은 오버클럭 이전의 기능 RTL에 집중한다. 다만 오버클럭 관련 모든 변경은 기능을 바꾸지 않으며(시뮬레이션에서 bit-exact 재검증), "오버클럭 이전/이후" 구분은 정확성과 무관하다.
