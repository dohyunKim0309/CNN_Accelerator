# CNN Accelerator — 발표 개요 (Deep Outline)

> **원칙**: 개요(이 문서)는 딥하게, **PPT 슬라이드는 가볍게**.
> 각 섹션은 `① 한 줄 메시지 → ② 발표 논리(대본) → ③ 핵심 수치/그림 → ④ 슬라이드(가볍게) → ⑤ 예상 질문` 구조.
> **이 개요의 범위 = 김도현 발표분: 0(소개/협업) · 3(Overclock) · 4(Complex Winograd) + 5(결론)**.
> 1(Computational 병목: SIMD packing/dataflow) · 2(Dataflow 병목: ping-pong/AXI-DMA)는 **팀원 위임 — 별도 작성**(여기선 제외).
>
> **전체 관통 서사**: "MNIST 1만 장 분류 **end-to-end latency** 최소화"라는 단일 목표 아래,
> **병목을 측정 → 식별 → 제거**하는 사이클을 4번 돈다:
> `Compute 병목(1·팀원) → Dataflow 전송 병목(2·팀원) → Clock 병목(3) → Algorithm 병목(4)`.
> 매 단계 "**무엇이 새 병목인지 측정으로 확인**"하는 게 이 프로젝트의 방법론. (3·4가 그 뒷부분.)

---

## 발전 과정 한눈에 (전 섹션 공통 백본)

| 단계 | 무엇을 풀었나 | 1만 장 Latency | 배수 |
|---|---|---|---|
| Baseline (INT8 Direct) | 전체 파이프라인 동작 | **1079 ms** | 1.00× |
| Inter-image Pipelining | stage 간 ping-pong, 가속기 idle 제거 | **586 ms** | 1.84× |
| AXI Burst + DMA | PS→PL 전송 병목 제거 | **187 ms** | 5.77× |
| Overclock 150 MHz | fanout/route 병목 제거 | **128 ms** | 8.4× |
| Overclock 200 MHz | reset fanout + phys_opt | **108.9 ms** | 9.9× |
| + Vitis feed-overlap | CDMA feed 와 compute 겹침 | **98 ms** | 11.0× |
| (예정) Complex Winograd | conv2 곱셈 144→46 | **~66–67 ms (이론)** | ~16× |

> 발표 내내 이 표를 "오른쪽으로 한 칸씩 채워가는" 식으로 재등장시키면 서사가 잡힌다.
> 결론 슬라이드에서 실측 보드 사진(1.74s → 0.68s → 0.18s 등 실제 캡처)으로 마무리.

---

# 0. 프로젝트 소개 및 협업 과정  〔담당: 김도현〕

### ① 한 줄 메시지
> "Arty A7-100T 한 장 위에서, INT8 MNIST CNN을 **PL 전용 추론 IP**로 구현하고, 1만 장 분류 latency를 최소화한다. 3명이 **명세 검증 → RTL → 보드**의 동일 파이프라인을 공유하며 협업했다."

### ② 발표 논리 (대본 수준)

**(a) 문제 정의 — 무엇을, 어디서, 무엇을 기준으로**
- **타겟 네트워크**: `Conv1(8,1,3,3) → ReLU → Conv2(16,8,3,3) → ReLU → MaxPool2×2 → FC(2304→10) → argmax`. 전부 INT8(weight/activation), 누적 후 `>>10 + ±127 saturation`.
- **역할 분담(HW/SW)**: PS(MicroBlaze)는 **데이터 전송 + start/done 제어만**. 모든 추론 연산은 PL의 `cnn_accelerator` IP 내부.
- **평가 지표(1순위)**: 단일 이미지 latency가 아니라 **1만 장 end-to-end** — PS→PL 전송, BRAM I/O, batch 누적까지 포함. → 이게 뒤의 모든 최적화(팀원 파트 1·2 + 내 파트 3·4) 방향을 결정한다 (여기서 못 박아두면 전부 같은 자(尺)로 이야기됨).
- **제약(보드 한도)**: DSP48E1 **240개**, BRAM 135(4.6Mb), LUT 63K, FF 126K. → 특히 **DSP 240개**가 뒤 섹션 전부의 "예산". (Conv2가 MAC의 90%라 DSP를 다 먹는다 → SIMD packing / Winograd의 동기.)

**(b) 시스템 아키텍처 (Block Design 한 장)**
- MicroBlaze + DDR3(MIG) + UART + Clocking Wizard + Proc System Reset.
- **PS-facing BRAM ×5**: input / output / conv1·conv2·fc weight.
- **Custom IP 2개**: `csr_axi`(start/done/timer) + `cnn_accelerator`(Conv1→Conv2→MaxPool→FC→argmax + stage 간 ping-pong BRAM).
- 강조 포인트: **중앙 컨트롤러 없음** → 각 엔진이 자체 FSM + in-flight 핸드셰이크(`write_done`/`read_done` pulse)로 **분산 제어**. (이 구조가 3장 오버클럭의 reset 병목과도 직결.)

