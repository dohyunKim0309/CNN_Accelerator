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

### ② 발표 논리 — 4단계: ⓘ 도입 이유 → ⓘⓘ 도입 준비 → ⓘⓘⓘ 150 MHz까지 → ⓘⓥ 200 MHz까지

> 결과만 나열하지 말고 **"무엇이 병목이라 생각했다가 틀렸고, 측정으로 진짜 병목을 찾았는가"**의 추리물로. 아래 4블록 순서로 진행.

---
#### Ⅰ. 도입 이유 — "computational bottleneck이 다음 병목"
- 데이터 전송 병목(1·2장, 팀원)을 풀고 나면 가속기는 **compute-bound**: conv2 throughput floor ≈ **1798 cyc/img**가 wall-clock을 지배.
- compute 병목을 줄이는 길은 둘 — ① 연산량 자체 ↓(알고리즘 = Winograd, 4장) 또는 ② **같은 연산을 더 빠른 클럭에서**. 이 장은 ②.
- **핵심 이점**: cycle 거동을 그대로 둔 채 datapath 클럭만 올리면 100 MHz timer가 세는 wall-clock cycle 수가 그대로 줄어든다 → **firmware 완전 무변경**. (baseline 여기까지 = 2장 AXI+DMA, 100 MHz, **0.188 s**, 10000/10000.)

---
#### Ⅱ. 도입 준비 (오버클럭을 켜기 위한 사전 결정·인프라)

**(1) 왜 전체가 아니라 PL(가속기 datapath)만 올리나**
- MicroBlaze·AXI Interconnect·BRAM Ctrl·CDMA·UART는 **암호화된 고정 Xilinx IP** → 소스 못 고쳐 **재파이프라인 불가**. Artix-7 **−1(최저 속도등급)**에서 이들 Fmax는 300은커녕 200도 위태 (UG984 MicroBlaze best 267 MHz @캐시無; 같은 보드 tutorial **200 fail / 100 안전**; AXI UART PG142 최저등급 120 MHz).
- 게다가 workload가 **가속기-bound**(PS는 셋업·폴링만) → PS/AXI 올려도 추론 속도 이득 0, 전력만 ↑.
- → **결론: 가속기 datapath만 빠르게, 나머지(MB/AXI=100, MIG=81.25/200)는 유지, 경계에 작은 CDC.** (MIG는 원래 자기 `ui_clk` 도메인 + AXI converter라 blocker 아님.)

**(2) 초기 목표 = 300 MHz (3×)** — wall-clock ~1/3(~0.063 s) 기대로 출발. (결과적으로 200에서 닫힘 — 그 이유가 Ⅳ-(c).)

**(3) MMCM이란 + "188 MHz는 존재하지 않는다"**
- **MMCM(Mixed-Mode Clock Manager)** = 칩 내장 클럭 생성 하드웨어(clk_wiz IP가 감쌈). 입력 1개 → VCO(고주파) → 여러 출력 동시 생성(`출력 = VCO / 정수`), 모두 같은 VCO라 **위상 정렬**.
- 우리 clk_wiz는 `clk_out1=100` + `clk_out2=200`(MIG ref)이 **VCO를 고정** → 가속기용 `clk_out3`는 **정수 분주만** = **{200, 171.4, 166.7, 150…} 이산 집합**.
- → **188을 요청해도 200으로 스냅.** 임의 주파수 ❌. (요청클럭 ≠ 실제클럭이면 silent fail 가능 → **positive WNS @ slow corner**만 신뢰.)

**(4) Clock Wizard 설정** — `clk_out3`(가속기 clk) 추가, `clk_out1`=가속기 aclk(100) 재사용. 별도 300용 proc_sys_reset 불필요(내부에서 재동기화). **[발표: clk_wiz *Output Clocks* 탭 캡처 삽입]**

**(5) XDC 제약 — 왜 필요한가 (20초 포인트)**
- 도메인을 둘로 나누면 100↔datapath **경계 경로**가 생기는데, STA가 기본적으로 이걸 *목적지 클럭 1주기 안에* 닫으라 요구 → **멀쩡한 경로가 가짜 violation** → timing 안 닫힘(빌드 FAIL).
- → write-bus(100→datapath, 실데이터) `set_max_delay -datapath_only`(비정수비 1.9:1에도 비율 무관·안전; multicycle은 부적합), CDC 동기화기 입력(datapath→100) `set_false_path`. 데이터 무결성은 max_delay로 여전히 bound(async 선언 금지). **[XDC append 부분 캡처 삽입]**

