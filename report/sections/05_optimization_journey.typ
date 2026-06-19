#import "../helpers.typ": *

= Optimization Journey — Timing Closure <sec-optim>

기능 완성된 설계를 200 MHz로 닫는 timing closure를 Baseline(@sec-optim-base, 완결)과
Winograd(@sec-optim-wino, 171.42 MHz met) 두 트랙으로 기술한다. 모든 RTL·제약 변경은
시뮬레이션 bit-exact 재검증으로 기능 불변을 확인했다.

== Baseline Track — 100 → 200 MHz (MET +0.011 ns) <sec-optim-base>

이 설계의 타이밍 벽은 거의 전부 die 전역으로 퍼지는 high-fanout 제어·리셋 net의 route
delay였으며, 로직 깊이 문제가 아니었다(워스트 경로의 route 비중이 82\~86%). 아래는 시간
순서로 본 closure 과정이다.

=== 왜 오버클럭인가 — compute-bound 판별

가속기의 throughput floor는 conv2 사이클(약 1,799 cyc/img)이 지배한다. 같은 cycle 거동을
더 빠른 클럭에서 돌리면 firmware를 바꾸지 않고도 wall-clock latency가 줄어든다(타이머가 세는
100 MHz cycle 수 자체가 감소). 다만 *현재 latency가 연산에 묶여 있는가, 데이터 전송에 묶여
있는가* 를 먼저 확인해야 한다. 이는 예상 연산 시간과 실측을 비교하면 판별된다.

```
예상 연산 시간 ≈ (conv2 병목 cyc/img) × (이미지 수) × (클럭 주기)
             = 1,799 × 10,000 × (1/200MHz) ≈ 90 ms   (compute-only 하한)
실측(200MHz, feed-overlap 후) = 98 ms
```

실측이 compute-only 하한에 근접하면 compute-bound이고 클럭 상승이 직접 latency로 환원된다.
크게 벌어지면 여전히 feed bound다. 두 값의 비교와 함의는 @sec-results · @sec-disc-limit 에서
수치로 다룬다. (목표 클럭은 처음 300 MHz였으나 closure를 진행하며 die 전역 잔여 위반이
비현실적으로 커 중간에 200 MHz로 낮췄다 — 맥락은 @sec-optim-base 후반.)

=== 선행 인프라 — dual-clock CDC

가속기만 빠른 클럭으로 돌리려면 PS·AXI·CSR(100 MHz)와 datapath 사이에 *clock-domain
crossing(CDC)* 이 필요하다. 두 클럭은 동일 MMCM 출력이라 위상이 정렬되어 비교적 안전하지만,
*metastability를 추가로 줄이기 위해* 경계마다 동기화기를 둔다. level 신호는 2-FF 동기화기,
1-cycle pulse 신호는 toggle 기반 동기화기를 쓴다(빠른 클럭에서 펄스가 여러 cycle로 보여
"N배 카운트"되는 것 방지). 사용처는 `cnn_accelerator` 경계 *총 5곳* 이다.

#figure(
  table(
    columns: 4, align: (left, center, center, left),
    table.header[신호][방향][종류][동기화기],
    [`start`], [aclk→clk], [pulse], [`cdc_pulse_sync`],
    [`img_ready`], [aclk→clk], [pulse], [`cdc_pulse_sync`],
    [`img_done`], [clk→aclk], [pulse], [`cdc_pulse_sync`],
    [`input_consumed`], [clk→aclk], [pulse], [`cdc_pulse_sync`],
    [`enable`], [aclk→clk], [level], [`cdc_bit_sync`],
  ),
  caption: [CDC 경계 5곳 — 펄스 4 + 레벨 1],
)

```verilog
// 코드 발췌 C4 — pulse 동기화기: toggle 인코딩 + edge 복원 (cdc_pulse_sync.v)
always @(posedge src_clk)                // src: pulse 마다 toggle 반전 (event=edge)
    if (src_rst) tgl <= 1'b0; else if (pulse_in) tgl <= ~tgl;
(* ASYNC_REG="TRUE" *) reg sync0, sync1; reg sync2;
always @(posedge dst_clk) begin           // dst: 2-FF 동기 + 1 지연
    sync0 <= tgl; sync1 <= sync0; sync2 <= sync1;
end
assign pulse_out = sync1 ^ sync2;         // toggle edge = dst 1-cycle pulse
```