**(c) 협업 과정 — "어떻게 3명이 한 칩을 만들었나"**
- **공통 인프라 먼저(Phase 0, Sobel Baseline)**: 본 CNN 전에 102×102 Sobel edge IP로 PS-PL 인터페이스 / AXI CSR / BRAM dual-port / line-buffer stencil을 **먼저 검증**. → 위험을 앞단에서 제거하고 공용 빌딩블록 확보.
- **공용 모듈화**: `RTL/core/`의 `line_buffer / window_register / pe_cell / truncate_relu`를 parameter화 → conv1·conv2가 **동일 PE 빌딩블록**을 재사용. (3명이 같은 부품을 공유 → 인터페이스 충돌 최소화.)
- **역할 분담**:
  - 김도현: PE(SIMD packing) / Conv2 engine / CSR_AXI / 헤더, 그리고 **오버클럭·Winograd**(이번 발표의 3·4장).
  - 김동주: PE / Conv1 engine.
  - 신지민: ping-pong buffer / MaxPool / FC / argmax / hex 생성.
  - 공통: Block Design, top wiring.
- **검증 규율(가장 중요한 협업 자산)**: **golden-first**.
  1. Python으로 명세 구현 → `output.npy`와 **bit-exact** 확인.
  2. 동일 동작을 RTL로 → `TB/`에서 **같은 입력에 같은 출력** 검증(iverilog, Vivado 없이 로컬).
  3. Vivado/Vitis 보드 검증 → 1만 장 latency 측정.
  - → 모든 RTL 변경은 **push 전 iverilog bit-exact가 게이트**. (오버클럭의 `max_fanout` 복제, Winograd 변환이 "기능 불변"임을 이 게이트로 증명.)
- **Git/PR 협업**: 브랜치 전략 + PR 흐름(`docs/cowork_guide.md`).

### ③ 핵심 수치/그림
- Block Design 다이어그램 1장. CNN 네트워크 dim 흐름 1장. 역할 분담 표. 검증 파이프라인(golden→RTL→board) 1장.

### ④ 슬라이드 (가볍게)
- **슬라이드 1**: 목표 한 줄 + 보드 사진 + "1만 장 latency가 척도" 한 문장.
- **슬라이드 2**: 네트워크 dim 흐름(그림만).
- **슬라이드 3**: Block Design(그림만, 말로 설명).
- **슬라이드 4**: 역할 분담 표 + "golden→RTL→board" 3-step 그림.
- 텍스트 최소화. 위 (a)~(c)는 **말로**.

### ⑤ 예상 질문
- "왜 PS가 아니라 PL에서 다 하나?" → latency/throughput 목표 + 가속기 IP가 과제 핵심.
- "왜 INT8?" → 보드 DSP/BRAM 예산, 명세.
- "3명이 어떻게 충돌 안 나게?" → 공용 core 모듈 + golden bit-exact 게이트 + PR.

---

# 3. Additional (1) — Overclock (100 → 200 MHz)  〔담당: 김도현〕

> 근거 문서: `docs/overclock_journey_100_to_200mhz.md`(서사·디버깅 로그), `docs/overclock_300mhz.md`(기술 레퍼런스),
> `docs/timing/`(WNS 캡처), 실측: `docs/150MHz_result.png`·`docs/200MHz_result_vitis_optimize.png`.

### ① 한 줄 메시지
> "같은 RTL을 **더 빠른 클럭**에서 돌리면 firmware 한 줄 안 고치고 latency가 준다. 그런데 이 칩의 타이밍 벽은 **로직 깊이가 아니라, die 전역으로 퍼지는 high-fanout 제어/리셋 net의 route delay**였다. 해법은 로직 재설계가 아니라 **`max_fanout`으로 driver를 클러스터 근처에 복제**하는 것 — 한 줄짜리 처방. 100 → **200 MHz**, 187 → **108.9 ms**(+ Vitis feed-overlap **98 ms**)."

### ② 발표 논리 — "병목을 측정 → 진단 → 닫는" 디버깅 서사 (이 장의 핵심)

> 이 장은 결과만 나열하지 말고 **"무엇이 병목이라고 생각했다가 틀렸고, 측정으로 어떻게 진짜 병목을 찾았는가"**의 추리물로 끌고 간다. 그게 이 작업의 진짜 기여.

**(a) 왜 오버클럭인가 — 무엇을 *안* 건드리는가**
- baseline(여기까지 = 2장 AXI+DMA build, **100 MHz, 0.188 s, 10000/10000**)에서 가속기는 **compute-bound**: conv2 throughput floor ≈ **1798 cyc/img**.
- **아이디어**: cycle 거동을 그대로 둔 채 **가속기 datapath 클럭만** 올리면, 100 MHz timer가 세는 wall-clock cycle 수가 그대로 줄어든다 → **firmware 완전 무변경**(timer/PS 코드 손 안 댐).
- 처음 목표는 **300 MHz(3×)**, 현실적으로 **200 MHz**에서 닫혔다. 이 장은 그 사이 모든 결정의 기록.

