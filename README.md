# CNN Accelerator

> Arty A7-100T FPGA 보드 위에서 동작하는 MNIST CNN 추론 가속기.
> Conv1 → Conv2 → MaxPool → FC 파이프라인을 INT8 데이터패스로 구현한다.
> Direct baseline 은 200MHz 로 timing closure 하여 MNIST 1만 장을 **10,000/10,000 정확도, 약 98ms**
> 에 보드 실측 완료했다. 추가로 Conv2 complex Winograd F(4,3) + DSP48E1 SIMD packing 가속 버전을
> 설계해 시뮬레이션 bit-exact 검증과 두 동작점(171.42 / 200MHz) timing closure 를 마쳤다
> (보드 실측은 제출 마감 이후 확정되어 latency 는 추정).

**수업**: 지능형시스템설계및응용

**팀원**: 김도현, 김동주, 신지민

---

## 1. 프로젝트 목표

본 프로젝트는 **MNIST 손글씨 분류 CNN** 을 FPGA 상에서 가속하는 IP 를 설계하는 것을 목적으로 한다.
PS (Processing System) 은 데이터 전송과 start/done 제어만 담당하며, 모든 추론 연산은 PL (Programmable Logic) 의 가속기 IP 내부에서 수행된다.

### 타겟 네트워크

```
Input (1, 28, 28) INT8
  ↓ Conv1 (8, 1, 3, 3), stride 1, no pad
Feature Map1 (8, 26, 26)
  ↓ ReLU
  ↓ Conv2 (16, 8, 3, 3), stride 1, no pad
Feature Map2 (16, 24, 24)
  ↓ ReLU
  ↓ MaxPool 2×2
Feature Map3 (16, 12, 12)
  ↓ Flatten (W, H, C order) → 2304
  ↓ FC (2304, 10)
Output Logit (10) → argmax
```

### 설계 제약

- **보드**: Arty A7-100T (Xilinx XC7A100T)
- **자원 한도**: DSP48E1 240 개, BRAM 135 (4.6 Mb), LUT 63K, FF 126K
- **데이터 타입**: Weight / Activation 모두 signed INT8
- **양자화 규칙**: 누적 후 LSB 10 bit 산술 우측 시프트 → ±127 saturation → INT8 출력

### 평가 지표 (우선순위 순)

1. **End-to-end Latency (최우선)** — **MNIST 1만 장 이미지 분류에 걸리는 총 시간**. 이 값을 최소화하는 것이 본 프로젝트의 1순위 목표
2. **Power (소비 전력)** — on-chip power
3. **Resource (자원 사용량)** — DSP / LUT / FF / BRAM

> 단일 이미지 latency 뿐 아니라 PS-PL 데이터 전송, BRAM 입출력, 1만 장 batch 전체에 걸친 누적 시간을 모두 고려한 end-to-end 시간이 평가 기준이다.

### 현재 상태 (2026-06-22)

- **Direct baseline — 보드 실측 완료**
  - 200MHz timing closure (WNS **+0.011 ns** @ slow corner)
  - MNIST 10,000장 정확도 **10,000 / 10,000**
  - end-to-end latency **약 98 ms** (순차 baseline 1,197 ms 대비 누적 **12.2×**, 전 단계 보드 실측)
  - DSP **226 / 240 (94%)** = Conv2 192 + Conv1 18 + FC 16
- **Winograd 버전 — 시뮬레이션 검증 + timing closure 완료, 보드 실측 미수행**
  - Conv2 complex Winograd F(4×4, 3×3) (Conv2 곱셈 직접 conv 대비 **3.13×** 감소) + Conv1 2× rebalance
  - top-module TB **bit-exact 100/100** (avg 1,341 cyc/img)
  - implementation **두 동작점 timing-met**: 171.42MHz robust (WNS +0.180) / 200MHz tight (WNS +0.050, over-constrain)
  - DSP **236 / 240 (98.33%)** = Winograd 184 + Conv1 2× 36 + FC 16
  - 200MHz closure 가 보드 제출 마감 이후 확정 → **보드 실측 미수행**. latency 는 cycle + baseline feed 오버헤드(~8 ms) 기반 추정 **~86 ms (171.42MHz, ~13.9×) / ~75 ms (200MHz, ~16.0×)**