#grid(columns: (1fr, 1fr), gutter: 8pt,
  figbox("figures/existing/clk_wiz.png", [그림 P1: Clocking Wizard 블록], w: 100%),
  figbox("figures/existing/winograd_clock_settings_1.png",
    [그림 P2: Clocking Wizard 내부 클럭 설정], w: 100%),
)

=== MMCM 제약 — "188 MHz는 존재하지 않는다"

Clocking Wizard(MMCM)는 `clk_out1=100`과 MIG IDELAYCTRL용 200 MHz가 *VCO 주파수를 고정*
한다. 따라서 datapath용 `clk_out3`는 그 VCO의 *정수 분주* 만 가능하여, 실제로 생성 가능한
값은 ${200, 171.4, 166.7, 150, dots}$의 이산 집합이다. 함정은 *188 MHz를 요청해도 Clocking
Wizard가 200 MHz로 스냅한다* 는 점이다. 이 스냅은 뒤의 silent timing failure의 결정적 빌미가
된다. 따라서 클럭 목표를 정하기 전 `report_clocks`로 실제 period가 요청값과 같은지 먼저
확인해야 한다.

=== 출발점 — 데이터패스 BRAM에 primitive output register

closure의 첫 조치로, 모든 data-path BRAM(Input / C1C2 / C2Pool / PoolFC)의 출력에
*primitive output register* 를 켰다. 이는 BRAM→로직으로 이어지는 조합 경로를 레지스터로
끊어, BRAM read 직후 단을 파이프라인 경계로 만든다. (BMG 설정 캡처는 `docs/ip_spec/`.)

=== 초기 −8.6 ns → 100→150 MHz (조합 깊이 + conv2 broadcast)

초기 합성의 WNS는 *−8.6 ns* 였다. 진단 결과 주범은 두 가지 조합 깊이 병목 — FC argmax의
17-input 9-level 비교 트리와 conv1의 9-input combiner. argmax는 4-round tournament로,
conv1 adder는 1→4 stage로 파이프라인화했다.

#figbox("figures/existing/01_pre-pipeline_wns-8.6.png",
  [그림: 초기 WNS −8.6 ns], w: 70%)

그 다음 300 MHz 목표 합성에서 WNS *−2.99 ns*, failing endpoint 110,302개가 *전부 datapath
intra-clock* 이었다. 진단 명령은 다음과 같다.

```tcl
report_timing_summary                              # 요약 + 워스트 1개
report_timing -setup -max_paths 44 -file paths.rpt # 위반 전체 덤프 (-file 이 안정적)
report_high_fanout_nets -timing                    # high-fanout net 식별
```

워스트 경로는 *route 86% / logic 14%* — 배선 거리 문제였다. 원인은 conv2의 제어·weight
broadcast(`state`/`sel`/`pe_en`/`packed_w`)가 192개 PE로 fanout되는데, DSP를 226/240(94%)까지
쓰다 보니 PE가 die 전역 DSP 컬럼에 깔려 broadcast가 die-spanning이 된다는 점이다. DSP 위치는
고정이라 floorplan 불가 → 가능한 방법은 파이프라인 + 드라이버 복제뿐이다. 적용한 조치(누적):

+ `max_fanout=32`(conv2_fsm `state`/`kw_cnt`, weight_loader `pe_id`) + `phys_opt -directive
  AggressiveFanoutOpt` → −2.99 → *−2.454*.
+ weight broadcast +1 register(1회성 load라 compute 무영향).
+ `PE_BC_DELAY`로 PE 입력단(`sel`/`pe_en`/`pe_x`)에 register 복제 → broadcast가 PE 클러스터
  근처 replica에서 출발 → *−2.187*.
+ weight_loader 주소·pe_id를 6-level 중첩 곱셈에서 단조증가 accumulator로(조합 깊이 6→1).

#grid(columns: (1fr, 1fr), gutter: 8pt,
  figbox("figures/existing/02_300mhz_conv2-broadcast_wns-2.99.png",
    [그림: −2.99 ns (conv2 broadcast)], w: 100%),
  figbox("figures/existing/03_300mhz_step1b-step2_wns-2.187.png",
    [그림: −2.187 ns (PE_BC_DELAY 후)], w: 100%),
)

300 MHz는 broadcast를 닫아도 reset·FSM 잔여 위반(−1.7\~−1.94)이 die 전역에 남아 비현실적이었다.
*따라서 목표를 낮춰 150 MHz에서 깨끗이 닫았고, 150 MHz 합성 빌드로 MNIST 10,000장을 보드에서
10,000/10,000 분류함을 확정* 하였다.