**(b) 선행 인프라 — dual-clock CDC로 datapath만 분리, 그리고 "CDC 무죄" 확정**
- 가속기만 빠른 클럭으로 돌리려면 PS/AXI/CSR(100 MHz)와 datapath(빠른 클럭) 사이 **클럭 도메인 횡단(CDC)**이 필요.
- RTL(`cnn_accelerator.v` + `core/cdc_pulse_sync.v`/`cdc_bit_sync.v`):
  - `aclk`(100) 포트 추가. `enable`=**2-FF level sync**, `start`/`img_ready`=**toggle pulse 동기화**(빠른 클럭에서 1-cycle pulse가 N cycle로 보여 **"N배 카운트"**되어 같은 이미지를 N번 처리/bank desync 되는 것 방지).
  - `img_done`/`input_consumed`는 datapath→100 방향 CDC, `bram_output`은 Port A write@datapath / Port B read@100 **dual-clock BRAM**.
  - **CSR·firmware·엔진·BMG는 무변경**(common-clock 골격 유지) — CDC FF만 가속기 안에 넣음.
- **XDC 제약 — 왜 필요한가 (발표 20초 포인트)**: 도메인을 둘로 나누면 100↔datapath **경계 경로**가 생기는데, STA(타이밍 분석기)는 기본적으로 이걸 *목적지 클럭 1주기 안에* 닫으라고 요구 → **실제론 여유 있는 멀쩡한 경로가 가짜 violation**으로 뜬다. → XDC로 "이 경계 경로를 어떻게 분석하라"고 정확히 알려줘야 **timing이 닫힌다**(안 하면 빌드 자체가 FAIL).
  - write-bus(100→datapath, 실데이터)는 `set_max_delay -datapath_only`(**비정수 클럭비**(190:100=1.9:1)에서도 비율 무관·idempotent해 안전; 애초 multicycle은 부적합), CDC 동기화기 입력(datapath→100)은 `set_false_path`.
- **검증으로 CDC를 일찌감치 무죄 처리**: 듀얼클럭 TB `tb_system_axi_multi_2clk` **10/10**(3배카운트/펄스손실/데드락 없음) + `report_clock_interaction`. → **이후 어떤 타이밍 문제도 CDC가 원인이 아님을 확정** → 디버깅을 **datapath 내부(intra-clock)에만** 집중할 수 있었다.

**(b′) CDC 두 모듈 — 무엇을, 왜 (미니 섹션)**
> 경계 신호는 **종류별로** 처리가 다르다. 모든 CDC는 top `cnn_accelerator.v`의 **경계 5곳에만** 격리 → 엔진(conv1/2·maxpool·fc)·CSR·firmware 무변경.

- **왜 필요한가 (위상 정렬돼도 동기화기가 필요한 이유)**: 두 클럭이 같은 MMCM라 위상 정렬돼도 —
  1. **메타스테이빌리티**: 지터·coincident-edge 때문에 경계 FF가 불확정 상태에 빠질 수 있다 → 2-FF로 **resolve**(다음 클럭에 안정값으로 정착).
  2. **펄스 폭(기능) 문제**: 100 MHz의 **1-cycle 펄스가 빠른 클럭에선 2~3 cycle로 보임** → 같은 이미지를 **N번 카운트**(handshake `prior_diff` N배 차감)·bank desync. ← *이게 사실 더 큰 위협이고, 메타와 별개.*
- **`cdc_bit_sync` — Level 신호용 (2-FF)**: `enable`(CSR 100 → datapath). 천천히 바뀌는 레벨 → **메타 resolve만**.
  ```verilog
  (* ASYNC_REG="TRUE" *) reg [1:0] sync;
  sync <= {sync[0], d_in};   // d_out = sync[1]
  ```
- **`cdc_pulse_sync` — Pulse(1-cycle) 신호용 (toggle 인코딩 + 2-FF + XOR 복원)**: `start`/`img_ready`(100→datapath), `img_done`/`input_consumed`(datapath→100, 양방향).
  ```verilog
  if (pulse_in) tgl <= ~tgl;             // src: event = toggle edge (레벨로 인코딩)
  sync0<=tgl; sync1<=sync0; sync2<=sync1; // dst: 2-FF 동기 + 1지연
  pulse_out = sync1 ^ sync2;             // XOR로 1-cycle pulse 복원
  ```
  → **펄스 폭(N배 카운트) + 메타를 동시에** 해결. 2-FF(메타 resolve)가 알맹이, toggle 래퍼가 펄스 의미 보존.
- **세 갈래 정리**: ① level → `cdc_bit_sync`, ② pulse → `cdc_pulse_sync`, ③ **multi-bit 버스(BMG write) → 동기화기 불가**(비트별 resolve 시점 달라 깨짐) **→ XDC `set_max_delay`로 처리**. → CDC 표면적이 **1-bit 5개뿐**이라 검증이 쉬웠던 게 핵심.

