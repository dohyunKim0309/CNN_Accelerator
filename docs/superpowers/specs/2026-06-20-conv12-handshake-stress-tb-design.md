# conv1/conv2 핸드쉐이크 stress 테스트벤치 재구성 — 설계 스펙

- 작성일: 2026-06-20
- 대상: `RTL/conv1`, `RTL/conv2` 엔진의 단일/멀티 이미지 테스트벤치 (maxpool/fc/winograd 무관)
- 상태: 설계 승인됨 (구현 계획 작성 대기)

---

## 1. 배경 / 문제 정의

현재 conv1·conv2 단일/멀티 TB가 정상 동작하지 않는다. iverilog 로 4개를 실측한 결과:

| TB | 결과 | 근본 원인 |
|---|---|---|
| `tb_conv1_engine.v` (conv1 단일) | ✅ PASS (1636 cyc) | c1c2 readback 이 이미 L=2 (`i-2`) |
| `tb_conv2_engine.v` (conv2 단일) | ❌ FAIL 352/576 | c2pool readback 이 **L=1**(`expected[i-1]`) 가정. 실제 IP/모델은 **L=2** |
| `tb_conv2_engine_multi.v` (conv2 멀티) | ❌ FAIL 30919/57600 | 동일 L=2 readback 버그 (`compare_image` 도 `expected[i-1]`) |
| `tb_conv1_conv2_multi.v` (통합 멀티) | ⚠️ 가짜 PASS | `__ICARUS__` 로컬 경로 없음 → `$readmemh` 실패 → 데이터 X → `!==` 에서 `X===X` 가 일치 처리. + 동일 L=2 버그 + 엔진간 핸드쉐이크를 SW 수동 펄스로 처리(취약) |
| `tb_conv1_conv2.v` (단일 통합) | (미실행) | `compare_c2pool` line 298 `expected[i-1]` → 동일 L=2 버그, 헤더 주석도 stale("L=1") |

### 1.1 진단 핵심

- **L=1 → L=2 stale**: 300MHz 오버클럭 때 `bram_c2_to_pool` 을 L=1 → L=2 로 바꿨으나(`docs/ip_spec/block_memory_generator.md` line 17, `bram_c2_to_pool ... L 2`), c2pool 을 **읽어서 검증하는** TB readback task 들이 여전히 L=1 (`expected[i-1]`) 로 샘플링. 엔진은 c2pool 에 **쓰기만** 하므로 데이터 자체는 정상 — `got[N] == exp[N-1]` 정확한 off-by-one 이 그 증거. 고치면 통과한다 (conv1 단일이 c1c2 를 `i-2` 로 읽어 PASS 하는 것과 대칭).
- **경로 미통일**: `tb_conv1_conv2_multi.v` 만 `__ICARUS__` 분기가 없어 로컬(mac/iverilog)에서 못 돈다. 동작하는 `tb_cnn_accelerator_multi.v` 패턴이 표준.
- **고정 sequential 한계**: 멀티 TB 의 "virtual conv1/maxpool" 이 `wait(conv1_done)` 식 lockstep + overlap 없음. 핸드쉐이크 카운터(2-deep credit)와 ping-pong backpressure 가 실질적으로 스트레스되지 않는다.

---

## 2. 목표 / 범위

### 2.1 목표
1. **버그 수정**: c2pool 을 읽는 모든 readback 을 L=2 로 정정 (단일 + 멀티 + 통합).
2. **실제 BRAM**: 모든 TB 가 `docs/ip_spec` 스펙의 BMG(모델/실IP)를 인스턴스 — 이미 충족, c2pool readback latency 만 정정.
3. **임의 속도 가상 앞/뒷단 모듈**: seeded LFSR 로 무작위 속도로 자율 동작하는 `producer_bfm` / `consumer_bfm` 를 신규 작성, 멀티 TB 에 투입해 양방향 핸드쉐이크 + 개수차 카운터를 random backpressure 로 독립 검증.
4. **프로토콜 assertion**: bit-exact 데이터 비교에 더해 핸드쉐이크/카운터 위반을 런타임 검출.
5. **경로 통일**: 모든 TB 가 mac(iverilog `data/`) + Vivado(Windows 절대경로) 양쪽에서 동작 (`tb_cnn_accelerator_multi.v` 기준 `__ICARUS__` 분기).

### 2.2 범위 밖 (무변경)
- RTL 엔진 (`conv1_engine`, `conv2_engine`, FSM 등) — TB 전용 작업, 엔진은 손대지 않는다.
- maxpool / fc / winograd / AXI 계열 TB.
- `TB/models/bmg_sim_models.v`, `dsp48e1_model.v`.