=== 150→200 MHz — silent timing failure 진단, 그리고 reset fanout

*문제 발생.* 150 이후 "200 MHz 빌드인데 wall-clock이 100 MHz와 동일(18.77 M cyc)"이라는
측정이 나왔다. 처음에는 이를 "오버클럭을 더 해도 안 줄어든다 = feed bound"로 해석할 뻔했다.

*원인 파악.* 그러나 그 "200 MHz 빌드"는 사실 *silently fail한 빌드* 였다 — 188 MHz로 설정 →
Clocking Wizard가 200 MHz로 스냅 → 실제로는 200 MHz로 돌면서 reset 경로(−1.94 ns)가 위반 →
분산 FSM·in-flight 카운터 구조가 desync되어 중간에 멈춤. Vivado는 _요청 클럭(188)_ 기준으로
통과시켰으나 _실제 클럭(200)_ 에서는 위반이었던 것이다. 즉 그 latency 비교는 깨진 빌드끼리의
비교였으므로 폐기했다. 교훈은 셋이다: ① `report_clocks`로 실제 period ≠ 요청 period인지
확인(스냅 탐지), ② *slow(signoff) corner의 양수 WNS만 신뢰*, ③ 타이밍이 깨진 HW 측정은
성능 근거로 쓸 수 없다.

#figbox("figures/existing/04_200mhz_earlier-build_wns+0.04_silent-fail-suspect.png",
  [그림: silent-fail 의심 빌드 (요청 클럭 기준 통과, 실제 클럭에서 위반)], w: 70%)

*해결.* 이 깨달음이 방향을 정했다 — "reset 경로(−1.94)부터 닫자". 남은 최대 위반이 바로
단일 reset net이었다: `rst_sync → BUFG → (fanout 41,323) → DSP/register`, −1.94 ns,
route 85%, die 전역. 단일 net이 datapath 전 레지스터(약 41k)로 직접 fanout되어 BUFG 글로벌
라우팅으로 die 끝까지 가는 데 너무 오래 걸렸다. reset 부하를 없애는 tie-0 방식은 기능 거동을
바꾸고 fragile하여 기각, *reset 복제 트리* 를 채택했다(분배 구조만 바꾸므로 기능 완전 불변).

```verilog
// 코드 발췌 C5 — cnn_accelerator.v: async-assert / sync-deassert 복제 트리
(* max_fanout = 32  *) reg rst_l1;     // trunk (few copies)
always @(posedge clk or negedge resetn)
    if (!resetn) rst_l1   <= 1'b1; else rst_l1   <= rst_sync;
(* max_fanout = 128 *) reg rst_leaf;   // leaf (datapath 근처로 대량 복제)
always @(posedge clk or negedge resetn)
    if (!resetn) rst_leaf <= 1'b1; else rst_leaf <= rst_l1;
wire rst = rst_leaf;
```

`max_fanout`이 합성기에게 `rst_sync(1) → rst_l1(~11) → rst_leaf(~323) → datapath(~41k)`
트리를 자동 생성시키고, 각 leaf 복제본을 자기 클러스터 근처에 배치하게 하여 high-fanout
net을 짧은 local net 다수로 쪼갠다. async-assert이므로 모든 단이 reset을 즉시(스큐 0)
assert하고, deassert만 +2 clk 균일 지연된다(전체 idle-start라 무해). 이후 잔여 위반을
단계적으로 닫았다.

#figure(
  table(
    columns: 5, align: (left, center, center, left, left),
    table.header[단계][WNS(ns)][Fail][워스트 경로][조치],
    [reset 트리(초기)], [−0.154], [44], [`pe_id_reg → pe_load_en_dec_r` (route 82%)], [reset −1.94 소멸],
    [+ phys_opt(default)], [−0.102], [31], [`fsm/state → lb2/mem/CE` (route 86%)], [default plateau],
    [+ `shift_en` mf=16], [−0.098], [1], [(lb2 거의 닫힘)], [RTL 복제(캡처 없음)],
    [+ phys_opt Aggr.Explore], [*+0.011*], [*0*], [—], [*MET*],
  ),
  caption: [표 T4: 200 MHz WNS 마일스톤],
)