**(c) MMCM 함정 — "188 MHz는 존재하지 않는다"** (스토리의 1차 반전)
- clk_wiz(MMCM)에서 `clk_out1=100` + `clk_out2=200`(MIG IDELAYCTRL ref)이 **VCO 주파수를 고정**한다. 그러면 `clk_out3`는 그 VCO의 **정수 분주**만 가능 → 실제로 낼 수 있는 값은 **{200, 171.4, 166.7, 150, …}의 이산 집합**.
- **188을 요청해도 clk_wiz가 200으로 스냅**한다. → "190/188로 타협"은 애초에 불가능했고, 닫을 후보는 **낮은 쪽(171.4/166.7/150)** 또는 **높은 쪽(200, 닫히면)** 뿐.
- 교훈: **클럭 목표를 정하기 전에 MMCM가 그 주파수를 *실제로* 생성할 수 있는지** `report_clocks`로 먼저 확인. (이 스냅이 뒤(e)의 silent-fail 빌미가 된다.)

**(d) 100 → 150 — Conv2 broadcast fanout을 닫다**
- 300 MHz 1차 합성: **WNS −2.99, Failing 110302/176215, 전부 `clk_out3→clk_out3`**(datapath intra-clock). CDC·제약은 멀쩡(b).
- **진단의 핵심 — 로직 깊이가 아니라 route**: 워스트 path가 **route 86% / logic 14%**, Logic Levels 3, DSP None. 즉 **연산이 느린 게 아니라 배선 거리가 문제**.
- 원인: 제어/weight broadcast(`state`/`sel`/`pe_en`/`pe_id`/`packed_w`)가 **192개 PE로 fanout**. DSP **226/240 = 94%** 사용 → PE가 die 전역 DSP 컬럼에 깔림 → broadcast가 본질적으로 **die-spanning**. DSP 위치는 고정이라 floorplan 불가 → **복제 + 파이프라인이 유일 레버**.
- 레버(누적):
  1. **`max_fanout=32`** (conv2_fsm `state`/`kw_cnt`, weight_loader `pe_id`/`slot_id`/`pe_load_en`) + `phys_opt -directive AggressiveFanoutOpt`. → −2.99 → **−2.454**(~173 MHz). 복제만으론 부족.
  2. **weight broadcast +1 register**(Step1b) — weight-load는 1회성이라 compute 무영향(cycle-neutral).
  3. **`PE_BC_DELAY` PE 입력 파이프**(Step2) — PE 입력단에 +N register 복제 → broadcast가 PE 클러스터 근처 replica에서 출발. → **−2.187**.
  4. **weight_loader nested-multiply → accumulator** — 주소/pe_id의 `(((oc·8)+ic)·3+kh)·3+kw` 6-level CARRY4를 단조증가 accumulator로 → **조합깊이 6 → 1**.
- 검증: iverilog `tb_cnn_accelerator_multi` **40/40 bit-exact** (`PE_BC_DELAY` N=0→1798, 1→1799, 2→1800 cyc/img — 정확히 +N/img).
- **그런데 300은 안 닫힌다**: broadcast를 닫아도 reset/FSM 잔여(−1.7~−1.94)가 die 전역에 남음 → **낮은 쪽 150 MHz에서 깨끗이 닫고**, HW **10000/10000** 확정(**0.128 s**, `150MHz_result.png`).

**(e) 우회로 — 버린 가설 하나 (정직한 기록, 발표의 훅)**
- 150 이후 한때 *"오버클럭을 더 해도 latency가 안 준다 = feed-bound(클럭 무관)"*라고 결론냈었다. 근거: "가속기 200 MHz인데 wall-clock이 100 MHz와 동일(18.77M cyc)"이라는 측정.
- **이 가설을 폐기했다.** 그 "200 MHz 빌드"가 사실 **silently fail한 빌드**였을 가능성이 큼 — **188 설정 → 200으로 스냅(c) → 실제로는 200으로 돌면서 reset 경로(−1.94) 위반 → 분산 FSM/in-flight 카운터 desync → 중간에 멈춤/오작동.** 즉 "같은 wall-clock"은 **깨진 빌드끼리의 비교**라 확정 불가.
- → 관련 결론/주석/메모를 전부 제거하고 **확실한 사실(150 동작)만** 남김.
- **교훈 2개**: ① 측정으로 결론 내리기 전에 그 빌드가 **timing-clean(positive WNS @ slow corner)** 인지 먼저 봐라. ② 요청 클럭 ≠ 실제 클럭(188→200 스냅)이면 Vivado가 통과시킨 빌드도 실모드에서 **silent fail**한다. → 이 깨달음이 150→200의 방향("**reset부터 닫자**")을 정했다.