---

## 3. 핸드쉐이크 프로토콜 (확정 사실 — BFM 설계 근거)

엔진은 중앙 컨트롤러 없이 **2-deep credit 기반 ping-pong flow control** 로 자율 동작한다. conv1·conv2 동일 구조.

- 포트(입출력): `prior_wdone`(in, 상류가 내 입력버퍼에 1장 채움), `rdone`(out, 내가 입력 1장 소비→상류 bank 해제 통보), `succ_rdone`(in, 하류가 내 출력 1장 소비), `wdone`(out, 내가 출력 1장 생산→하류 통보). 모두 **1-cycle 펄스**.
- 카운터 (signed):
  - `prior_diff = (rdone 수) − (prior_wdone 수)`. `data_ready = (prior_diff_next < 0)` → 미소비 입력 존재.
  - `after_diff = (wdone 수) − (succ_rdone 수)`. `output_avail = (after_diff_next < 2)` → 출력 bank 여유.
- 처리 시작 게이트: `data_ready && output_avail` (둘 다 만족 시 다음 이미지 진입).
- bank 선택: `input_bank_sel` 은 `rdone` 마다 토글(0 시작), `output_bank_sel` 은 `wdone` 마다 토글(0 시작) → 이미지 k 는 입력 bank `k&1` 에서 읽고 출력 bank `k&1` 에 쓴다.
- reset: **active-high `rst`**, 모든 카운터/bank_sel 0 초기화.
- 코드 위치: conv1 `RTL/conv1/conv1_fsm.v` (prior_diff/after_diff/게이트/토글), `rdone`=RUN2 끝, `wdone`=DONE. conv2 `RTL/conv2/conv2_fsm.v` + `conv2_engine.v` (`rdone_event`/`wdone_event` 레지스터).

### 3.1 BFM 가 만족해야 할 credit 규칙
- **producer**(상류): 입력 ping-pong 2-bank → `outstanding = img_sent − rdone_cnt` 가 `< 2` 일 때만 다음 이미지를 bank `img_sent&1` 에 write. write 완료 후 `prior_wdone` 1-cyc.
- **consumer**(하류): 출력 ping-pong 2-bank → `available = wdone_cnt − img_recv` 가 `> 0` 일 때만 bank `img_recv&1` 을 read. read+compare 완료 후 `succ_rdone` 1-cyc.
- credit 덕분에 producer write bank 과 engine read bank 은 절대 충돌하지 않고, consumer read bank 과 engine write bank 도 충돌하지 않는다(배타성 보장). 이를 assertion 으로 교차검증.

---

## 4. 재사용 BFM 모듈 — `TB/models/handshake_bfm.v` (신규)

순수 stimulus 모듈(시뮬 전용). **iverilog + Vivado sim 양쪽에 소스로 포함** (bmg_sim_models.v 처럼 Vivado 서 제외하지 않는다 — 실제 자극원이므로).

### 4.1 `producer_bfm`

```
parameter SRC_DW    = 8     // 입력 hex 1 element 폭 (bram_input=8, c1c2=64)
parameter DW        = 32    // BRAM Port A write data 폭   (bram_input=32, c1c2=64)
parameter PACK      = DW/SRC_DW   // 1 word 당 src element 수 (4 또는 1)
parameter WEA_W     = 4     // wea 폭 (bram_input=4, c1c2=8)
parameter AW        = 9     // Port A addr 폭 (bram_input=9, c1c2=11); bank = addr[AW-1]
parameter WORDS     = 196   // 이미지당 word 수 (bram_input=196, c1c2=1024)
parameter N_IMAGES  = 40
parameter IMG_HEX   = "..." // SRC_DW-wide hex, N_IMAGES*WORDS*PACK element
parameter SEED      = 16'hACE1
parameter MAX_IDLE  = 4000  // 이미지 사이 랜덤 idle 상한 (cyc). 이미지 처리시간보다 크게 → starve 유발
parameter STALL_PCT = 40    // burst 중 word 마다 1-cyc stall 삽입 확률 (0~255 LFSR 비교, 0=연속)

ports:
  input  clk, rst
  output reg               prior_wdone
  input                    rdone
  output reg               ena
  output reg [WEA_W-1:0]   wea
  output reg [AW-1:0]      addra
  output reg [DW-1:0]      dina
  output reg [31:0]        img_sent     // 상태/디버그
  output reg               done         // 전 이미지 전송 완료
```

