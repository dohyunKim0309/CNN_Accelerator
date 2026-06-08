# CNN Accelerator — 발표 개요 (Deep Outline)

> **원칙**: 개요(이 문서)는 딥하게, **PPT 슬라이드는 가볍게**.
> 각 섹션은 `① 한 줄 메시지 → ② 발표 논리(대본) → ③ 핵심 수치/그림 → ④ 슬라이드(가볍게) → ⑤ 예상 질문` 구조.
> **담당**: 0 · 3 · 4 = 김도현 / 1 · 2 = 공동(엔진별 담당자)
>
> **전체 관통 서사**: "MNIST 1만 장 분류 **end-to-end latency** 최소화"라는 단일 목표 아래,
> **병목을 측정 → 식별 → 제거**하는 사이클을 4번 돈다.
> `Compute 병목 → Dataflow(전송) 병목 → Clock 병목 → Algorithm 병목`.
> 매 단계 "**무엇이 새 병목인지 측정으로 확인**"하는 게 이 프로젝트의 방법론.

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
- **평가 지표(1순위)**: 단일 이미지 latency가 아니라 **1만 장 end-to-end** — PS→PL 전송, BRAM I/O, batch 누적까지 포함. → 이게 뒤의 모든 최적화 방향을 결정한다 (여기서 못 박아두면 1·2·3·4 전부 같은 자(尺)로 이야기됨).
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

# 1. Computational Bottleneck and Solutions  〔공동〕

### ① 한 줄 메시지
> "연산량의 **90%가 Conv2**. DSP 240개 예산 안에서 Conv2를 채우려면 **DSP 한 개로 INT8 곱셈 2개**(SIMD packing) + **PE를 놀지 않게 하는 dataflow**가 필요하다."