**(f) 150 → 200 — reset fanout을 닫다 (본편)**
- 남은 최대 WNS = **단일 reset net** `rst_sync_reg → BUFG → (fanout 41323) → DSP/RSTB·register`, **−1.94, route 85%, 1343 violating endpoints, die 전역**. 한 net이 datapath 전 register(~41k)로 직접 fanout → BUFG 글로벌 라우팅으로 die 끝 DSP까지 가는 데 너무 김.
- **접근 선택**: tie-0(reset 자체 제거) **기각**(기능 거동 바뀜·X-leak 검증 부담·fragile) → **reset 복제 트리 채택**(reset을 *제거*하지 않고 **분배 구조만** 바꿈 → 기능 완전 불변):
  ```verilog
  (* max_fanout = 32  *) reg rst_l1;   // L1 trunk (few copies)
  (* max_fanout = 128 *) reg rst_leaf; // L2 leaf (datapath로 대량 복제)
  ```
  - 합성이 `rst_sync(1) → rst_l1(~11) → rst_leaf(~323) → datapath(~41k)` 트리를 **자동 생성**하고 leaf 복제본을 **자기 cluster 근처 배치** → 긴 high-fanout net이 **짧은 local net 다수로 쪼개짐**(BUFG 불필요).
  - **async-assert(`negedge resetn`)/sync-deassert** 유지 → 모든 단이 스큐 0로 reset, deassert만 +2clk 균일(idle-start라 무해, leaf끼리 상대 스큐 0). 하류 `if(rst)`는 전부 그대로 → **기능 투명**.
- **양파 까기(onion-peeling) — 워스트 하나 닫으면 다음이 노출**:

  | 단계 | WNS | Failing | 조치 |
  |---|---|---|---|
  | reset 트리만 | **−0.154** | 44 | (−1.94 **완전 소멸** 확인) |
  | + phys_opt (default) | **−0.102** | 31 | default가 plateau("did not improve") |
  | + conv2 `shift_en` max_fanout | **−0.098** | 1 | line buffer CE 클러스터 닫힘 |
  | + **phys_opt `-directive AggressiveExplore`** | **+0.011** | **0** | **MET ✅** |

  - `shift_en`은 conv2_fsm의 **조합 출력**이 8 ic line_buffer/window CE로 die 전역 broadcast되는데(`line_buffer.mem`이 FF 합성 → CE=`shift_en&(ptr==addr)`), `state`/`kw_cnt`엔 있던 `max_fanout`이 **`shift_en`만 빠져 있었다** → `(* max_fanout=16 *)` 한 줄로 31→1.
- **검증**: iverilog `tb_cnn_accelerator_multi` 40/40 + `tb_system_axi_multi` 10/10 bit-exact. (★ `dsp48e1_model.v`에 `initial`이 없어 reset 변경의 X를 **실제 전파**해서 잡는다 → bit-exact PASS = X-leak 없음 = HW(GSR=0)는 더 안전.)
- **★ +0.011 = positive WNS @ slow(signoff) corner = 정식 MET** ((e)의 −1.94 silent fail과 근본적으로 다름).

**(g) FC argmax — "합성기가 10단 직렬 비교기로 풀어버린다"** (브레인덤프 포인트, datapath 내 또 다른 fanout-무관 병목)
- FC 끝단 10-class argmax를 **1-cycle combinational 10-way 비교**로 짜면 24-bit 비교기 **9단이 직렬**로 풀려 **100 MHz에서도 setup −8.6 ns** → 200은 논외.
- **해결: 4-round 파이프라인 토너먼트** `10→5→3→2→1`, round마다 register. stage critical path = "**24-bit 비교 1개 + 2:1 mux**"만 남김.
- tie-break: 페어링을 left가 항상 더 낮은 인덱스가 되게 + strict `>` → **"낮은 인덱스 우선", 기존 combinational과 bit-exact 동일**(`RTL/fc/fc_argmax.v`). latency = in_valid 후 4 cycle.

**(h) 결과 & 왜 정확히 2×가 아닌가** (정직한 분석으로 마무리)
- **150 MHz: 0.128 s**(12,795,913 cyc, in-CDMA 67%) → **200 MHz: 108.9 ms**(10,896,290 cyc, WNS +0.011) → **+ Vitis feed-overlap: 98 ms**(9,799,994 cyc, in-CDMA 56%).
- baseline(100 MHz AXI-DMA) 0.188 s 대비 **1.72×**, 150 대비 1.17×.
- **왜 2×가 아닌가**: profile상 **in-CDMA(blocking) 72%**(7.9M cyc)가 **100 MHz feed 도메인**(가속기 클럭 무관). 가속기 2×는 **compute slice만** 압축 → 전체는 1.72×. **현재 floor = CDMA feed.**
- → **다음 레버**: ① feed overlap(non-blocking/prefetch CDMA + 입력 bank>2) — Vitis 단에서 이미 98 ms로 일부 회수, ② **Complex Winograd**(4장, compute 자체를 줄여 feed를 푼 뒤 효과).