동작(FSM + 16-bit Galois LFSR, SEED 초기화):
1. `initial $readmemh(IMG_HEX, src_mem)` — `reg [SRC_DW-1:0] src_mem [0:N_IMAGES*WORDS*PACK-1]`.
2. `rdone_cnt` 를 `rdone` 마다 +1 (always).
3. 각 이미지 img (0..N-1):
   a. LFSR 로 `idle = lfsr % (MAX_IDLE+1)` 만큼 대기 (ena=0).
   b. `wait((img_sent − rdone_cnt) < 2)` — credit.
   c. `bank = img_sent[0]`. word k (0..WORDS-1):
      - STALL_PCT 확률로 1-cyc stall(ena=0) 후 진행 (LFSR 비교).
      - `dina = { src_mem[base + k*PACK + (PACK-1)], ..., src_mem[base + k*PACK + 0] }` (LE 조립; PACK=1 이면 그대로).
      - `ena=1, wea=all-1, addra={bank, k[AW-2:0]}`.
   d. ena=0 후 1~2 cyc settle, `prior_wdone` 1-cyc, `img_sent++`.
4. 전부 끝나면 `done=1`.

> SRC_DW/DW/PACK 로 비대칭 `bram_input`(8→32 packing)과 대칭 `c1c2`(64→64) 를 한 모듈로 처리.

### 4.2 `consumer_bfm`

```
parameter DW        = 128   // BRAM Port B read data 폭 (c1c2=64, c2pool=128)
parameter AW        = 11    // Port B addr 폭; bank = addr[AW-1]
parameter WORDS     = 576   // 이미지당 word 수 (c1c2=1024, c2pool=576)
parameter READ_LAT  = 2     // BMG read latency L (모두 L=2)
parameter N_IMAGES  = 40
parameter EXP_HEX   = "..." // DW-wide hex, N_IMAGES*WORDS element
parameter SEED      = 16'hBEEF
parameter MAX_IDLE  = 4000  // 이미지 사이 랜덤 idle 상한 → consumer backpressure 유발
parameter STALL_PCT = 40    // burst 중 read gap 확률

ports:
  input  clk, rst
  input                  wdone
  output reg             succ_rdone
  output reg             enb
  output reg [AW-1:0]    addrb
  input      [DW-1:0]    doutb
  output reg [31:0]      img_recv
  output reg [31:0]      mismatch_cnt
  output reg             done
```

동작:
1. `initial $readmemh(EXP_HEX, exp_mem)` — `reg [DW-1:0] exp_mem [0:N_IMAGES*WORDS-1]`.
2. `wdone_cnt` 를 `wdone` 마다 +1 (always).
3. 각 이미지 img (0..N-1):
   a. LFSR 랜덤 idle 대기.
   b. `wait(wdone_cnt > img_recv)` — 가용.
   c. `bank = img_recv[0]`. **issue/capture 2-경로** (gap·L=2 동시 처리):
      - issue: 매 cyc STALL_PCT 확률 stall(enb=0); 아니면 `enb=1, addrb={bank, k[AW-2:0]}, k++` (k<WORDS 까지).
      - addr-valid 파이프(깊이 READ_LAT): `(enb, k)` 를 매 cyc shift. tail 이 valid 면 `doutb` 를 `exp_mem[img*WORDS + tail_k]` 와 `!==` 비교 → 불일치 시 `mismatch_cnt++`, `captured++`.
      - `captured == WORDS` 이면 이미지 read 완료.
   d. `succ_rdone` 1-cyc, `img_recv++`.
4. 전부 끝나면 `done=1`.

> addr-valid 파이프가 STALL gap 과 L=2 latency 를 함께 흡수하므로 `enb` 가 임의 패턴이어도 정확 비교.
> 구현 리스크 완화: 만약 gap 처리가 iverilog 에서 까다로우면 `STALL_PCT=0`(연속 read) 으로도 이미지간 idle jitter 만으로 backpressure 검증 성립 — fallback.

### 4.3 프로토콜 assertion (사용자 핵심 요구)

producer 내부:
- `assert (rdone_cnt <= img_sent)` — 엔진이 안 보낸 bank 를 read 했다고 주장 금지.
- `assert (0 <= img_sent − rdone_cnt <= 2)` — credit 범위.

consumer 내부:
- `assert (wdone_cnt >= img_recv)`.
- `assert ((wdone_cnt − img_recv) <= 2)` — **위반 시 엔진 `output_avail`(after_diff<2) 카운터 버그** (3장 미리 생산). 핵심 회귀 검출기.

