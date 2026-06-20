# conv1/conv2 핸드쉐이크 stress 테스트벤치 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** conv1/conv2 단일·멀티 TB 의 L=2 readback 버그를 고치고, seeded-LFSR 임의 속도 `producer_bfm`/`consumer_bfm` 모듈을 신규 작성해 멀티 TB 3종(conv1 단독 / conv2 단독 / conv1+conv2)에서 2-deep credit ping-pong 핸드쉐이크를 random backpressure + 프로토콜 assertion 으로 검증한다.

**Architecture:** 각 멀티 TB 는 실제 BMG 버퍼 + 실제 엔진 + 경계에 임의 속도 BFM 모듈(producer 앞단 / consumer 뒷단)을 붙인 3-process 구조(`tb_cnn_accelerator_multi.v` 패턴). BFM 은 엔진의 실제 `prior_wdone`/`rdone`/`succ_rdone`/`wdone` 포트로 자율 동기화하며, credit(`outstanding≤2`) 과 데이터 bit-exact 를 런타임 검사한다.

**Tech Stack:** Verilog-2001/2012, iverilog(`-g2012`) 로컬 시뮬, Vivado xsim(parallel desktop). 검증 데이터 = `data/multi_img/all_*.hex`, `data/weights_simd/*.hex`.

## Global Constraints

- RTL 엔진(`conv1_engine`/`conv2_engine`/FSM) **무변경** — TB 전용 작업.
- 모든 TB 는 mac(iverilog, `data/` 상대경로) + Vivado(Windows 절대경로) 양쪽 동작 — `\`ifdef __ICARUS__` 분기 (기준: `tb_cnn_accelerator_multi.v`).
- 엔진 reset = **active-high `rst`**. BFM 도 active-high.
- BMG read latency **L=2** (전 버퍼). c2pool/c1c2 readback 은 `expected[i-2]` (loop `0..WORDS+1`).
- BMG 모델 사실: `bram_c1_to_c2` = L=2 **양 stage enb-gated, regceb 포트 없음**. `bram_c2_to_pool`/`bram_input` = L=2 **출력 reg(regceb tie1) always-follow**. → consumer 는 **연속(gap 없는) read** 로 두 BMG 공통 L=2 정렬 사용.
- 핸드쉐이크 타이밍(문서 `docs/conv1_timing_table.md`, `RTL/conv2/conv2_timing.md`):
  - conv1: `rdone` @ scan_done+1, `wdone` @ scan_done+8, **마지막 c1c2 write @ scan_done+9** (wdone+1). → consumer 는 wdone 후 **SETTLE≥3 cycle** 뒤 read.
  - conv2: `wdone` @ cycle 1796 (마지막 c2pool mem[575] write 와 동일 edge), 1-cycle pulse.
  - 처리 사이클: conv1 ≈ 1634/img, conv2 ≈ 1796/img → BFM `MAX_IDLE≈2000`.
  - 모든 핸드쉐이크 펄스 1-cycle. `prior_wdone` 는 conv2 LOAD_WEIGHTS 중 도착해도 무해(카운터 decrement).
- 펄스/credit: producer `outstanding = img_sent − rdone_cnt`, write 전 `<2` 대기, bank=`img_sent[0]`. consumer `available = wdone_cnt − img_recv`, `>0` 대기, bank=`img_recv[0]`.
- 커밋 trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

### Deviations from spec
- 스펙 §4.2 의 "gapped consumer read + addr-valid 파이프" → **연속 read** 로 정련. 이유: `bram_c1_to_c2`(enb-gated 양 stage) 와 `bram_c2_to_pool`(regceb always-follow) 의 gap 동작이 달라 generic 파이프가 BMG-특화됨. arbitrary-speed 의 핵심 stress(언제 버퍼를 service 하는가 = backpressure)는 이미지간 random idle 로 충분히 확보. consumer mid-burst stall 제거, producer mid-burst write stall(STALL_PCT)은 BMG 무관하게 안전하여 유지.

---

## File Structure

| 파일 | 책임 |
|---|---|
| `TB/models/handshake_bfm.v` (신규) | `producer_bfm` + `consumer_bfm` (LFSR pacing, credit, assertion) |
| `TB/multi_img/tb_conv1_engine_multi.v` (신규) | conv1 단독 멀티 stress |
| `TB/multi_img/tb_conv2_engine_multi.v` (덮어쓰기) | conv2 단독 멀티 stress (구 sequential 폐기) |
| `TB/multi_img/tb_conv1_conv2_multi.v` (덮어쓰기) | conv1+conv2 통합 멀티 stress (실 wire 핸드쉐이크) |
| `TB/single_img/tb_conv2_engine.v` (수정) | c2pool readback L=2 |
| `TB/single_img/tb_conv1_conv2.v` (수정) | c2pool readback L=2 |

공통 iverilog 명령(cwd=루트):
```
iverilog -g2012 -o /tmp/o.vvp -y RTL/core -y RTL/conv1 -y RTL/conv2 -y RTL/maxpool -y RTL/fc \
  RTL/conv2/weight_loader.v TB/models/dsp48e1_model.v TB/models/bmg_sim_models.v \
  TB/models/handshake_bfm.v TB/multi_img/<tb>.v && vvp /tmp/o.vvp
```
(단일 TB 는 `handshake_bfm.v` 불필요, `TB/single_img/<tb>.v`.)

---

## Task 1: 단일 TB c2pool readback L=2 수정

**Files:**
- Modify: `TB/single_img/tb_conv2_engine.v` (compare_c2pool, 헤더 주석)
- Modify: `TB/single_img/tb_conv1_conv2.v` (compare_c2pool, 헤더 주석)