### ③ 핵심 수치/그림 (자료는 이미 repo에 있음)
- **WNS 진행 표**: −2.99 → −2.454 → −2.187 → (reset)−0.154 → −0.102 → −0.098 → **+0.011**.
- **route% vs logic% 막대**(86% vs 14%) — "배선이 문제" 한 장.
- **fanout 41323 → 복제 트리**(rst_sync→l1→leaf→41k) 그림.
- reset/shift_en **`max_fanout` 한 줄** 코드 스니펫.
- argmax **9단 직렬 → 4-round 토너먼트** 그림.
- 실측 캡처: `150MHz_result.png`(128 ms), `200MHz_result_vitis_optimize.png`(98 ms), `docs/timing/*`.

### ④ 슬라이드 (가볍게 — 5장 + 백업)
- **S1**: "클럭만 올리면 firmware 무변경으로 빨라진다" + `187 → 108.9 → 98 ms` 화살표.
- **S2 (이 장의 한 장)**: **"이 칩의 벽 = route delay(배선 거리), 해법 = `max_fanout` 복제"** + route 86% 막대 + reset 복제 트리 그림.
- **S3**: WNS 진행 표(한 줄씩 애니메이션) → **+0.011 MET**.
- **S4**: argmax 9단 직렬 → 4-round 토너먼트(작은 임팩트 카드).
- **S5**: 실측 사진 2장 + "왜 1.72×인가 = CDMA feed 72%".
- **말로만**: (b) CDC 무죄, (c)(e) MMCM 스냅 + silent-fail 훅("188은 존재하지 않았다"). 시간 빡세면 S4 생략하고 g는 한 문장.

### ⑤ 예상 질문 (Q&A 대비)
- **"왜 300이 아니라 200?"** → MMCM 이산값(200 다음이 171/167/150) + reset/broadcast 잔여가 300에선 die 전역(−1.7~−1.94), 200에서 clean.
- **"max_fanout 복제가 기능을 바꾸나?"** → 아니다. attribute-only, iverilog 40/40 bit-exact. reset은 async-assert/sync-deassert로 스큐 0 투명. (DSP 모델에 initial 없어 X-leak까지 잡았다.)
- **"왜 2배 안 빨라지나?"** → in-CDMA(blocking) 72%가 100 MHz feed 도메인(클럭 무관) → 가속기 2×는 compute만 압축.
- **"phys_opt가 재현되나?"** → interactive 결과라 그 in-memory design에서 바로 write_bitstream하거나, impl strategy에 AggressiveExplore post-route phys_opt를 넣어야 함(안 넣고 impl 재실행 시 −0.098 복귀). ← 함정 언급하면 가산점.
- **"왜 dual-clock인가, 전체를 300으로 올리면?"** → MicroBlaze/AXI/MIG는 암호화 고정 IP라 −1 등급에서 200도 못 닫음(UG984 best 267, 같은 보드 tutorial 200 fail) → 가속기 datapath만 분리.
- **"XDC는 왜 손댔나?"** → 도메인 경계 경로를 STA가 기본 분석하면 가짜 violation이 떠서 timing이 안 닫힌다. 경계를 어떻게 볼지 알려줘 닫히게 + 데이터 무결성 보장(write-bus는 max_delay로 여전히 bound, async 선언은 금지).
- **"위상 정렬되면 동기화기는 왜 필요?"** → 위상 정렬은 *데이터 버스*엔 충분(그래서 BRAM은 common-clock 그대로). 동기화기는 ① 잔여 메타(지터/coincident-edge) resolve + ② **1-cycle 펄스가 빠른 클럭에서 N번 카운트되는 펄스-폭 문제**(후자가 핵심) 때문 → `cdc_pulse_sync`의 toggle 인코딩이 그걸 막음.

---

# 4. Additional (2) — Complex Winograd Convolution  〔담당: 김도현 — 본인 아이디어〕

### ① 한 줄 메시지
> "클럭은 MMCM 한계로 200MHz가 max → 다음 레버는 **알고리즘**. 점 집합 `{0, ±1, ±i, ∞}`의 **복소수 Winograd F(4×4,3×3)**로 Conv2 곱셈을 **144→46 (3.13×)**. 표준 실수 F(4,3)의 `1/24` 분수(=INT8 손실)를 **복소수로 회피**해 **direct conv와 bit-exact**. (Complex F(4,3) 유도까지가 본인 기여 — prior work는 있으나 이 INT8 무손실 구성은 독자.)"

### ② 발표 논리 (수학 → HW 순. 깊게.)

**(a) Winograd 기본 아이디어 (빠르게)**
- `2D: Y = Aᵀ[(G·g·Gᵀ) ⊙ (Bᵀ·d·B)]A`, ⊙ = element-wise(실제 곱셈 발생 위치).
- 배경: **CRT / Lagrange 보간**으로 다항식 곱을 적은 곱셈으로 — 점에서 평가(작은 곱) 후 보간으로 복원. (언급만 하고 빠르게.)
- `F(m,n)` 의미: m×m 출력, n×n 필터를 한 tile에 — 1D 곱셈 `m+n−1`, 2D `(m+n−1)²`.
- 2D 적용: `F(m×m, n×n)`. → 곱셈 절감률이 핵심 지표.