> 다음 병목은 연산이 아니라 **PS-PL feed** 다 — 클럭을 2배로 올려도 latency 가 1.72× 만 줄어든 것은 전체 시간의 72% 가 입력 전송에 묶여 있기 때문이며, Winograd 의 연산 이득을 온전히 얻으려면 feed overlap 이 선행되어야 한다.

---

## 2. 로드맵

프로젝트는 단계별 마일스톤으로 진행된다. 각 단계는 직전 단계의 hardware/software 인프라를 그대로 재사용하며 누적적으로 발전한다.

### Phase 0 — Sobel Baseline (완료)

`archive/` 에 위치. 102×102 grayscale 이미지에 대한 3×3 Sobel edge detection IP. CNN 가속기를 위한 기본 인프라(Line buffer + 3×3 window register, AXI CSR 슬레이브, BRAM Port A/B 분리, PS-PL 데이터 전송 프로토콜) 를 검증하는 단계.

### Phase 1 — INT8 Direct CNN Accelerator (완료)

`RTL/` 에서 본격적으로 시작. 명세 그대로의 INT8 Direct Convolution 으로 전체 파이프라인을 구현하고, 1만 장 처리 latency 의 기준선(baseline) 을 확보한 단계.

- Output Stationary + Weight Stationary 데이터플로우 채택
- DSP48E1 SIMD packing 으로 1개 DSP 가 INT8 곱 2개를 동시 수행 (출력 채널 pair 단위)
- Conv1: `K(9) × OC_pair(2) = 18 DSP` (8 출력채널을 2 round 로 시분할)
- Conv2: `OC_pair(8) × IC(8) × K_row(3) = 192 DSP` ← 전체 곱셈의 90% 차지
- FC: `16 DSP` → 합계 **226 / 240 DSP (94%)**
- 채널별 line buffer + window register 로 streaming 처리
- 200MHz post-implementation timing closure (WNS +0.011 ns) 및 보드 검증 완료
- baseline 실측: **200MHz, MNIST 10,000장 약 98 ms, 10,000/10,000**

### Phase 2 — Winograd Conv2 가속 (설계·검증·timing closure 완료, 보드 실측 미수행)

Conv2 가 전체 곱셈의 90% 를 차지하는 병목임을 확인했으므로, complex F(4,3) Winograd 변환으로 Conv2 의 multiply 수를 직접 conv 대비 **3.13×** 줄였다. 이로 인해 이동한 병목은 Conv1 2× rebalance 로 맞췄다.

- 8×8 INT8 SIMD packing 알고리즘은 `docs/DSP48E1_signed8x8_SIMD_Packing.md` 에 정리
- 알고리즘 reference 구현은 `scripts/golden_sim/1_complex_winograd_f(4,3).py` (10,000장 bit-exact)
- Winograd RTL 은 `RTL/conv2_winograd/`, `RTL/conv1_2x/`, 설계 문서는 `docs/winograd/`
- top-module TB **100/100 bit-exact** (avg 1,341 cyc/img), Conv1 2× gate 40/40 bit-exact
- implementation **두 동작점 timing-met** (171.42MHz WNS +0.180 / 200MHz WNS +0.050, over-constrain), DSP **236/240 (98.33%)**
- 200MHz closure 가 보드 제출 마감 이후 확정되어 **보드 실측 미수행** — latency 추정 **~86 ms / ~75 ms**

### Phase 3 — 최적화

1만 장 batch 의 end-to-end 시간을 더 줄이기 위한 추가 pipelining, PS-PL 전송 오버랩, 메모리 access pattern 개선 등.

---

## 3. 시스템 아키텍처 (Block Design)