공통:
- `prior_wdone`/`succ_rdone` 1-cycle 폭 (2 cyc 연속 high 금지).
- deadlock 은 TB timeout → FAIL.
- iverilog 는 `$fatal` 대신 `$display("ASSERT FAIL ...")` + 카운터 누적(최종 리포트에서 비-0 이면 FAIL) 으로 처리 (iverilog/xsim 호환).

---

## 5. 멀티 TB 3종

각 TB 는 3-process 구조(`tb_cnn_accelerator_multi.v` 패턴): main(reset+weight+start+report) / producer_bfm / consumer_bfm. 입출력 BFM 에 **서로 다른 SEED**.

### 5.1 `tb_conv1_engine_multi.v` (신규, conv1 단독)
```
producer ─[bram_input]─▶ conv1_engine ─[bram_c1_to_c2]─▶ consumer
배선: conv1.prior_wdone ← producer.prior_wdone,  producer.rdone ← conv1.rdone
      conv1.succ_rdone  ← consumer.succ_rdone,   consumer.wdone ← conv1.wdone
producer: SRC_DW=8, DW=32, PACK=4, WEA_W=4, AW=9,  WORDS=196,  IMG_HEX=all_input.hex
consumer: DW=64, AW=11, WORDS=1024, READ_LAT=2,    EXP_HEX=all_c1c2.hex
weight  : conv1_weight_bram Port A 36 word write (init 1회). conv1 은 prior_wdone 로 트리거(별도 start 불필요 — 확인 필요).
```

### 5.2 `tb_conv2_engine_multi.v` (덮어쓰기, conv2 단독)
```
producer ─[bram_c1_to_c2]─▶ conv2_engine ─[bram_c2_to_pool]─▶ consumer
배선: conv2.prior_wdone ← producer.prior_wdone, producer.rdone ← conv2.rdone
      conv2.succ_rdone  ← consumer.succ_rdone,  consumer.wdone ← conv2.wdone
producer: SRC_DW=64, DW=64, PACK=1, WEA_W=8, AW=11, WORDS=1024, IMG_HEX=all_c1c2.hex
consumer: DW=128, AW=11, WORDS=576, READ_LAT=2,     EXP_HEX=all_c2pool.hex
weight  : conv2_weight_bram Port A 576 word write + conv2.start 1-cyc pulse(LOAD_WEIGHTS) (init 1회).
```

### 5.3 `tb_conv1_conv2_multi.v` (덮어쓰기, 통합)
```
producer ─[bram_input]─▶ conv1 ─[bram_c1_to_c2]─▶ conv2 ─[bram_c2_to_pool]─▶ consumer
★ 중간 핸드쉐이크는 실제 wire:  conv1.wdone → conv2.prior_wdone,  conv2.rdone → conv1.succ_rdone
  (기존의 conv1_done 후 SW 수동 prior_wdone pulse 제거 — 엔진 자율 동기화)
경계 BFM: producer.rdone ← conv1.rdone,  consumer.wdone ← conv2.wdone
producer: bram_input  (5.1 producer 와 동일 파라미터),  IMG_HEX=all_input.hex
consumer: c2pool      (5.2 consumer 와 동일 파라미터),  EXP_HEX=all_c2pool.hex
weight  : conv1 BMG 36 + conv2 BMG 576 write + conv2.start 1-cyc pulse (init 1회).
```

### 5.4 공통 사항
- clock 100MHz, **active-high `rst`** (엔진 규약; cnn 최상위만 resetn). BFM 도 active-high.
- `MAX_IDLE` 를 이미지 처리시간(conv1 ~1.6k, conv2 ~1.8k cyc)보다 크게 → producer starve / consumer backpressure 양방향 자연 발생. 최종 리포트에 "producer 최대 outstanding 도달 횟수 / consumer 최대 available 도달 횟수" 를 찍어 backpressure 발생을 증거화.
- N_IMAGES=40 기본 (데이터 100 까지 지원), SEED 는 파라미터로 스윕 가능.

---

## 6. 단일 TB 수정 (L=2 + 경로 통일)

- `TB/single_img/tb_conv2_engine.v`: `compare_c2pool` 을 L=2 로 — loop `0..577`, `if(i>=2) exp=expected_c2pool[i-2]`. 헤더 주석 `bram_c2_to_pool ... L=1` → `L=2`. (`__ICARUS__` 경로 이미 로컬 — 유지.)
- `TB/single_img/tb_conv1_conv2.v`: `compare_c2pool` 동일 L=2 정정 (line 287~298). 헤더 line 19 주석 `L=1`→`L=2`.
- `TB/single_img/tb_conv1_engine.v`: 이미 PASS. 경로/주석 점검만 (변경 최소, 가능하면 무변경).