**(b) F(2,3)으로 감 잡기**
- `F(2×2,3×3)`: 2D 곱셈 36→**16 (2.25×)**. G 원소 `{0,±1,±½}` — ½ 하나뿐, INT8에서도 무난.
- 더 키우면(F(4,3)) 절감률↑ 이지만 **문제 발생** → 다음.

**(c) 표준 실수 F(4,3)의 문제**
- 점 `{0,±1,±2,∞}` → Lagrange 분모 `∏(αₖ−αⱼ)`가 불균일(거리 1,2,3,4) → **`1/24, 1/12, 1/6` 분수** 등장.
- **INT8 치명적**: `1/24`가 양자화 그리드에 안 떨어짐 → 누적 오차. (FP32는 무손실이지만 우리는 INT8.) → 표준 실수 F(4,3) **부적합**.

**(d) 해결 아이디어 — 보간 계수를 복소수로** (본인 핵심 기여)
- **관찰**: 4차 단위근 `{1,i,−1,−i}`는 서로 거리가 **모두 √2로 균일** → 분모가 깔끔한 `{1,4}`(2의 거듭제곱)만.
- 점 집합 `{0, 1, −1, i, −i, ∞}` (6점 = m+r−1 = 4+3−1).
- **켤레 대칭**(공짜 절감): 실수 입력/필터를 복소점에서 평가하면 `g(−i)=conj(g(i))`, `d(−i)=conj(d(i))` → `i`만 계산하면 `−i`는 켤레로 자동.
- **변환 행렬**(정정판, golden 검증):
  - **G** `{0,±1,±i}` (필터), **Bᵀ** `{0,±1,±i,±4}` (입력, ¼스케일 흡수), **Aᵀ** `{0,±1,±i}` (출력) — **전부 Gaussian integer, 곱셈기 0개**(시프트+부호+i-swap+×4).
  - ¼(2D는 1/16) 스케일은 weight가 아니라 **출력 shift**로 흡수 → `result = sat((Aᵀ·M·A) >> 14) = sat(Y>>10)` **= direct conv와 완전 동일값**.
- **결과**: G/B/A 정수 + 곱·누적 정수 + 출력 shift 정확 → **bit-exact**. (실수 F(4,3)의 1/24 반올림 문제를 복소수로 회피한 게 이 변환을 쓰는 유일한 이유.)

**(e) 곱셈 절감 정밀 계산**
- 1D: 실수점 4개(4 mul) + 켤레쌍 `{i,−i}` 1개(Gauss 3 mul) = **7 mul** (직접 12 → 1.71×).
- 2D 36점 분류: (real,real)16×1 + (real,cplx)4×3 + (cplx,real)4×3 + (cplx,cplx)2×3 = **46 mul** (직접 144 → **3.13×**).
- 핵심 통찰: `β=i` 차원이면 (real α, complex β)에서도 U,V가 복소수 → 그래서 복소 곱이 늘지만, 켤레+Gauss로 46에 수렴.

**(f) Gauss 복소수 곱셈 (4 mul → 3 mul)**
- `(a+bi)(c+di) = (ac−bd) + (ad+bc)i`.
- naive 4 real mul → **Gauss trick 3 real mul**:
  - `k₁=a(c+d)`, `k₂=c(b−a)`, `k₃=d(a+b)` → `Re=k₁−k₃`, `Im=k₁+k₂`.
- 이 3-mul이 복소점 곱셈마다 적용되어 46의 근거.

**(g) HW 매핑 — DSP 분배 (184 = 46 × 4)**
- 변환 모듈(입력 `Bᵀ·d·B` / 출력 `Aᵀ·M·A`)은 **곱셈기 0개**(adder/shift만).
- element-wise mul array만 DSP: **46-unit × IC=4 = 184 DSP** (utilization 100%).
  - 한 cycle: 4 IC × 46 = 184 mul → 한 (OC,tile) 8IC = 2 cycle → 16 OC × 36 tile = **1,152 cycle compute**.
  - Winograd는 변환 후 12-bit라 **SIMD packing 불가**(Aport 36-bit > 25-bit) → DSP 1개에 곱 1개.
- weight `U=G·g·Gᵀ` 사전계산(INT12, ~18KB, BRAM 1개).
- **2-파트가 한 세트**: conv2만 Winograd하면 conv1(1634)이 새 병목 → conv2 비는 DSP를 conv1에 줘(18→36) 1634→837. 그래야 conv2-wino(~1324)가 병목 되어 전체 효과.