전체 시스템은 Vivado Block Design 상에서 다음과 같이 구성된다. Microblaze 가 PS 역할을 담당하며 AXI Interconnect 를 통해 BRAM Controller, CSR, 디버그용 Uartlite 와 연결되고, CNN 가속 본체는 `cnn_accelerator` 내부에 모두 들어간다.

```
Block Design (Vivado GUI)
├── Microblaze (D-cache enabled)
├── AXI Interconnect
├── Clocking Wizard
├── Processor System Reset
│   ├── ext_reset_in ← 외부 버튼 (BTN0)
│   ├── dcm_locked   ← Clocking Wizard.locked
│   └── peripheral_aresetn → 모든 AXI peripheral reset
│       ├── CSR_AXI.S_AXI_ARESETN
│       ├── BRAM Controller × 4의 reset
│       └── cnn_accelerator.reset (자체 reset port 만들어서)
├── AXI BRAM Controller × 4
│   ├── input_bram_ctrl
│   ├── conv1_w_ctrl
│   ├── conv2_w_ctrl
│   └── fc_w_ctrl
├── AXI Uartlite (debug)
└── Custom IP
    ├── csr_slave_axi_inner (수정 버전)
    └── cnn_accelerator
        ├── conv1_engine (Direct conv, DSP+LUT mult)
        │   ├── input_bram (BRAM × 2 bank)
        │   ├── conv1_w_bram
        │   └── pe_array  ※ core (line_buffer, window_register, pe_cell, truncate_relu) 인스턴스화
        ├── conv2_engine / conv2_winograd_engine (Direct / Winograd 변형, 동일 module 명 상호배타)
        │   ├── conv2_w_bram (Direct baseline)
        │   ├── wino_weight_bram (PS 가 pre-transform 한 U 를 적재)
        │   └── pe_array 또는 Winograd datapath
        ├── maxpool_engine
        ├── fc_engine
        │   ├── fc_w_bram
        │   └── MAC tree (LUT mult)
        ├── argmax_unit → result (4-bit), img_done
        └── ping_pong_buffer instances
```

주요 설계 포인트:

- **AXI BRAM Controller × 4** — 입력 이미지와 세 종류의 weight (Conv1, Conv2, FC) 가 각각 독립된 BRAM 에 매핑되어 PS 가 병렬로 적재 가능
- **Reset 트리** — `Processor System Reset` 이 외부 버튼과 Clocking Wizard `locked` 를 받아 모든 AXI peripheral 및 가속기 IP 의 `peripheral_aresetn` 을 동기 release
- **`cnn_accelerator` 내부 dataflow** — Conv1 → Conv2 → MaxPool → FC → argmax 의 single-image inference 파이프라인. `ping_pong_buffer` 로 stage 간 producer/consumer 를 분리해 연속 1만 장 추론의 throughput 을 끌어올림
- **`core` 공용화** — `line_buffer`, `window_register`, `pe_cell`, `truncate_relu` 는 `RTL/core/` 에 분리하여 conv1_engine / conv2_engine 이 동일 PE 빌딩 블록을 인스턴스화. parameter 로 channel / output width 만 조정
- **결과 출력** — `argmax_unit` 이 10-class logit 에서 4-bit class index 와 `img_done` 신호를 만들어 PS 로 보고

---

## 4. 폴더 구조 및 역할