**(6) CDC 코드 2개 — 역할 / 위치**
> 모든 CDC는 top `cnn_accelerator.v` **경계에만** 격리 → 엔진(conv1/2·maxpool·fc)·CSR·firmware 무변경. 신호 종류별로 처리가 갈린다.
- **`cdc_bit_sync` (2-FF, Level용)** — `enable`. 천천히 바뀌는 레벨 → **2-FF로 메타 resolve만**.
- **`cdc_pulse_sync` (toggle 인코딩 + 2-FF + XOR, Pulse용)** — `start`/`img_ready`(100→fast), `img_done`/`input_consumed`(fast→100, 양방향). 펄스를 toggle 레벨로 인코딩 → 2-FF 동기 → XOR로 1-cycle 복원. → **① 펄스 폭 문제(1-cycle이 빠른 클럭에서 N번 카운트 → 같은 이미지 N번/bank desync) + ② 메타**를 동시에 해결. (위상 정렬돼도 ①은 남아서 동기화기가 필요한 이유.)
- **위치 = 경계 5개 인스턴스**: 입력측 `u_enable_sync`(bit) / `u_start_sync` / `u_imgready_sync`(pulse), 출력측 `u_imgdone_sync` / `u_inputcons_sync`(pulse). **multi-bit 버스(BMG write)는 동기화기 불가 → (5) XDC가 담당.**
- **검증으로 CDC 무죄 확정**: 듀얼클럭 TB `tb_system_axi_multi_2clk` 10/10(3배카운트/펄스손실/데드락 없음) + `report_clock_interaction` → 이후 타이밍 문제는 전부 **datapath 내부(intra-clock)**로 좁힘.

---
#### Ⅲ. 150 MHz까지 — 300 시도 → 후퇴 → 150 closure (시간순)

> **시간순 사실**: 처음엔 300을 노렸다. 300이 안 닫혀서 **일단 안전한 150으로 후퇴**한 게 이 블록 — **300 포기 판단도 여기서 났다.** 각 단계의 "무엇이 임계였나" 근거 로그는 `docs/timing/`(옵시디언 링크).

**(a) (착수 전) FC argmax + conv1 adder — 100 MHz에서도 −8.6 ns**  → 근거: [[01_pre-pipeline_wns-8.6.png]]
- 10-class argmax 1-cycle 조합(24-bit 비교기 **9단 직렬**) + conv1 9입력 가산이 1-cycle → **setup −8.6 ns @100 MHz** (클럭 올리기는커녕 100도 위험).
- 해결: argmax → **4-round 토너먼트**(`10→5→3→2→1`, stage = 비교 1개 + 2:1 mux), conv1_adder_tree 1→4-stage. tie-break(낮은 인덱스 우선) **기존 combinational과 bit-exact 동일**(`RTL/fc/fc_argmax.v`). → 이 정지작업 먼저 닫고 클럭 인상 시작.

**(b) 300 1차 시도 — conv2 broadcast fanout (route 지배)**  → 근거: [[02_300mhz_conv2-broadcast_wns-2.99.txt]]
- 300 합성 **WNS −2.99**, 전부 datapath intra-clock. 워스트 **route 86% / logic 14%**, DSP None → **연산이 아니라 배선 거리 문제**.
- 원인: 제어/weight broadcast(`state`/`sel`/`pe_en`/`packed_w`)가 **192 PE로 fanout**, DSP **226/240=94%**라 die 전역 → die-spanning.
- 레버 누적: `max_fanout=32` + `phys_opt AggressiveFanoutOpt` → **−2.454** [[03_300mhz_step1-replication_wns-2.454.png]] → Step1b(weight +1reg) + Step2(`PE_BC_DELAY` PE입력 파이프) + weight_loader nested-mul→accumulator(조합깊이 6→1) → **−2.187** [[03_300mhz_step1b-step2_wns-2.187.png]] (weight-load 격리 실험 [[03_300mhz_weightreg-falsepath-isolation.txt]]). iverilog **40/40 bit-exact**(N=0→1798/1→1799/2→1800 cyc/img).

**(c) 300 포기 결정 — 왜 (정직한 ROI 판단)**
- broadcast를 닫아도 워스트엔 **reset net −1.94** + **OTHER 다전선 tier −1.6~−1.7**(FC FSM `pair_cnt`/`s_cnt`→state, conv2 `state`→pe_x, broadcast 잔여→DSP, `rdone`→conv1 handshake)가 **die 전역**으로 남는다.
- 이들 경로의 **물리 지연 ≈ 5.0~5.5 ns** = **≈190~200 MHz급**. 300(3.33 ns)으로 닫으려면 이 **무리 전부를 각 ~1.7 ns씩 더** 내려야 하는데, **DSP 94%라 floorplan 여지 없고**(placer가 클러스터 못 모음) 각 fix가 FC FSM 재설계·handshake 재구성처럼 침습적 → **비현실적 ROI**.
- → **결정: 300 보류, 일단 클럭을 낮춰 깨끗이 닫자.** (★주의: reset이 die 전역이라 "**못 푼다**"가 아니라 — *300까진* 못 내린다는 판단. 200에서 reset은 **실제로 푼다** = Ⅳ. 이 구분이 다음 블록의 핵심.)