**(h) 예상 성능 (이론)**
- bottleneck: 1798 → ~1324 cyc/img. @200MHz **~66–67 ms** (compute-only floor). DSP 238/240.
- **현재 상태**: golden(`scripts/golden_sim/1_complex_winograd_f(4,3).py`) **전체 10000장 bit-exact 완료**, RTL 미착수 → "이론상 이렇게 된다 + testbench cycle 수 → 클럭 환산 → ms" 로 마무리.

### ③ 핵심 수치/그림
- `144 → 46 (3.13×)` 대문짝. 점 집합 `{0,±1,±i,∞}` 복소평면 그림(거리 √2 균일). 1/24 분수 문제 vs Gaussian integer 표(6.1 비교표). Gauss 3-mul 박스. 46×4=184 DSP 분배 그림. bottleneck 변화 표(1798→1324, conv1 1634→837). 예상 66–67 ms.

### ④ 슬라이드 (가볍게)
- 슬라이드 1: "클럭은 끝났다 → 이제 곱셈 자체를 줄인다" + `144→46`.
- 슬라이드 2: **핵심 아이디어 한 장** — 복소평면 `{0,±1,±i,∞}` + "1/24 분수를 복소수로 회피 → INT8 bit-exact". (유도 디테일은 말로, 행렬은 부록.)
- 슬라이드 3: Gauss 3-mul + "46 mul" 한 장.
- 슬라이드 4: 184 DSP 분배 + conv1 rebalance + **예상 66–67 ms**.
- 행렬 전체/Lagrange 유도/비트폭 분석은 **부록 슬라이드**(질문 대비).

### ⑤ 예상 질문
- "왜 실수 F(4,3) 안 쓰고 복소수?" → 1/24 분수가 INT8에서 손실, 복소수는 분모가 {1,4}라 무손실.
- "복소수 곱이 더 비싸지 않나?" → 켤레 대칭 + Gauss 3-mul로 46에 수렴(직접 144 대비 3.13×).
- "왜 SIMD packing 못 쓰나?" → 변환 후 12-bit라 Aport 36-bit > 25-bit 한도.
- "prior work와 차이?" → Winograd/Lavin-Gray·복소 Winograd 개념은 있으나, **INT8 bit-exact를 위해 ¼을 출력 shift로 흡수하고 {0,±1,±i,±4}로 정수화한 이 구성**이 본인 기여. F(4,3) 도출·10000장 golden 검증까지 직접.
- "RTL 됐나?" → golden bit-exact 완료, RTL은 진행 예정(이론 성능 제시).

---

# 5. Conclusion

### ① 한 줄 메시지
> "병목을 측정→식별→제거하는 사이클로 **1079 → 98 ms (11×)**. 알고리즘(Complex Winograd)까지 가면 이론상 **~66 ms (16×)**."

### ② 발표 논리
- **발전 과정 재생**: baseline → inter-image → AXI-DMA → 150 → 200 → feed-overlap. 실측 보드 사진(1.74s → 0.68s → 0.18s 캡처)으로 "눈에 보이는" 진전.
- **각 단계가 다른 종류의 병목**이었다는 메시지: compute(SIMD/dataflow) → data movement(ping-pong/DMA) → clock(fanout/route) → algorithm(Winograd). **"매번 측정으로 다음 병목을 찾았다"**가 핵심 방법론.
- **Winograd if-then**: testbench cycle 수 → 클럭 환산 → **~66–67 ms 예상**. (구현 시 보드 최고 성능 목표.)
- **마무리 지표**: Power / WNS(slack) / DSP·BRAM·LUT utilization 표 1장.

### ③ 슬라이드 (가볍게)
- 슬라이드 1: 발전 과정 표/그래프(누적 배수) + 보드 사진들.
- 슬라이드 2: "4가지 다른 병목" 한 장 요약.
- 슬라이드 3: utilization/power/slack 표 + 한 줄 결론.

---

## 부록 (질문 대비, 슬라이드는 숨김)
- SIMD packing 비트 도출 / 2^24 exhaustive / WP486 비교.
- Winograd 행렬 정정판(§9.1), Lagrange 유도, 비트폭 분석(33-bit).
- overclock WNS 전 구간 로그 / silent-fail 분석 / iverilog 검증 명령.
- Block Design 단계별 빌드, CSR 메모리맵, 핸드셰이크 race 디버깅 노트.

---

### 출처 (이 개요의 근거 문서)
- `README.md` (마일스톤·아키텍처) / `docs/project_overview.md` (역할 분담·DSP 분배)
- `docs/overclock_journey_100_to_200mhz.md`, `docs/overclock_300mhz.md`, `docs/timing/`
- `docs/DSP48E1_signed8x8_SIMD_Packing.md`
- `docs/winograd/algorithm_complex_f43.md`, `docs/winograd/README.md`, `docs/winograd/conv2_winograd_design.md`
- `RTL/fc/fc_argmax.v` (4-round 토너먼트), `RTL/cnn_accelerator.v` (reset 복제 트리)