**Interfaces:** 없음 (자체 완결).

- [ ] **Step 1: 현재 FAIL 확인 (failing test)**

Run: `iverilog -g2012 -o /tmp/o.vvp -y RTL/core -y RTL/conv1 -y RTL/conv2 -y RTL/maxpool -y RTL/fc RTL/conv2/weight_loader.v TB/models/dsp48e1_model.v TB/models/bmg_sim_models.v TB/single_img/tb_conv2_engine.v && vvp /tmp/o.vvp | tail -8`
Expected: `mismatches : 352 / 576`, `*** FAIL ***`.

- [ ] **Step 2: `tb_conv2_engine.v` compare_c2pool 를 L=2 로**

`compare_c2pool` task 의 loop 와 비교 인덱스를 교체:
```verilog
    task compare_c2pool;
        integer i;
        reg [127:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing c2pool BMG bank 0 (576 entries, L=2) vs expected ...");
            for (i = 0; i < 578; i = i + 1) begin          // L=2: 576+2
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = {1'b0, i[9:0]};        // bank 0
                end else begin
                    c2pool_enb_b  = 1'b0;
                end
                if (i >= 2) begin                          // L=2: i-2 데이터 비교
                    got = c2pool_doutb_b;
                    exp = expected_c2pool[i - 2];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ addr %0d (h=%0d w=%0d) : got=%h, exp=%h",
                                     i-2, (i-2)/24, (i-2)%24, got, exp);
                    end
                end
            end
            @(negedge clk); c2pool_enb_b = 1'b0;
        end
    endtask
```
헤더 주석 line 15 `bram_c2_to_pool   (128b × 2048, L=1)` → `L=2`.

- [ ] **Step 3: `tb_conv1_conv2.v` compare_c2pool 를 L=2 로**

동일 패턴 — loop `0..577`(=576+1 끝, 정확히는 `i<578`), `if(i>=2) exp=expected_c2pool[i-2]`:
```verilog
            for (i = 0; i < 578; i = i + 1) begin
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb_b  = 1'b1;
                    c2pool_addr_b = {1'b0, i[9:0]};
                end else begin
                    c2pool_enb_b  = 1'b0;
                end
                if (i >= 2) begin
                    got = c2pool_doutb_b;
                    exp = expected_c2pool[i - 2];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ addr %0d : got=%h, exp=%h", i-2, got, exp);
                    end
                end
            end
```
헤더 주석 line 19 `bram_c2_to_pool ... L=1` → `L=2`.

- [ ] **Step 4: 두 TB PASS 확인**

Run: conv2 single + conv1_conv2 single 각각 컴파일+실행.
Expected: 둘 다 `mismatches : 0 / 576`, `*** PASS ***`.

- [ ] **Step 5: Commit**
```bash
git add TB/single_img/tb_conv2_engine.v TB/single_img/tb_conv1_conv2.v
git commit -m "fix(tb): conv2/conv1_conv2 single c2pool readback L=1 -> L=2"
```

---

## Task 2: `handshake_bfm.v` — producer_bfm + consumer_bfm

**Files:**
- Create: `TB/models/handshake_bfm.v`

**Interfaces (Produces — 이후 모든 멀티 TB 가 사용):**
- `producer_bfm #(SRC_DW,DW,WEA_W,AW,WORDS,N_IMAGES,IMG_HEX,SEED,MAX_IDLE,STALL_PCT,SETTLE) (clk,rst, prior_wdone[out], rdone[in], ena[out],wea[out],addra[out],dina[out], img_sent[out],assert_fail[out],done[out])`
- `consumer_bfm #(DW,AW,WORDS,READ_LAT,N_IMAGES,EXP_HEX,SEED,MAX_IDLE,SETTLE) (clk,rst, wdone[in], succ_rdone[out], enb[out],addrb[out],doutb[in], img_recv[out],mismatch_cnt[out],assert_fail[out],done[out])`

- [ ] **Step 1: 모듈 작성 (full code)**

```verilog
`timescale 1ns / 1ps
//==============================================================================
// handshake_bfm.v — 임의 속도 가상 앞/뒷단 BFM (시뮬 전용)
//   producer_bfm : 입력 ping-pong BRAM 채움 + prior_wdone, rdone 로 credit(outstanding<2)
//   consumer_bfm : 출력 ping-pong BRAM 비움 + succ_rdone, wdone 감시 + bit-exact 비교
//   난수: 16-bit Galois LFSR (SEED) — 결정론적/재현가능.
//   credit/타이밍 근거: docs/superpowers/specs/2026-06-20-conv12-handshake-stress-tb-design.md,
//                       docs/conv1_timing_table.md, RTL/conv2/conv2_timing.md
//   ★ bmg_sim_models.v 와 달리 Vivado 에서도 소스에 포함 (실제 자극원).
//==============================================================================