```
CNN_Accelerator/
├── RTL/                  # CNN 가속기 합성 대상 Verilog (메인 산출물)
│   ├── cnn_accelerator.v          # baseline 최상위 IP (전체 배선 + BMG IP 목록)
│   ├── cnn_accelerator_winograd.v # Winograd 변형 최상위 (동일 module 명 상호배타)
│   ├── core/             # stage 공용 primitive (pe_cell, line_buffer, window_register, truncate_relu)
│   ├── conv1/ conv2/ maxpool/ fc/ # 레이어별 engine + FSM + adder/accumulator
│   ├── conv1_2x/         # Winograd 단계용 Conv1 2× DSP rebalance
│   ├── conv2_winograd/   # complex F(4,3) Winograd Conv2 engine
│   └── control_status_register/   # AXI4-Lite CSR slave
├── TB/                   # Verilog testbench (Vivado 없이 iverilog 로컬 시뮬 가능)
│   ├── models/           # 합성 불가 시뮬 모델 (BMG/BRAM, DSP48E1)
│   ├── single_img/       # 단일 이미지 단위 TB
│   ├── multi_img/        # 다중 이미지 통합 TB (전체 파이프라인, AXI 포함)
│   └── winograd/         # Winograd 전용 TB
├── scripts/              # 골든/입력 데이터 생성 (Python) → data/ 로
│   ├── golden_sim/       # PyTorch bit-exact reference (Direct + Winograd)
│   ├── single_img/ multi_img/     # 레이어별 / 다중 이미지 hex 생성
│   └── weights/          # DSP SIMD weight packing
├── data/                 # 생성된 검증/입력 데이터 (scripts/ 산출물)
│   ├── _base_npy/        # 원본 PyTorch npy (weight / input / output)
│   ├── single_img/ multi_img/     # 레이어별 / 다중 골든 hex
│   ├── weights_simd/     # SIMD packed weight (.hex=TB / .h=vitis)
│   └── winograd/         # Winograd 골든 데이터
├── vitis/                # PS(MicroBlaze) 펌웨어 (main.c, test_images.h)
├── archive/              # 이전 과제(AS1 Sobel) baseline — 인프라 검증용 참고
└── docs/                 # 설계·타이밍·알고리즘·협업 문서 (+ ip_spec/, overclock/, winograd/)
```

### `RTL/`

CNN 가속기의 합성 대상 Verilog 가 모두 모이는 메인 디렉토리.

- `cnn_accelerator.v` — baseline 최상위 모듈. 전체 데이터패스 배선 + 필요한 BMG(BRAM) IP 목록이 파일 헤더 주석에 정리됨. packaged IP 로 Block Design 에 인스턴스화
- `cnn_accelerator_winograd.v` — Winograd 변형 최상위 (동일 module 명이라 baseline 과 상호배타)
- `core/` — stage 공용 PE 빌딩 블록: `pe_cell.v` (DSP48E1 INT8×2 SIMD 곱), `line_buffer.v` / `window_register.v` (sliding-window 생성), `truncate_relu.v` (`>>10` + saturate ±127 + ReLU)
- `conv1/` `conv2/` `maxpool/` `fc/` — 레이어별 engine + 자체 FSM + adder-tree / accumulator. stage 사이는 ping-pong BRAM + producer/consumer 핸드셰이크로 분산 제어 (중앙 컨트롤러 없음)
- `conv1_2x/` — Winograd 단계에서 Conv1 을 18→36 DSP 로 늘려 2 round → 1 round 화한 rebalance 버전
- `conv2_winograd/` — complex F(4,3) Winograd Conv2 engine (DSP 184)
- `control_status_register/` — start/done·result·timer 제어용 AXI4-Lite CSR slave

### `TB/`

Verilog testbench. Vivado 없이 `iverilog` 로 로컬에서 전체 파이프라인을 bit-exact 검증할 수 있다.

- `models/` — 합성 불가 시뮬 모델 (`bmg_sim_models.v`, `dsp48e1_model.v`)
- `single_img/` — 엔진별 단일 이미지 TB
- `multi_img/` — 다중 이미지 통합 TB (`tb_cnn_accelerator_multi` = 전체 PL core, `tb_system_axi_multi_2clk` = AXI / 멀티클럭 포함)
- `winograd/` — Winograd 전용 TB

### `archive/`

이전 과제(AS1 Sobel edge detection) baseline. CNN 본 구현 전 PS-PL 인터페이스, AXI CSR, BRAM dual-port, line-buffer stencil 연산을 검증한 인프라이며, 본 프로젝트의 line-buffer sliding-window 구조가 여기서 재사용되었다.

### `scripts/`