---

## 7. 파일 계획

| 동작 | 파일 | 비고 |
|---|---|---|
| 신규 | `TB/models/handshake_bfm.v` | `producer_bfm` + `consumer_bfm` |
| 신규 | `TB/multi_img/tb_conv1_engine_multi.v` | conv1 단독 멀티 |
| 덮어쓰기 | `TB/multi_img/tb_conv2_engine_multi.v` | 구 sequential 버전 폐기 → BFM 버전 |
| 덮어쓰기 | `TB/multi_img/tb_conv1_conv2_multi.v` | 구 버전 폐기 → BFM + 실 wire 핸드쉐이크 |
| 수정 | `TB/single_img/tb_conv2_engine.v` | L=2 |
| 수정 | `TB/single_img/tb_conv1_conv2.v` | L=2 |
| 점검 | `TB/single_img/tb_conv1_engine.v` | 무변경 목표 |

> "기존 conv1/conv2 멀티 TB 삭제" 요구는 위 2개 파일을 BFM 버전으로 **덮어써** 충족(구 코드 제거, 파일명은 자연스러운 자리 유지). maxpool/fc/winograd 멀티 TB 는 건드리지 않는다.

---

## 8. 검증 계획

iverilog 명령(프로젝트 루트):
```
iverilog -g2012 -o out.vvp -y RTL/core -y RTL/conv1 -y RTL/conv2 -y RTL/maxpool -y RTL/fc \
  RTL/conv2/weight_loader.v TB/models/dsp48e1_model.v TB/models/bmg_sim_models.v \
  TB/models/handshake_bfm.v TB/multi_img/<tb>.v && vvp out.vvp
```
(단일은 `TB/single_img/<tb>.v`. `handshake_bfm.v` 는 단일에는 불필요.)

성공 기준:
1. 6개 TB(단일 3 + 멀티 3) 전부 **컴파일 + 실행**, **bit-exact PASS**, **assertion 위반 0**.
2. 멀티 3개 로그에 입력측 credit 포화(**producer outstanding=2**, 엔진이 입력 bank 를 못 비워 producer 가 멈춤)와 출력측 포화(**consumer available=2**, 엔진이 출력 2장을 미리 채우고 멈춤)가 최소 수 회씩 찍혀 양방향 backpressure 가 실제 발생함을 증명. (두 포화는 결국 producer/consumer 의 상대 속도 차에서 비롯; random idle 이 두 방향 모두를 유발.)
3. SEED 2~3개 스윕에도 전부 PASS (난수 강건성).
4. Vivado(parallel desktop): RTL 무변경. sim source 에 `handshake_bfm.v` 추가, `bmg_sim_models.v` 제외(실 IP 대체), 경로는 `__ICARUS__` 미정의로 Windows 분기 자동 선택.

복붙 안내(사용자 워크플로): 변경 파일은 전부 `TB/` 하위 (RTL 무변경). Vivado sim set 에 `handshake_bfm.v` 1개만 추가하면 됨.

---

## 9. 리스크 / 완화

| 리스크 | 완화 |
|---|---|
| consumer gap+L=2 비교 파이프 인덱싱 오류 | addr-valid 파이프를 단일 책임으로 격리, `STALL_PCT=0` fallback. iverilog bit-exact 로 인덱스 확정 |
| conv1 이 prior_wdone 만으로 트리거되는지 불확실 | 구현 첫 단계에서 conv1_fsm IDLE 게이트 확인 (`(data_ready&&output_avail)||start_pulse`). 필요시 init 에 start 1-cyc 추가 |
| LFSR/`$readmemh`/assert 의 xsim 호환 | 표준 합성가능 스타일 + `$display` 기반 soft-assert (`$fatal` 회피) |
| 덮어쓸 파일이 다른 곳에서 include | TB 는 top-level, include 안 됨 — 안전 |

---

## 10. 미해결 / 구현 중 확정할 것
- conv1 단독 TB 에서 conv1 트리거에 start pulse 필요 여부 (RTL 확인).
- BFM `MAX_IDLE` 구체값 (conv1/conv2 처리시간 측정 후 1.5~2× 로 설정).
- 최종 backpressure 통계 출력 포맷.