세 번째 행의 새 워스트는 conv2 `shift_en`(line buffer clock-enable)이었다. `state`·`kw_cnt`는
이미 `max_fanout=32`였으나 `shift_en`만 빠져 있어 한 줄로 복제 속성을 부여했다.

```verilog
(* max_fanout = 16 *) wire fsm_shift_en;   // conv2_engine.v — zero-latency, 기능 불변
```

마지막 한 끗은 phys_opt directive였다. default `phys_opt_design`은 −0.154→−0.102에서
plateau였고, `phys_opt_design -directive AggressiveExplore`가 −0.098 → *+0.011(0 failing)* 로
마감했다.

#block(inset: (left: 8pt), stroke: (left: 2pt + orange))[
  ⚠ *재현성 함정(필수 기록)*: 위 AggressiveExplore는 interactive phys_opt의 in-memory
  결과다. impl을 재실행하면 −0.098로 되돌아간다. 재현하려면 *impl strategy에 post-route
  phys_opt(AggressiveExplore)를 명시적으로 넣어야* 한다.
]

최종 결과는 *200 MHz timing CLOSED — WNS +0.011, TNS 0.000, WHS +0.002* 다. 이는 slow(signoff)
corner의 양수 WNS이므로 앞의 −1.94 silent fail과 근본적으로 다른 정식 충족이다.

#grid(columns: (1fr, 1fr), gutter: 8pt,
  figbox("figures/existing/direct_impl_200MHz_timing_summary.png",
    [그림: 최종 200 MHz timing summary (MET)], w: 100%),
  figbox("figures/existing/direct_impl_200MHz_power_summary.png",
    [그림: 200 MHz power summary (해석은 @sec-disc-power)], w: 100%),
)

이 설계의 datapath 타이밍 벽은 대부분 high-fanout 제어·reset net의 route delay였고(로직 깊이가
아님), 효과적인 방법은 `max_fanout`으로 드라이버를 클러스터 근처에 복제하는 것이었다. 워스트
하나를 닫으면 다음 워스트가 드러나는 과정이 반복되었다(상세는 @sec-discussion).

== Winograd Track — 200 MHz 시도 끝에 171.42 MHz로 met <sec-optim-wino>

Winograd 엔진도 같은 closure 방법을 적용했으나, 곱셈을 줄이는 대신 transform network·gather
구조가 추가되어 *route congestion이라는 새로운 변수* 가 생겼다. RTL은 시뮬레이션 bit-exact로
검증됐고 합성도 fit했지만, 목표였던 200 MHz는 끝내 닫지 못하고 *171.42 MHz에서 timing-met*
으로 마무리했다.

*합성 단계 — LUT overflow.* Winograd weight는 offline에서 미리 변환된 상수($U = G g G^T$)이므로,
첫 설계는 이 변환 상수를 conv2_winograd 내부 상수 ROM에 baked하여 모듈이 자체 weight를 들고
있도록 했다(외부 weight BRAM·loader 불필요). 그러나 이 상수 ROM이 LUT로 합성되어 LUT를 78.7K
(63.4K 초과)까지 차지해 배치가 실패했다. 두 가지로 해결했다: ReLU 출력 범위 분석으로 데이터
비트폭을 줄이고(VW 16→14, MW 32→25, YW 36→28 등), baked ROM을 PS-writable BMG(`wino_weight_bram`)로
바꿔 같은 상수를 BRAM에서 읽도록(ROM과 bit-identical) 옮겼다. 결과 LUT 75.88%로 fit.

*라우팅 단계 — 병목 제거.* routing에서 worst path를 하나씩 제거했다. baseline과 달리 병목의
성격은 route congestion이었다.

- *−2.04 ns*: row buffer write broadcast(fanout 312, route 93%) → per-PE distributed LUTRAM 전환.
- *−1.74 ns*: output transform의 20-level 조합 깊이 → OT를 1-cycle에서 4-stage로 분할.
- *−0.41 ns*: 합성기가 4-lane weight 레지스터를 equiv-merge해 fanout 2,944 폭증 → `(* keep,
  max_fanout *)`로 lane별 복제 보존.
- *−0.34 ns*: 잔여 40 endpoint를 IT·tile6·wm·gather 4개 class로 층화.
- *−0.094 ns, 7 EP*: 세 class(M/B/D)만 남음 — M은 25-bit 음수 누적 carry chain, B는 tile6_q
  (2,304-bit) die-spanning scatter, D는 동일 25-bit 가산.