**(d) 150 closure — 왜 150은 그냥 닫히나 (핵심 직관)**
- die-spanning 경로엔 **고정 물리 지연**(≈5.0~5.5 ns). **150 = 6.67 ns 주기**라 이 경로들이 **추가 묘수 없이 그냥 fit** → clean, **HW 10000/10000, 0.128 s**(`150MHz_result.png`).
- 이 "**물리 지연(≈5 ns) vs 클럭 주기**" 프레임이 전부를 설명: 150(6.67) 여유 / 200(5.0) 빠듯(reset만 짧게 하면 닫힘) / 300(3.33) 전 tier 못 내림. → 다음 블록 = 이 5 ns tier를 **5.0 ns 밑으로** 내리는 싸움.

---
#### Ⅳ. 150 → 200 MHz — 5 ns tier를 5.0 ns 밑으로 (상세)

> 200 = **5.0 ns 주기**. 150에서 그냥 fit하던 ≈5 ns die-spanning 경로들이 이제 **빠듯하게 위반**. 워스트부터 하나씩 **양파 까듯**(측정 → 복제/파이프 → 재측정) 닫는다.

**(a) 워스트 = reset net → 복제 트리**  → 근거: [[05_200mhz_reset-tree_wns-0.154.txt]]
- reset `rst_sync_reg → BUFG → (fanout 41323) → DSP/RSTB·register` **−1.94, route 85%, 1343 endpoints, die 전역**. 한 net이 datapath 전 register(~41k)로 직접 fanout → BUFG 글로벌 라우팅으로 die 끝까지 너무 김.
- **tie-0(reset 제거) 기각**(기능 거동 바뀜·X-leak 검증 부담·fragile) → **reset 복제 트리 채택**(분배 구조만 바꿈, 기능 완전 불변):
  ```verilog
  (* max_fanout = 32  *) reg rst_l1;    // trunk (few copies)
  (* max_fanout = 128 *) reg rst_leaf;  // leaf → datapath (대량 복제)
  ```
  합성이 `rst_sync(1)→rst_l1(~11)→rst_leaf(~323)→datapath(~41k)` 트리 자동 생성 + leaf를 **cluster 근처 배치** → 긴 high-fanout net이 **짧은 local net 다수**로 쪼개짐(BUFG 불필요). async-assert/sync-deassert라 스큐 0·기능 투명.
- 결과: **reset −1.94 완전 소멸** → WNS **−0.154**. 새 워스트는 전혀 다른 곳(`wl_inst/pe_id → pe_load_en_dec_r/R`, route 82%, weight-load 디코드).

**(b) 양파 까기 — 워스트 하나 닫으면 다음이 노출** (단계별 원인 + 로그)

  | 단계 | WNS | Failing | 새 워스트 (무엇이 임계였나) | 조치 | 근거 로그 |
  |---|---|---|---|---|---|
  | reset 트리 | **−0.154** | 44 | wl `pe_id → pe_load_en_dec` (route 82%) | 다음 phys_opt가 닫음 | [[05_200mhz_reset-tree_wns-0.154.txt]] |
  | + phys_opt default | **−0.102** | 31 | conv2 `state → shift_en → far-ic lb2 mem CE` (route 86%) | default **plateau** | [[06_200mhz_physopt-plateau_wns-0.102_lb2-CE.txt]] |
  | + `shift_en` max_fanout | **−0.098** | 1 | (lb2 클러스터 닫힘, straggler 1) | `(*max_fanout=16*) wire fsm_shift_en` → 31→1 | — |
  | + phys_opt `AggressiveExplore` | **+0.011** | **0** | — | directive로 plateau 돌파 → **MET ✅** | [[07_200mhz_MET_wns+0.011.txt]] |

- **`shift_en` 디테일**: conv2_fsm 조합 출력 `shift_en`이 8 ic line_buffer/window CE로 die 전역 broadcast(`line_buffer.mem`이 FF 합성 → CE=`shift_en&(ptr==addr)`, LUT3+LUT6 2단). `state`/`kw_cnt`엔 있던 `max_fanout`이 **`shift_en`만 빠져 있었음** → 한 줄로 31→1.
- **phys_opt 재현성 함정**: `AggressiveExplore`는 **interactive 결과** → 그 in-memory design에서 바로 `write_bitstream`하거나 impl strategy에 post-route phys_opt를 넣어야 함(안 넣고 impl 재실행 시 −0.098 복귀).