// ---------------------------------------------------------------------------
// producer_bfm — 상류(앞단): 입력 BRAM Port A write + prior_wdone, rdone credit
// ---------------------------------------------------------------------------
module producer_bfm #(
    parameter integer SRC_DW    = 8,        // 입력 hex element 폭 (bram_input=8, c1c2=64)
    parameter integer DW        = 32,       // BRAM Port A write 폭 (bram_input=32, c1c2=64)
    parameter integer WEA_W     = 4,        // wea 폭 (bram_input=4, c1c2=8)
    parameter integer AW        = 9,        // Port A addr 폭; bank = addr[AW-1]
    parameter integer WORDS     = 196,      // 이미지당 word 수
    parameter integer N_IMAGES  = 40,
    parameter         IMG_HEX   = "data/multi_img/all_input.hex",
    parameter [15:0]  SEED      = 16'hACE1,
    parameter integer MAX_IDLE  = 2000,     // 이미지간 random idle 상한
    parameter integer STALL_PCT = 40,       // burst 중 word 마다 1-cyc stall 확률 (0..255, 0=연속)
    parameter integer SETTLE    = 2         // 마지막 write → prior_wdone settle
)(
    input  wire             clk,
    input  wire             rst,            // active-high
    output reg              prior_wdone,
    input  wire             rdone,
    output reg              ena,
    output reg [WEA_W-1:0]  wea,
    output reg [AW-1:0]     addra,
    output reg [DW-1:0]     dina,
    output reg [31:0]       img_sent,
    output reg [31:0]       assert_fail,
    output reg              done
);
    localparam integer PACK = DW / SRC_DW;
    reg [SRC_DW-1:0] src_mem [0:N_IMAGES*WORDS*PACK-1];
    initial $readmemh(IMG_HEX, src_mem);

    // rdone counter (credit source)
    reg [31:0] rdone_cnt;
    always @(posedge clk) if (rst) rdone_cnt <= 32'd0; else if (rdone) rdone_cnt <= rdone_cnt + 1;

    // 16-bit Galois LFSR
    reg [15:0] lfsr;
    function [15:0] lfsr_nxt; input [15:0] s;
        begin lfsr_nxt = s[0] ? ((s >> 1) ^ 16'hB400) : (s >> 1); end
    endfunction

    integer img, k, j, idle, s;
    reg [DW-1:0] word;

    initial begin
        prior_wdone = 1'b0; ena = 1'b0; wea = {WEA_W{1'b0}}; addra = {AW{1'b0}};
        dina = {DW{1'b0}}; img_sent = 32'd0; assert_fail = 32'd0; done = 1'b0; lfsr = SEED;
        wait (!rst);
        @(negedge clk);
        for (img = 0; img < N_IMAGES; img = img + 1) begin
            // random idle
            lfsr = lfsr_nxt(lfsr); idle = lfsr % (MAX_IDLE + 1);
            for (j = 0; j < idle; j = j + 1) @(negedge clk);
            // credit: outstanding < 2
            while ((img_sent - rdone_cnt) >= 2) @(negedge clk);
            // write WORDS words to bank img_sent[0]
            for (k = 0; k < WORDS; k = k + 1) begin
                lfsr = lfsr_nxt(lfsr);
                if (lfsr[7:0] < STALL_PCT) begin ena = 1'b0; wea = {WEA_W{1'b0}}; @(negedge clk); end
                word = {DW{1'b0}};
                for (j = 0; j < PACK; j = j + 1)
                    word[j*SRC_DW +: SRC_DW] = src_mem[img*WORDS*PACK + k*PACK + j];
                ena = 1'b1; wea = {WEA_W{1'b1}};
                addra = {img_sent[0], k[AW-2:0]};
                dina = word;
                @(negedge clk);
            end
            ena = 1'b0; wea = {WEA_W{1'b0}};
            for (s = 0; s < SETTLE; s = s + 1) @(negedge clk);
            prior_wdone = 1'b1; @(negedge clk); prior_wdone = 1'b0;
            img_sent = img_sent + 1;
        end
        done = 1'b1;
    end

    // protocol assertion (negedge: img_sent/rdone_cnt 안정)
    always @(negedge clk) if (!rst) begin
        if (rdone_cnt > img_sent)              assert_fail = assert_fail + 1; // 안 보낸 bank read
        if ((img_sent - rdone_cnt) > 2)        assert_fail = assert_fail + 1; // credit overflow
    end
endmodule