*−0.094 ns / 7 EP의 두 부류.* 남은 7 endpoint는 logic-bound와 route-bound로 나뉜다. worst
path는 reduce 출력 `gpim_q`에서 `m_im_flat`까지의 경로로, 한 cycle 안에 25-bit 가산과 conj
부호반전 carry chain이 직렬로 놓여 있다.

```
Slack (VIOLATED):   -0.094 ns
Source:             conv2/gpim_q_reg[25][4]/C
Destination:        conv2/m_im_flat_reg[874]/D
Path Group:         clk_out3  (200 MHz target)
Data Path Delay:    4.942 ns   (logic 2.851 ns = 57.7%,  route 2.091 ns = 42.3%)
```

logic이 57.7%로 지배적이므로 이 경로는 조합 깊이가 한계인 logic-bound다. 반면 B
(`tile6_q→u_it`, 2,304-bit die-spanning scatter)와 D는 logic이 얕고 route가 68\~85%를 차지하는
route-bound다. 두 부류는 처방이 다르다 — logic-bound는 RTL 파이프라인 분할로 조합 깊이를 줄여야
닫히고, route-bound는 배치(over-constrain·`max_fanout` 복제)로 배선을 줄여야 닫힌다. 한쪽 처방을
다른 부류에 적용하면 효과가 없거나 역효과가 난다.

*route-bound 처방 — over-constraining.* route 벽을 줄이는 방법이 over-constraining이다.
place/route 동안 `set_clock_uncertainty -setup 0.7`로 클럭을 인위로 더 조여 placer·router가
critical net을 더 짧게 풀도록 강제하고, signoff 직전 `-setup 0`으로 되돌려 *실제 제약 기준
WNS* 를 측정한다. impl strategy 훅(place PRE / post-route phys-opt PRE)으로 자동화해 Design
Runs의 WNS 열이 곧 signoff 값이 되게 했다. 핵심은 over-constrain이 *배치 자유도만 더 쓰게 할
뿐 조합 깊이는 못 줄이므로 정확히 route-bound 벽에만 듣는다* 는 점이다 — logic 벽 M에는 무효다.

그 순효과를 통제 실험으로 분리했다 — 동일 합성에서 directive와 over-constrain만 달리한 세
impl run을 비교했다.

#figure(
  table(
    columns: 4, align: (left, left, center, center),
    table.header[impl run][directive][over-constrain][WNS \@171.42],
    [stock (tool 기본)], [Default], [—], [+0.068],
    [strong directives], [ExtraTimingOpt + phys-opt], [—], [+0.026],
    [over-constrained], [ExtraTimingOpt + phys-opt], [+0.7 ns], [*+0.180*],
  ),
  caption: [표 T13: over-constrain의 순효과 — 동일 synth·directive에서 over-constrain만 추가.
    directive 강화만으론 비단조(+0.026 < +0.068, placement은 확률적)이고, over-constrain이
    약 +0.11 ns의 실효 마진을 만든다 (route-bound 벽이 지배하는 171.42 MHz)],
)

#figbox("figures/user/winograd_impl_runs_compare.png",
  [그림: 세 impl run의 Design Runs 비교 — 동일 synth에서 레시피만 달리해 WNS·util·power 대조],
  w: 85%)

이 마진으로 171.42 MHz를 닫았다. 표 T13은 통제 비교용 run이고, 제출 signoff build는 동일
over-constrain으로 WNS +0.222로 닫혔다(그림 F11). 200 MHz에서는 같은 over-constrain으로 route 벽 B·D는 줄었으나
logic 벽 M의 조합 깊이가 그대로 남아 closure에 이르지 못했다.

*한계에 부딪힘 — bisect와 floorplan 둘 다 실패.* −0.094를 닫기 위한 두 시도가 모두 역효과였다. (i) *M carry-bisect(13+12 분할)*: M은 닫혔으나(−0.094→0) +1 latency와 새
레지스터 배치 churn으로 *B class가 −0.088→−0.150 회귀* 하고 Fmax가 196→187 MHz로 떨어져 revert.
(ii) *Floorplan(pblock 압축)*: gather→central-reduce 구조가 lane 입력 4-way fan-in과 글로벌
출력 fan-out을 동시에 갖는 net-bound 구조라, 압축하면 한쪽 net이 반드시 늘어난다 → 강제 압축
시 WNS −1.116으로 10배 악화 → 본질적으로 floorplan 부적합.