**(c) 검증 & signoff**
- iverilog `tb_cnn_accelerator_multi` 40/40 + `tb_system_axi_multi` 10/10 bit-exact (전부 attribute-only/복제라 기능 불변).
- ★ `dsp48e1_model.v`에 `initial`이 없어 reset 변경의 X를 **실제 전파**해 잡는다 → bit-exact PASS = **X-leak 0** = HW(GSR=0)는 더 안전.
- **+0.011 = positive WNS @ slow(signoff) corner = 정식 MET** (요청클럭≠실제클럭으로 음수인데 통과하는 빌드와 근본적으로 다름).

**(d) 결과 & 왜 정확히 2×가 아닌가**  → HW 실측: [[08_200mhz_HW-result_10000of10000_108.9ms.txt]]
- **150: 0.128 s → 200: 108.9 ms**(10,896,290 cyc, WNS +0.011) → **+ Vitis feed-overlap: 98 ms**(9,799,994 cyc, in-CDMA 56%). baseline 0.188 s 대비 **1.72×**.
- **2×가 아닌 이유**: profile상 **in-CDMA(blocking) 72%**(7.9M cyc)가 **100 MHz feed 도메인**(가속기 클럭 무관) → 가속기 2×는 **compute slice만** 압축. **floor = CDMA feed** → ① feed overlap(이미 98 ms로 일부 회수), ② **Complex Winograd**(4장, compute 자체를 줄여 feed 푼 뒤 효과).

### ③ 핵심 수치/그림 (자료는 이미 repo에 있음)
- **WNS 진행 표**: −2.99 → −2.454 → −2.187 → (reset)−0.154 → −0.102 → −0.098 → **+0.011**.
- **route% vs logic% 막대**(86% vs 14%) — "배선이 문제" 한 장.
- **fanout 41323 → 복제 트리**(rst_sync→l1→leaf→41k) 그림.
- reset/shift_en **`max_fanout` 한 줄** 코드 스니펫.
- argmax **9단 직렬 → 4-round 토너먼트** 그림.
- 실측 캡처: `150MHz_result.png`(128 ms), `200MHz_result_vitis_optimize.png`(98 ms).
- **단계별 근거 로그(옵시디언)**: [[docs/timing/README]] 표 + 각 단계 — [[01_pre-pipeline_wns-8.6.png]] · [[02_300mhz_conv2-broadcast_wns-2.99.txt]] · [[03_300mhz_step1-replication_wns-2.454.png]] · [[03_300mhz_step1b-step2_wns-2.187.png]] · [[05_200mhz_reset-tree_wns-0.154.txt]] · [[06_200mhz_physopt-plateau_wns-0.102_lb2-CE.txt]] · [[07_200mhz_MET_wns+0.011.txt]] · [[08_200mhz_HW-result_10000of10000_108.9ms.txt]]. (참고 — silent-fail 의심 빌드: [[04_200mhz_earlier-build_wns+0.04_silent-fail-suspect.png]].)

### ④ 슬라이드 (가볍게 — 5장 + 백업)
- **S1**: "클럭만 올리면 firmware 무변경으로 빨라진다" + `187 → 108.9 → 98 ms` 화살표.
- **S2 (이 장의 한 장)**: **"이 칩의 벽 = route delay(배선 거리), 해법 = `max_fanout` 복제"** + route 86% 막대 + reset 복제 트리 그림.
- **S3**: WNS 진행 표(한 줄씩 애니메이션) → **+0.011 MET**.
- **S4**: argmax 9단 직렬 → 4-round 토너먼트(Ⅲ-a, 150 이전 정지작업, 작은 임팩트 카드).
- **S5**: 실측 사진 2장 + "왜 1.72×인가 = CDMA feed 72%".
- **말로만**: Ⅱ-(6) CDC 무죄, Ⅱ-(3) MMCM 스냅 훅("188은 존재하지 않았다"). **Ⅲ-(c) 왜 300 포기**는 백업 1장(Q&A 대비). 시간 빡세면 S4는 한 문장.

### ⑤ 예상 질문 (Q&A 대비)
- **"왜 300이 아니라 200? reset 풀었으면 300도 되지 않나?"** → Ⅲ-(c)·Ⅳ-(a) 참고. reset 트리는 reset을 **5.0 ns(200) 밑으로** 내린 것이지 3.33 ns(300)가 아님 + reset은 최악 하나일 뿐, 그 아래 FC FSM/conv2 제어→DSP/handshake 등 **~5 ns die-spanning 무리**(="~200 벽")가 더 있음. 300은 그걸 전부 침습적으로 더 내려야 하고 DSP 94%라 floorplan 불가 → ROI 붕괴 → Winograd로 전환.
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