// ---------------------------------------------------------------------------
// consumer_bfm — 하류(뒷단): 출력 BRAM Port B read + succ_rdone, wdone 감시
// ---------------------------------------------------------------------------
module consumer_bfm #(
    parameter integer DW        = 128,      // BRAM Port B read 폭 (c1c2=64, c2pool=128)
    parameter integer AW        = 11,       // Port B addr 폭; bank = addr[AW-1]
    parameter integer WORDS     = 576,      // 이미지당 word 수
    parameter integer READ_LAT  = 2,        // BMG read latency L
    parameter integer N_IMAGES  = 40,
    parameter         EXP_HEX   = "data/multi_img/all_c2pool.hex",
    parameter [15:0]  SEED      = 16'hBEEF,
    parameter integer MAX_IDLE  = 2000,
    parameter integer SETTLE    = 3         // wdone → first read (conv1 last write @ wdone+1)
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          wdone,
    output reg           succ_rdone,
    output reg           enb,
    output reg [AW-1:0]  addrb,
    input  wire [DW-1:0] doutb,
    output reg [31:0]    img_recv,
    output reg [31:0]    mismatch_cnt,
    output reg [31:0]    assert_fail,
    output reg           done
);
    reg [DW-1:0] exp_mem [0:N_IMAGES*WORDS-1];
    initial $readmemh(EXP_HEX, exp_mem);

    reg [31:0] wdone_cnt;
    always @(posedge clk) if (rst) wdone_cnt <= 32'd0; else if (wdone) wdone_cnt <= wdone_cnt + 1;

    reg [15:0] lfsr;
    function [15:0] lfsr_nxt; input [15:0] s;
        begin lfsr_nxt = s[0] ? ((s >> 1) ^ 16'hB400) : (s >> 1); end
    endfunction

    integer img, i, idle, j, mm;
    reg [DW-1:0] got, exp;
    reg          bank;

    initial begin
        succ_rdone = 1'b0; enb = 1'b0; addrb = {AW{1'b0}}; img_recv = 32'd0;
        mismatch_cnt = 32'd0; assert_fail = 32'd0; done = 1'b0; lfsr = SEED;
        wait (!rst);
        @(negedge clk);
        for (img = 0; img < N_IMAGES; img = img + 1) begin
            lfsr = lfsr_nxt(lfsr); idle = lfsr % (MAX_IDLE + 1);
            for (j = 0; j < idle; j = j + 1) @(negedge clk);
            // availability
            while (wdone_cnt <= img_recv) @(negedge clk);
            // settle (conv1: 마지막 c1c2 write @ wdone+1)
            for (j = 0; j < SETTLE; j = j + 1) @(negedge clk);
            bank = img_recv[0];
            mm = 0;
            // 연속 read, L=READ_LAT 정렬 (conv1 single 검증 패턴)
            for (i = 0; i < WORDS + READ_LAT; i = i + 1) begin
                @(negedge clk);
                if (i < WORDS) begin enb = 1'b1; addrb = {bank, i[AW-2:0]}; end
                else           begin enb = 1'b0; end
                if (i >= READ_LAT) begin
                    got = doutb;
                    exp = exp_mem[img*WORDS + (i - READ_LAT)];
                    if (got !== exp) begin
                        mm = mm + 1;
                        if (mm <= 3) $display("[consumer] MM img=%0d addr=%0d got=%h exp=%h",
                                              img, i - READ_LAT, got, exp);
                    end
                end
            end
            @(negedge clk); enb = 1'b0;
            mismatch_cnt = mismatch_cnt + mm;
            succ_rdone = 1'b1; @(negedge clk); succ_rdone = 1'b0;
            img_recv = img_recv + 1;
        end
        done = 1'b1;
    end

    // protocol assertion
    always @(negedge clk) if (!rst) begin
        if (wdone_cnt < img_recv)              assert_fail = assert_fail + 1;
        if ((wdone_cnt - img_recv) > 2)        assert_fail = assert_fail + 1; // 엔진 output_avail 버그
    end
endmodule
```

- [ ] **Step 2: 컴파일 elaborate 확인 (syntax test)**

Run: `iverilog -g2012 -o /tmp/bfm.vvp -t null TB/models/handshake_bfm.v 2>&1 | head`
Expected: 에러 없음(경고만 가능). (`-t null` = elaborate only.)

- [ ] **Step 3: Commit**
```bash
git add TB/models/handshake_bfm.v
git commit -m "feat(tb): random-speed producer/consumer handshake BFM modules"
```

---

## Task 3: `tb_conv1_engine_multi.v` (신규) — conv1 단독 stress

**Files:**
- Create: `TB/multi_img/tb_conv1_engine_multi.v`

**Interfaces (Consumes):** `producer_bfm`/`consumer_bfm` (Task 2), `bram_input`/`bram_c1_to_c2` (bmg_sim_models.v), `conv1_engine`.

**배선:** producer→bram_input→conv1→bram_c1_to_c2→consumer. `conv1.prior_wdone←producer.prior_wdone`, `producer.rdone←conv1.rdone`, `conv1.succ_rdone←consumer.succ_rdone`, `consumer.wdone←conv1.wdone`. 입력 `all_input.hex`(SRC_DW=8,DW=32,PACK=4,WORDS=196,AW=9,WEA_W=4), 기대 `all_c1c2.hex`(DW=64,WORDS=1024,AW=11). conv1 weight = c1w_* Port A 36 word(rst 중 적재). conv1 은 prior_wdone 로 트리거(start 불필요 — Step 4 에서 확인).

- [ ] **Step 1: TB 작성 (full code)**

```verilog
`timescale 1ns / 1ps
//==============================================================================
// tb_conv1_engine_multi.v — conv1 단독 멀티 stress (임의 속도 BFM, N 이미지 bit-exact)
//   producer ─bram_input─▶ conv1_engine ─bram_c1_to_c2─▶ consumer
//   양방향 핸드쉐이크/credit 카운터 독립 검증 + 프로토콜 assertion.
//   BMG: bmg_sim_models.v(iverilog) / 실 IP(Vivado). conv1_weight_bram = conv1 내부.
//==============================================================================
`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define ALL_C1C2_HEX     "data/multi_img/all_c1c2.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
`else
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define ALL_C1C2_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c1c2.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`endif

module tb_conv1_engine_multi;
    parameter N_IMAGES = 40;
    parameter SEED_P   = 16'hACE1;
    parameter SEED_C   = 16'h1234;

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst     = 1'b1;     // engine reset (active-high)
    reg bfm_rst = 1'b1;     // BFM hold until setup done

    // conv1 weight Port A (engine 내부 BMG)
    reg         c1w_ena = 1'b0; reg [3:0] c1w_wea = 4'd0;
    reg [5:0]   c1w_addra = 6'd0; reg [31:0] c1w_dina = 32'd0;
    reg [31:0]  weight1_mem [0:35];

    // nets
    wire prior_wdone, rdone, succ_rdone, wdone;
    wire        in_ena;  wire [3:0] in_wea; wire [8:0] in_addra; wire [31:0] in_dina;
    wire        in_enb;  wire [10:0] in_addrb; wire signed [7:0] in_doutb;
    wire        c1c2_we; wire [7:0] c1c2_wea; wire [10:0] c1c2_addr; wire [63:0] c1c2_din;
    wire        c1c2_renb; wire [10:0] c1c2_raddr; wire [63:0] c1c2_rdout;
    wire [31:0] p_sent, p_af, c_recv, c_mm, c_af;
    wire        p_done, c_done;

    // input BMG: producer writes A, conv1 reads B
    bram_input in_bmg (
        .clka(clk), .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .clkb(clk), .enb(in_enb), .addrb(in_addrb), .doutb(in_doutb));

    // c1c2 BMG: conv1 writes A, consumer reads B
    bram_c1_to_c2 c1c2_bmg (
        .clka(clk), .ena(c1c2_we), .wea(c1c2_wea), .addra(c1c2_addr), .dina(c1c2_din),
        .clkb(clk), .enb(c1c2_renb), .addrb(c1c2_raddr), .doutb(c1c2_rdout));

    // DUT
    conv1_engine conv1 (
        .clk(clk), .rst(rst), .start(1'b0), .done(),
        .prior_wdone(prior_wdone), .succ_rdone(succ_rdone), .rdone(rdone), .wdone(wdone),
        .in_bram_addr(in_addrb), .in_bram_en(in_enb), .in_bram_dout(in_doutb),
        .c1w_ena(c1w_ena), .c1w_wea(c1w_wea), .c1w_addra(c1w_addra), .c1w_dina(c1w_dina),
        .c1c2_we(c1c2_we), .c1c2_wea(c1c2_wea), .c1c2_addr(c1c2_addr), .c1c2_din(c1c2_din));

    // producer (앞단): bram_input
    producer_bfm #(.SRC_DW(8), .DW(32), .WEA_W(4), .AW(9), .WORDS(196),
                   .N_IMAGES(N_IMAGES), .IMG_HEX(`ALL_INPUT_HEX), .SEED(SEED_P),
                   .MAX_IDLE(2000), .STALL_PCT(40), .SETTLE(2)) prod (
        .clk(clk), .rst(bfm_rst), .prior_wdone(prior_wdone), .rdone(rdone),
        .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .img_sent(p_sent), .assert_fail(p_af), .done(p_done));

    // consumer (뒷단): bram_c1_to_c2
    consumer_bfm #(.DW(64), .AW(11), .WORDS(1024), .READ_LAT(2),
                   .N_IMAGES(N_IMAGES), .EXP_HEX(`ALL_C1C2_HEX), .SEED(SEED_C),
                   .MAX_IDLE(2000), .SETTLE(3)) cons (
        .clk(clk), .rst(bfm_rst), .wdone(wdone), .succ_rdone(succ_rdone),
        .enb(c1c2_renb), .addrb(c1c2_raddr), .doutb(c1c2_rdout),
        .img_recv(c_recv), .mismatch_cnt(c_mm), .assert_fail(c_af), .done(c_done));

    // backpressure 통계
    integer cyc = 0; always @(posedge clk) if (!bfm_rst) cyc <= cyc + 1;
    integer prod_sat = 0, cons_sat = 0;
    always @(negedge clk) if (!bfm_rst) begin
        if ((p_sent - cons_recv_cnt()) ...; // (간단화: 아래 monitor 블록으로 대체)
    end

    task load_w1; integer wi; begin
        for (wi=0; wi<36; wi=wi+1) begin @(negedge clk);
            c1w_ena=1'b1; c1w_wea=4'hF; c1w_addra=wi[5:0]; c1w_dina=weight1_mem[wi]; end
        @(negedge clk); c1w_ena=1'b0; c1w_wea=4'd0;
    end endtask

    initial begin : main
        $display("\n=== tb_conv1_engine_multi (N=%0d, SEED_P=%h SEED_C=%h) ===", N_IMAGES, SEED_P, SEED_C);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        rst = 1'b1; bfm_rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;           // engine 가동
        load_w1();                            // conv1 weight BMG 적재
        repeat (4) @(posedge clk);
        @(negedge clk); bfm_rst = 1'b0;       // BFM 시작
        wait (p_done && c_done);
        repeat (20) @(posedge clk);
        $display("\n=== conv1 단독 결과 ===");
        $display("  images        : sent=%0d recv=%0d", p_sent, c_recv);
        $display("  mismatch      : %0d", c_mm);
        $display("  assert_fail   : producer=%0d consumer=%0d", p_af, c_af);
        $display("  backpressure  : prod_sat=%0d cons_sat=%0d (outstanding/available=2 도달)", prod_sat, cons_sat);
        $display("  total cycles  : %0d", cyc);
        if (c_mm==0 && p_af==0 && c_af==0 && c_recv==N_IMAGES)
            $display("  *** PASS ***"); else $display("  *** FAIL ***");
        $finish;
    end

    // backpressure saturation 카운트 (rising-edge of 포화)
    reg [31:0] rdc=0, wdc=0; reg out_sat_d=0, av_sat_d=0;
    always @(posedge clk) begin
        if (bfm_rst) begin rdc<=0; wdc<=0; end
        else begin if (rdone) rdc<=rdc+1; if (wdone) wdc<=wdc+1; end
    end
    always @(negedge clk) if (!bfm_rst) begin
        // outstanding(producer) = p_sent - rdc ; available(consumer) = wdc - c_recv
        if (((p_sent - rdc) >= 2) && !out_sat_d) prod_sat = prod_sat + 1;
        out_sat_d <= ((p_sent - rdc) >= 2);
        if (((wdc - c_recv) >= 2) && !av_sat_d)  cons_sat = cons_sat + 1;
        av_sat_d <= ((wdc - c_recv) >= 2);
    end

    initial begin #50000000;
        $display("\n[TB] !!! TIMEOUT cyc=%0d sent=%0d recv=%0d !!!", cyc, p_sent, c_recv); $finish;
    end
endmodule
```

> 작성 시 정리: 위 `cyc` 직후의 잘못된 `prod_sat` always 스텁(주석 `간단화`)은 제거하고 하단 saturation monitor 블록만 사용. (plan 초안 메모 — 실제 파일엔 monitor 블록만 둔다.)

- [ ] **Step 2: 컴파일 + 실행 (test)**

Run: `iverilog -g2012 -o /tmp/o.vvp -y RTL/core -y RTL/conv1 -y RTL/conv2 -y RTL/maxpool -y RTL/fc RTL/conv2/weight_loader.v TB/models/dsp48e1_model.v TB/models/bmg_sim_models.v TB/models/handshake_bfm.v TB/multi_img/tb_conv1_engine_multi.v && vvp /tmp/o.vvp | tail -12`
Expected: 첫 실행에서 컴파일 통과 + 결과 출력. mismatch/assert 0 이 목표.

- [ ] **Step 3: 실패 시 디버그 (systematic-debugging)**

- conv1 이 트리거 안 됨(`recv=0`, timeout) → conv1 이 prior_wdone 만으로 안 도는 것. main 에서 `bfm_rst` 해제 직전 `conv1.start` 1-cyc pulse 추가 (conv1 port `.start(conv1_start)` 로 변경, reg 선언).
- mismatch 다수 + off-by-one(`got[N]==exp[N-1]`) → consumer READ_LAT 정렬 문제. (현재 L=2 = conv1 single 검증값과 동일하므로 발생 시 c1c2 가 다른 L 인지 재확인.)
- `cons_sat=0` 또는 `prod_sat=0` → backpressure 미발생. MAX_IDLE 를 3000~4000 로 상향.

- [ ] **Step 4: PASS + backpressure 증거 확인**

Expected 최종: `mismatch=0`, `assert_fail producer=0 consumer=0`, `recv=40`, `prod_sat>0 && cons_sat>0`, `*** PASS ***`.

- [ ] **Step 5: Commit**
```bash
git add TB/multi_img/tb_conv1_engine_multi.v
git commit -m "feat(tb): conv1 standalone multi-image handshake stress TB (random BFM)"
```

---

## Task 4: `tb_conv2_engine_multi.v` (덮어쓰기) — conv2 단독 stress

**Files:**
- Overwrite: `TB/multi_img/tb_conv2_engine_multi.v` (구 sequential 버전 폐기)

**배선:** producer→bram_c1_to_c2→conv2→bram_c2_to_pool→consumer. `conv2.prior_wdone←producer.prior_wdone`, `producer.rdone←conv2.rdone`, `conv2.succ_rdone←consumer.succ_rdone`, `consumer.wdone←conv2.wdone`. 입력 `all_c1c2.hex`(SRC_DW=64,DW=64,PACK=1,WORDS=1024,AW=11,WEA_W=8), 기대 `all_c2pool.hex`(DW=128,WORDS=576,AW=11). conv2 weight = c2w_* Port A 576 word(rst 중) + **conv2.start 1-cyc pulse**(LOAD_WEIGHTS, rst 해제 후).

- [ ] **Step 1: TB 작성 (full code)** — Task 3 과 동일 골격, 차이만:
  - `\`define` : `ALL_C1C2_HEX`(입력), `ALL_C2POOL_HEX`(기대), `CONV2_WEIGHT_HEX`.
  - DUT = `conv2_engine conv2 (.clk,.rst,.start(conv2_start), .c2w_ena/wea/addra/dina, .c1c2_re(in_renb),.c1c2_addr(in_raddr),.c1c2_dout(in_rdout), .c2pool_we/addr/din, .prior_wdone,.rdone,.succ_rdone,.wdone)`.
  - 입력 BMG = `bram_c1_to_c2`(producer writes A, conv2 reads B): producer `.SRC_DW(64),.DW(64),.WEA_W(8),.AW(11),.WORDS(1024),.IMG_HEX(\`ALL_C1C2_HEX)`.
  - 출력 BMG = `bram_c2_to_pool`(conv2 writes A `.wea(c2pool_we)`, consumer reads B, `.regceb(1'b1)`): consumer `.DW(128),.AW(11),.WORDS(576),.EXP_HEX(\`ALL_C2POOL_HEX),.SETTLE(3)`.
  - weight: `c2w_ena/wea[3:0]/addra[9:0]/dina[31:0]`, 576 word `load_w2()` (rst 중). main: rst 해제 → load_w2 → `@(negedge clk) conv2_start=1; @(negedge clk) conv2_start=0;` → repeat(4) → `bfm_rst=0`.
  - saturation monitor: `outstanding=p_sent-rdc`(rdc=conv2.rdone count), `available=wdc-c_recv`(wdc=conv2.wdone count) — Task 3 와 동일.

  핵심 instantiation (참고):
```verilog
    bram_c1_to_c2 in_bmg (.clka(clk),.ena(in_ena),.wea(in_wea),.addra(in_addra),.dina(in_dina),
        .clkb(clk),.enb(in_renb),.addrb(in_raddr),.doutb(in_rdout));
    bram_c2_to_pool out_bmg (.clka(clk),.ena(c2pool_we),.wea(c2pool_we),
        .addra(c2pool_addr),.dina(c2pool_din),
        .clkb(clk),.enb(c2_renb),.addrb(c2_raddr),.doutb(c2_rdout),.regceb(1'b1));
    conv2_engine conv2 (.clk(clk),.rst(rst),.start(conv2_start),
        .c2w_ena(c2w_ena),.c2w_wea(c2w_wea),.c2w_addra(c2w_addra),.c2w_dina(c2w_dina),
        .c1c2_re(in_renb),.c1c2_addr(in_raddr),.c1c2_dout(in_rdout),
        .c2pool_we(c2pool_we),.c2pool_addr(c2pool_addr),.c2pool_din(c2pool_din),
        .prior_wdone(prior_wdone),.rdone(rdone),.succ_rdone(succ_rdone),.wdone(wdone));
    producer_bfm #(.SRC_DW(64),.DW(64),.WEA_W(8),.AW(11),.WORDS(1024),
        .N_IMAGES(N_IMAGES),.IMG_HEX(`ALL_C1C2_HEX),.SEED(SEED_P),.MAX_IDLE(2000),.STALL_PCT(40),.SETTLE(2)) prod (
        .clk(clk),.rst(bfm_rst),.prior_wdone(prior_wdone),.rdone(rdone),
        .ena(in_ena),.wea(in_wea),.addra(in_addra),.dina(in_dina),
        .img_sent(p_sent),.assert_fail(p_af),.done(p_done));
    consumer_bfm #(.DW(128),.AW(11),.WORDS(576),.READ_LAT(2),
        .N_IMAGES(N_IMAGES),.EXP_HEX(`ALL_C2POOL_HEX),.SEED(SEED_C),.MAX_IDLE(2000),.SETTLE(3)) cons (
        .clk(clk),.rst(bfm_rst),.wdone(wdone),.succ_rdone(succ_rdone),
        .enb(c2_renb),.addrb(c2_raddr),.doutb(c2_rdout),
        .img_recv(c_recv),.mismatch_cnt(c_mm),.assert_fail(c_af),.done(c_done));
```

- [ ] **Step 2: 컴파일 + 실행**

Run: 공통 명령에 `TB/multi_img/tb_conv2_engine_multi.v`.
Expected: `mismatch=0`, `assert_fail=0/0`, `recv=40`, `prod_sat>0 && cons_sat>0`, `*** PASS ***`.

- [ ] **Step 3: 실패 시 디버그** — conv2 미트리거 시 start pulse 타이밍 점검(LOAD_WEIGHTS 후 DONE 진입 확인). mismatch off-by-one 시 L 재확인.

- [ ] **Step 4: Commit**
```bash
git add TB/multi_img/tb_conv2_engine_multi.v
git commit -m "feat(tb): rewrite conv2 multi TB with random-speed handshake BFM"
```

---

## Task 5: `tb_conv1_conv2_multi.v` (덮어쓰기) — conv1+conv2 통합 stress

**Files:**
- Overwrite: `TB/multi_img/tb_conv1_conv2_multi.v`

**배선:** producer→bram_input→conv1→bram_c1_to_c2(실 중간 BMG)→conv2→bram_c2_to_pool→consumer. **중간 핸드쉐이크 실 wire**: `conv2.prior_wdone = conv1.wdone`, `conv1.succ_rdone = conv2.rdone`. 경계: `conv1.prior_wdone←producer.prior_wdone`, `producer.rdone←conv1.rdone`, `consumer.wdone←conv2.wdone`, `conv2.succ_rdone←consumer.succ_rdone`. 입력 `all_input.hex`(Task 3 producer 파라미터), 기대 `all_c2pool.hex`(Task 4 consumer 파라미터). weight: conv1 36 + conv2 576 (rst 중) + conv2.start 1-cyc.

- [ ] **Step 1: TB 작성 (full code)** — 핵심 wiring:
```verilog
    wire c1_wdone, c2_rdone;     // 중간 핸드쉐이크
    // input BMG (producer→conv1)
    bram_input in_bmg (.clka(clk),.ena(in_ena),.wea(in_wea),.addra(in_addra),.dina(in_dina),
        .clkb(clk),.enb(in_enb),.addrb(in_addrb),.doutb(in_doutb));
    // 중간 c1c2 BMG (conv1→conv2, BFM 없음)
    bram_c1_to_c2 mid_bmg (.clka(clk),.ena(c1c2_we),.wea(c1c2_wea),.addra(c1c2_addr),.dina(c1c2_din),
        .clkb(clk),.enb(c1c2_re),.addrb(c1c2_raddr),.doutb(c1c2_rdout));
    // output c2pool BMG (conv2→consumer)
    bram_c2_to_pool out_bmg (.clka(clk),.ena(c2pool_we),.wea(c2pool_we),
        .addra(c2pool_addr),.dina(c2pool_din),
        .clkb(clk),.enb(c2_renb),.addrb(c2_raddr),.doutb(c2_rdout),.regceb(1'b1));

    conv1_engine conv1 (.clk(clk),.rst(rst),.start(1'b0),.done(),
        .prior_wdone(prior_wdone), .succ_rdone(c2_rdone), .rdone(c1_rdone), .wdone(c1_wdone),
        .in_bram_addr(in_addrb),.in_bram_en(in_enb),.in_bram_dout(in_doutb),
        .c1w_ena(c1w_ena),.c1w_wea(c1w_wea),.c1w_addra(c1w_addra),.c1w_dina(c1w_dina),
        .c1c2_we(c1c2_we),.c1c2_wea(c1c2_wea),.c1c2_addr(c1c2_addr),.c1c2_din(c1c2_din));

    conv2_engine conv2 (.clk(clk),.rst(rst),.start(conv2_start),
        .c2w_ena(c2w_ena),.c2w_wea(c2w_wea),.c2w_addra(c2w_addra),.c2w_dina(c2w_dina),
        .c1c2_re(c1c2_re),.c1c2_addr(c1c2_raddr),.c1c2_dout(c1c2_rdout),
        .c2pool_we(c2pool_we),.c2pool_addr(c2pool_addr),.c2pool_din(c2pool_din),
        .prior_wdone(c1_wdone), .rdone(c2_rdone), .succ_rdone(succ_rdone), .wdone(c2_wdone));

    producer_bfm #(.SRC_DW(8),.DW(32),.WEA_W(4),.AW(9),.WORDS(196),
        .N_IMAGES(N_IMAGES),.IMG_HEX(`ALL_INPUT_HEX),.SEED(SEED_P),.MAX_IDLE(2000),.STALL_PCT(40),.SETTLE(2)) prod (
        .clk(clk),.rst(bfm_rst),.prior_wdone(prior_wdone),.rdone(c1_rdone),
        .ena(in_ena),.wea(in_wea),.addra(in_addra),.dina(in_dina),
        .img_sent(p_sent),.assert_fail(p_af),.done(p_done));
    consumer_bfm #(.DW(128),.AW(11),.WORDS(576),.READ_LAT(2),
        .N_IMAGES(N_IMAGES),.EXP_HEX(`ALL_C2POOL_HEX),.SEED(SEED_C),.MAX_IDLE(2000),.SETTLE(3)) cons (
        .clk(clk),.rst(bfm_rst),.wdone(c2_wdone),.succ_rdone(succ_rdone),
        .enb(c2_renb),.addrb(c2_raddr),.doutb(c2_rdout),
        .img_recv(c_recv),.mismatch_cnt(c_mm),.assert_fail(c_af),.done(c_done));
```
  main: rst 해제 → load_w1 + load_w2 → conv2_start 1-cyc → repeat(4) → bfm_rst=0. saturation monitor: `outstanding=p_sent-c1_rdone_cnt`, `available=c2_wdone_cnt-c_recv`.

- [ ] **Step 2: 컴파일 + 실행**

Run: 공통 명령 + `TB/multi_img/tb_conv1_conv2_multi.v`.
Expected: `mismatch=0`, `assert_fail=0/0`, `recv=40`, `prod_sat>0 && cons_sat>0`, `*** PASS ***`.

- [ ] **Step 3: 실패 시 디버그** — 통합은 conv1 의 bank race fix(`bank_sel_pipe`) 가 random pacing 에서 검증되는 지점. img≥1 에서 (25,25) 부근 mismatch 가 보이면 `docs/conv1_timing_table.md` §4 의 잔존 race → 사용자에게 보고(엔진 이슈, TB 가 정확히 검출). 단순 트리거/타이밍 문제와 구분.

- [ ] **Step 4: Commit**
```bash
git add TB/multi_img/tb_conv1_conv2_multi.v
git commit -m "feat(tb): rewrite conv1+conv2 integration multi TB with real wire handshake + random BFM"
```

---

## Task 6: 회귀 + seed 스윕 + 메모리

**Files:** 없음(검증) 또는 미세 튜닝.

- [ ] **Step 1: 6개 TB 전체 회귀**

단일 3(conv1/conv2/conv1_conv2) + 멀티 3 전부 컴파일+실행. 모두 PASS, assert 0.

- [ ] **Step 2: seed 스윕 (난수 강건성)**

멀티 3종을 `SEED_P/SEED_C` 2~3 조합으로 재실행 (TB 파라미터 override: `iverilog ... -P tb_conv1_engine_multi.SEED_P=16'h... ` 또는 파일 내 파라미터 수정 후). 전부 PASS + backpressure 발생 확인.

- [ ] **Step 3: backpressure 증거 최종 확인**

멀티 3종 로그에 `prod_sat>0` (입력측 credit 포화) **및** `cons_sat>0` (출력측 포화) 가 모두 찍히는지 확인 → 양방향 backpressure 실증. 안 찍히면 `MAX_IDLE` 상향 후 재확인 (silent 미달 금지 — 로그로 명시).

- [ ] **Step 4: 메모리 갱신**

`~/.claude/projects/.../memory/` 에 핸드쉐이크 stress TB 사실 기록 (BFM 모듈 위치, credit 규칙, conv1 wdone+1 last-write settle, L=2 readback, iverilog 명령에 handshake_bfm.v 추가). `iverilog-local-sim.md` 업데이트 또는 신규.

- [ ] **Step 5: 최종 커밋 (튜닝 있었으면)**
```bash
git add -A TB/ && git commit -m "test(tb): conv1/conv2 handshake stress regression + seed sweep"
```

---

## Self-Review (spec 대비)

- §1 진단(L=2, 경로, sequential) → Task 1(L=2) + Task 3~5(BFM 경로 통일/random) ✓
- §3 핸드쉐이크 프로토콜 → BFM credit/bank 로직(Task 2) + 실 wire 통합(Task 5) ✓
- §4 BFM(파라미터/동작/assertion) → Task 2 full code ✓ (단 §4.2 gapped→연속 read 정련: Deviations 명시)
- §5 멀티 3종 배선 → Task 3/4/5 ✓
- §6 단일 L=2 → Task 1 ✓
- §7 파일 계획 → File Structure + Task 별 create/overwrite ✓
- §8 검증(backpressure 증거, seed 스윕) → Task 6 ✓
- Placeholder scan: Task 3 의 `cyc` 직후 스텁 always 는 "초안 메모"로 명시 제거 지시함 — 실제 파일엔 monitor 블록만. 그 외 placeholder 없음.
- Type 일관성: BFM 포트/파라미터명(`img_sent`,`assert_fail`,`mismatch_cnt`,`img_recv`,`prior_wdone`,`succ_rdone`)이 Task 3~5 instantiation 과 일치 ✓.