*현재 위치 — 171.42 MHz MET.* 200 MHz는 한 worst path를 줄이면 다른 worst path가 드러나는 과정이 반복되어 닫지 못했고,
*171.42 MHz로 fallback* 했다. *171.42 MHz에서는 WNS +0.222 ns, TNS 0.000, 0 failing endpoint로
timing이 닫혔다* (period 5.833 ns, 그림 F11). 200 MHz만 미완이다. 200 MHz closure에 남은 처방은 두
부류에 각각 대응한다. route 벽 B·D는 over-constrain으로 줄어들고(표 T13), logic 벽 M은 worst
path의 carry chain을 register로 분할해 조합 깊이를 낮춘다 — msum 가산기와 `wino_m_assemble`
(부호반전) 사이에 register 1단을 삽입한 형태다.

```verilog
// msum = acc + gpre_q (가산) 과 wino_m_assemble (conj 부호반전) 사이에 register 1단 삽입
reg signed [MW-1:0] msum_im_q [0:25];
always @(posedge clk) if (mul_en_q4)
  for (kk = 0; kk < 26; kk = kk + 1)
    msum_im_q[kk] <= acc_im[kk] + gpim_q[kk];      // carry chain #1 (가산) 만 한 cycle
wino_m_assemble u_asm (.sim_flat(msum_q_im_flat), ...);  // 부호반전은 다음 cycle 로 분리
```

이 분할은 latency를 1 cycle 늘리되 throughput(cyc/img)은 불변이며, conv2 standalone과 full
pipeline TB 모두 100/100 bit-exact로 동작 보존을 확인하였다. 앞선 carry-bisect는 M을 닫았으나
새 레지스터가 route 벽 B·D의 배치를 churn시켜 Fmax가 196에서 187 MHz로 낮아졌으므로, 이 분할은
over-constrain과 함께 적용해 route 벽의 churn을 억제한다.

#grid(columns: (1fr, 1fr), gutter: 8pt,
  figbox("figures/existing/winograd_impl_171.42MHz_timing_summary.png",
    [그림 F11: Winograd 171.42 MHz timing summary (MET)], w: 100%),
  figbox("figures/existing/winograd_impl_171.42MHz_power_summary.png",
    [그림: Winograd 171.42 MHz power summary], w: 100%),
)

다만 *보드 실측은 수행하지 못했다* — 보드 제출 마감 시점에 200 MHz fallback이 확정되지 않아
최종 Winograd 비트스트림의 HW bring-up·latency 측정을 하지 못했다. 따라서 Winograd의 1만 장
latency는 시뮬레이션 bit-exact + implementation timing(171.42 MHz met) + TB 측정 cycle로부터
추정한다: compute-bound 가정 시 약 $1,341 times 10,000 / 171.42 "MHz" approx 78 "ms"$(feed
오버랩 무시), 200 MHz가 닫혔다면 \~67 ms였을 것이다. 모두 보드 실측이 아닌 추정임을 명시한다.

== 두 트랙 종합 <sec-optim-summary>

Baseline은 *200 MHz MET(WNS
+0.011 ns)이고 보드 실측까지 완료* (\~98 ms)했고, Winograd는 200 MHz를 닫지 못해 *171.42 MHz
MET(WNS +0.222 ns)으로 fallback했으며 보드 실측은 시간상 못 해 추정(\~78 ms)* 에 그친다.

#figure(
  table(
    columns: 4, align: (left, center, center, center),
    table.header[항목][Baseline (Direct)][Winograd],
    [클럭], [200 MHz], [171.42 MHz],
    [WNS], [+0.011 ns (MET)], [+0.222 ns (MET)],
    [검증], [보드 실측], [시뮬 bit-exact only],
    [정확도], [10,000/10,000 (실측)], [100/100 (시뮬, 보드 미측)],
    [cyc/img], [\~1,799 (conv2 floor)], [\~1,341 (TB)],
    [1만장 latency], [\~98 ms (실측)], [\~78 ms (추정)],
  ),
  caption: [표 T12: Baseline vs Winograd closure 종합 (실측/추정 구분)],
)

같은 closure 방법(`max_fanout` 복제, 파이프라인 분할, phys_opt directive)이 성격이 다른 두
설계 모두에 적용되었다. 다만 Winograd는 gather 구조의 route 특성 때문에 마지막 구간을 닫기가
더 어려워, 같은 200 MHz 목표에 도달하지 못하고 한 단계 낮은 이산 클럭에서 닫혔다.