명세를 알고리즘적으로 검증하고, 검증된 데이터를 RTL / SW 가 먹을 형식으로 변환하는 Python 스크립트. 산출물은 `data/` 로 간다.

- `golden_sim/` — PyTorch bit-exact reference
  - `reference_core.py` — 공통 유틸 (`.npy`·MNIST 라벨 로드, bit-exact 비교, 명세 saturation 규칙 = `>>10` shift + clip[-128,127] 을 갖는 base 레이어)
  - `0_reference.py` — INT8 Direct 컨볼루션 reference (`data/_base_npy/output.npy` 와 bit-exact 일치)
  - `1_complex_winograd_f(4,3).py` — complex F(4,3) Winograd 변환 reference (10,000장 bit-exact)
- `single_img/` `multi_img/` — 레이어별 / 다중 이미지 골든 hex 생성
- `weights/` — DSP SIMD weight packing (`weight_simd_pack.py`)

### `data/`

`scripts/` 산출물 및 원본 INT8 파라미터. TB / vitis 가 소비한다.

- `_base_npy/` — 원본 PyTorch `.npy` (Conv1 `(8,1,3,3)` / Conv2 `(16,8,3,3)` / FC `(10,2304)` weight, input, expected output)
- `single_img/` `multi_img/` — 레이어별 / 다중 이미지 골든 hex
- `weights_simd/` — SIMD packed weight (`.hex` = TB 용, `.h` = vitis 용)
- `winograd/` — Winograd 골든 데이터

### `docs/`

설계·구현·협업 관련 모든 문서.

- `project_overview.md` — 보드/자원 한도, 타겟 CNN, 결정 사항, 업무 분담 결정 내역
- `DSP48E1_signed8x8_SIMD_Packing.md` — DSP48E1 단일 multiplier 로 signed 8×8 두 개를 동시에 수행하는 SIMD packing 알고리즘 (Winograd 단계 핵심 기법)
- `docs/overclock/direct/journey.md`, `timing/` — 100MHz → 200MHz timing closure 과정 및 HW 측정 근거
- `winograd/` — Conv2 Winograd, Conv1 2× rebalance, cycle-level timing 및 검증 문서
- `cowork_guide.md` — Git / GitHub / VSCode / Python 환경 세팅부터 PR 까지의 협업 가이드
- `pdfs/` — 과제 안내문, 베이스라인 보고서, 구현 계획 PDF, Winograd 참고 자료

---

## 5. 개발 흐름

전형적인 작업 사이클은 다음과 같다.

1. **알고리즘 검증 (scripts/golden_sim)** — Python 으로 명세 구현, `data/_base_npy/output.npy` 와 bit-exact 일치 확인
2. **RTL 설계 (RTL)** — 동일 동작을 Verilog 로 옮기고, testbench 로 동일 입력에 대한 동일 출력 검증
3. **합성 & 보드 검증 (Vivado / Vitis)** — 위 Block Design 으로 bitstream 빌드 → Arty A7-100T 에 적재 → PS 측 baremetal app 으로 MNIST 1만 장 분류 수행
4. **측정 & 최적화** — 1만 장 처리 총 시간 측정 후 다음 마일스톤으로

협업 절차 (브랜치 전략, PR 흐름, 환경 세팅) 는 `docs/cowork_guide.md` 에 자세히 정리되어 있다.

---

## 6. 참고 문서 빠른 링크

- 프로젝트 명세 및 계획: [`docs/project_overview.md`](docs/project_overview.md)
- DSP48E1 SIMD Packing: [`docs/DSP48E1_signed8x8_SIMD_Packing.md`](docs/DSP48E1_signed8x8_SIMD_Packing.md)
- 200MHz timing closure 기록: [`docs/overclock/direct/journey.md`](docs/overclock/direct/journey.md)
- Winograd 작업 인덱스: [`docs/winograd/README.md`](docs/winograd/README.md)
- 협업 가이드: [`docs/cowork_guide.md`](docs/cowork_guide.md)