### ② 발표 논리
- **병목 측정**: MAC 분포 — Conv1 6.6% / **Conv2 90.2%** / FC 3.1%. → Conv2가 throughput floor.
- **DSP 예산 문제**: Conv2를 `oc×ic×K` 풀언롤하면 DSP 부족. → 해결책 **SIMD packing**.
- **핵심 기여 — DSP48E1 signed 8×8 SIMD packing**:
  - 단일 25×18 multiplier로 `P = (W1·2^17 + W0)·X` → 한 번에 `W0·X`, `W1·X` 두 곱.
  - **차별점**: `-128` 포함 **모든 2^24 조합 bit-exact**. 오버플로우(`W1=-128 ∧ W0<0`)를 `-256·X` **산술 보정**(분기 없는 단일 경로)으로 처리.
  - 선행연구 대비 우위: Xilinx WP486은 DSP48E2(27-bit) 전용, Vestias(FPL'17)는 -128 손상. **본 알고리즘은 좁은 DSP48E1(25-bit)에서 무손실** → 2^24 exhaustive 검증.
- **Dataflow paradigm — Weight/Output Stationary, Activation Flowing**:
  - Weight: PE-local register에 1회 적재 후 inference 동안 고정.
  - Psum: 16 OC × 24-bit accumulator (K_col 3-cycle 누적).
  - Activation: BRAM → line buffer → window → PE 스트리밍.
  - → 매 cycle PE가 일하도록(95%+ utilization) 채우는 게 목적.
- **결과**: Conv2 192 DSP, ~1728–1798 cyc/img. DSP 총 ~228/240.

### ③ 핵심 수치/그림
- MAC 파이 차트(Conv2 90%). SIMD packing `Aport = W1·2^17 + W0` 그림 1장. Stationary dataflow 그림. DSP 분배 표.

### ④ 슬라이드 (가볍게)
- 슬라이드 1: MAC 90% 파이 + "Conv2가 병목".
- 슬라이드 2: SIMD packing 1장(수식 1줄 + "DSP 1개로 곱셈 2개, -128도 정확").
- 슬라이드 3: dataflow 그림 1장.
- 증명/비트 도출은 **부록**으로 빼고 말로 "exhaustive 검증" 한마디.

### ⑤ 예상 질문
- "왜 SIMD가 필요?" → DSP 240 한도 안에 Conv2를 넣기 위해.
- "-128이 왜 문제?" → 25-bit 범위 초과 1케이스, 보정 안 하면 틀림.

---

# 2. Dataflow Bottleneck and Solutions  〔공동〕

### ① 한 줄 메시지
> "Conv2를 빠르게 만들자 **데이터를 나르는 게** 새 병목. (a) stage 간 **ping-pong BRAM**으로 가속기 idle 제거, (b) PS→PL을 **AXI burst + DMA**로 교체 → 587→187 ms."

### ② 발표 논리
- **병목 이동**: compute를 채우고 나니 ① stage 간 대기, ② PS→PL 전송이 새 병목.
- **(a) Inter-image Pipelining (1079→586)**:
  - 한 이미지가 끝나기 전 다음 이미지를 적재. stage 사이 **2-bank ping-pong BRAM**(`c1_to_c2`/`c2_to_pool`/`pool_to_fc`)으로 producer/consumer 분리 → 가속기 노는 구간 제거.
  - 양방향 핸드셰이크(write_done/read_done pulse + bank_sel toggle), 중앙 컨트롤러 없음.
- **(b) AXI Burst + DMA (586→187)**:
  - 프로파일 결과 **PS→PL word 단위 전송**이 병목 → AXI burst + CDMA로 교체.
  - `input_consumed` **backpressure**로 PS write와 PL compute **오버랩**.
- **결과**: 586 → 187 ms (baseline 대비 5.77×). 이후 floor = **CDMA feed**(100MHz 도메인) → 3장 오버클럭의 "왜 2×가 안 나오나"로 연결.

### ③ 핵심 수치/그림
- ping-pong 타이밍 다이어그램(producer/consumer 겹침). AXI burst 전/후 전송 그림. 586→187 화살표.

### ④ 슬라이드 (가볍게)
- 슬라이드 1: ping-pong 그림 + "idle 제거 1079→586".
- 슬라이드 2: AXI burst+DMA 그림 + backpressure 한 줄 + "586→187".

### ⑤ 예상 질문
- "DMA 도입 후 남은 병목?" → CDMA feed(100MHz), 3장에서 다룸.

---

# 3. Additional (1) — Overclock  〔담당: 김도현〕

### ① 한 줄 메시지
> "같은 RTL을 **더 빠른 클럭**에서 돌리면 firmware 무변경으로 latency가 준다. 단 이 칩의 벽은 **로직 깊이가 아니라 die 전역으로 퍼지는 high-fanout net의 route delay** — 해법은 재설계가 아니라 **`max_fanout`으로 driver를 클러스터 근처에 복제**하는 것. 100→**200 MHz**, 187→**98 ms**."

### ② 발표 논리 (이 장이 당신 색깔이 가장 진한 곳 — 디버깅 서사로)

**(a) 왜 오버클럭인가 / 무엇을 안 건드리나**
- 가속기 cycle 거동은 그대로 두고 클럭만 올리면 **wall-clock cycle 수가 줄어든다**(100MHz timer가 세는 값이 감소). **firmware 무변경**.
- 선행 작업 **dual-clock CDC**: PS/AXI(100MHz)와 datapath(빠른 클럭) 분리.
  - `enable`=2-FF level sync, `start`/`img_ready`=**toggle 동기화**(빠른 클럭에서 pulse가 N-cycle로 N배 카운트되는 것 방지).
  - XDC: write-bus는 `set_max_delay -datapath_only`(비정수 클럭비에서 multicycle 부적합 → max_delay가 안전), 반대 방향 `set_false_path`.
  - 듀얼클럭 TB(`tb_system_axi_multi_2clk`) 10/10 + `report_clock_interaction` → **"CDC 무죄" 일찌감치 확정** → 이후 디버깅을 datapath 내부에만 집중.

**(b) MMCM 함정 — "188 MHz는 존재하지 않는다"** (스토리의 반전 포인트)
- clk_wiz의 `clk_out1=100`+`clk_out2=200`(MIG ref)이 **VCO를 고정** → `clk_out3`는 정수 분주만(200/171.4/166.7/150…)의 **이산 집합**.
- **188을 요청해도 200으로 스냅** → 나중 silent fail의 빌미.
- **버린 가설(정직한 기록)**: "오버클럭해도 latency 안 줄어든다 = feed-bound" 라고 한때 결론냈으나, 그 "200MHz 빌드"가 **실은 silently fail한 빌드**(188→200 스냅 + reset 위반으로 핸드셰이크 깨짐)였을 가능성. → **깨진 빌드끼리 비교**라 확정 불가 → 결론 폐기, 확실한 사실(150MHz 동작)만 남김.
- **교훈**: 측정 전에 그 빌드가 **timing-clean(positive WNS @ slow corner)** 인지 먼저 봐라.

**(c) 100→150 — Conv2 broadcast fanout**
- 300MHz 1차 합성 WNS **−2.99**, 전부 `clk_out3→clk_out3`(datapath intra-clock). 워스트 path **route 86% / logic 14%** → **로직 깊이 아님, 배선 거리 문제**.
- 원인: 제어/weight broadcast(`state`/`sel`/`pe_en`/`packed_w`)가 **192 PE로 fanout**. DSP 226/240=94% → PE가 die 전역 DSP 컬럼에 깔림 → broadcast가 **die-spanning**. DSP 위치 고정이라 floorplan 불가 → **파이프라인 + 복제**가 유일 레버.
- 레버(누적): `max_fanout=32`(state/kw_cnt) + weight bc +1reg + `PE_BC_DELAY` PE입력 파이프 + weight_loader nested-multiply→accumulator(조합깊이 6→1). → **150MHz 깨끗이 닫음, HW 10000/10000**.

**(d) 150→200 — reset fanout** (본편)
- 남은 워스트 = **단일 reset net** `rst_sync → BUFG → (fanout 41323) → DSP/register`, **−1.94, route 85%, die 전역**.
- 선택: **tie-0 기각**(기능 바꿈, fragile) → **reset 복제 트리 채택**(분배 구조만 변경, 기능 완전 불변).
  ```verilog
  (* max_fanout = 32  *) reg rst_l1;   // trunk
  (* max_fanout = 128 *) reg rst_leaf; // leaf → datapath
  ```
  - 합성이 `rst_sync(1)→rst_l1(~11)→rst_leaf(~323)→datapath(~41k)` 트리를 자동 생성, 각 leaf 복제본을 **cluster 근처 배치** → 긴 net이 짧은 local net 다수로 쪼개짐(BUFG 불필요).
  - async-assert/sync-deassert 유지 → leaf끼리 상대 스큐 0, 기능 투명.
- **양파 까기**: reset 닫으니 다음 워스트 노출 → conv2 `shift_en` max_fanout(line buffer CE) → 마지막 한 끗 **`phys_opt_design -directive AggressiveExplore`**로 −0.098 → **+0.011 (0 failing) MET**.

**(e) FC argmax — "합성기가 10단 직렬 비교기로 풀어버린다"** (당신 브레인덤프 포인트)
- FC 끝단 10-class argmax를 **1-cycle combinational 10-way 비교**로 짜면, 24-bit 비교기 **9단이 직렬**로 합성 → 100MHz에서도 setup 위반(−8.6ns), 200MHz는 불가능.
- **해결: 4-round 파이프라인 토너먼트** `10→5→3→2→1`, round마다 register. 각 stage critical path = "24-bit 비교 **1개** + 2:1 mux" 만 남김.
- tie-break: left가 항상 더 낮은 인덱스가 되도록 페어링 + strict `>` → "낮은 인덱스 우선", **기존 combinational과 bit-exact 동일**(`RTL/fc/fc_argmax.v`).

**(f) 결과 & 왜 정확히 2×가 아닌가**
- 150MHz **0.128s** / 200MHz **108.9 ms**(10,896,290 cyc, WNS +0.011 = 정식 signoff) / + Vitis feed-overlap **98 ms**.
- baseline(100MHz @ AXI-DMA) 0.188s 대비 **1.72×**. **2×가 아닌 이유**: profile에서 in-CDMA(blocking) **72%**가 100MHz feed 도메인(클럭 무관) → 가속기 2×는 compute slice만 압축. **현재 floor = CDMA feed** → 다음 레버는 feed overlap, 그 다음이 Winograd.

### ③ 핵심 수치/그림
- WNS 진행 표(−2.99 → −2.454 → −1.94 → … → +0.011). route% vs logic% 막대. fanout 41323 → 복제 트리 그림. argmax 9단 직렬 → 4-round 토너먼트 그림. 타이밍 리포트 캡처(`docs/timing/`, `150MHz_result.png`, `200MHz_result_vitis_optimize.png`).

### ④ 슬라이드 (가볍게)
- 슬라이드 1: "클럭만 올리면 firmware 무변경으로 빨라진다" + 187→98 화살표.
- 슬라이드 2: **핵심 한 장** — "이 칩의 벽 = route delay(배선 거리), 해법 = `max_fanout` 복제" + route 86% 막대 + 복제 트리 그림.
- 슬라이드 3: WNS 진행 표(애니메이션으로 한 줄씩) → +0.011 MET.
- 슬라이드 4: argmax 9단→4-round 그림(작은 임팩트 카드).
- MMCM/silent-fail 서사는 **말로** (시간 되면 한 슬라이드, "188은 존재하지 않았다" 훅).

### ⑤ 예상 질문
- "왜 300이 아니라 200?" → MMCM 이산값 + reset/broadcast 잔여가 300에서 die 전역, 200에서 clean.
- "max_fanout 복제가 기능을 바꾸나?" → 아니다, iverilog 40/40 bit-exact + reset은 async-assert/sync-deassert로 투명.
- "왜 2배 안 빨라지나?" → CDMA feed 72%가 100MHz 도메인.
- "phys_opt가 재현되나?" → interactive 결과라 strategy에 AggressiveExplore 넣어야 재현(함정 언급하면 가산점).

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
