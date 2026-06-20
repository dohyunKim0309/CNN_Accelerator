`timescale 1ns / 1ps
//==============================================================================
// handshake_bfm.v — 임의 속도 가상 앞/뒷단 BFM (시뮬 전용)
//
//   producer_bfm : 입력 ping-pong BRAM Port A 를 채우고 prior_wdone 발행,
//                  엔진 rdone 으로 credit(outstanding < 2) 관리.
//   consumer_bfm : 출력 ping-pong BRAM Port B 를 비우고 succ_rdone 발행,
//                  엔진 wdone 감시 + bit-exact 비교 + 프로토콜 assertion.
//
//   난수: 16-bit Galois LFSR (SEED 파라미터) — 결정론적/재현가능. 입출력 BFM 에
//         서로 다른 SEED 를 주면 독립 난수 스트림 → 양방향 random backpressure.
//
//   credit/bank/타이밍 근거:
//     docs/superpowers/specs/2026-06-20-conv12-handshake-stress-tb-design.md
//     docs/conv1_timing_table.md (conv1: 마지막 c1c2 write @ wdone+1 → consumer SETTLE)
//     RTL/conv2/conv2_timing.md  (conv2: wdone @ 1796, 1-cycle)
//
//   ★ bmg_sim_models.v 와 달리 Vivado 에서도 소스에 포함할 것 (실제 자극원).
//==============================================================================


//==============================================================================
// producer_bfm — 상류(앞단): 입력 BRAM Port A write + prior_wdone, rdone credit
//
//   엔진의 입력 ping-pong (2 bank) 을 채운다. 이미지 i 는 bank i&1 에 쓰고,
//   outstanding = (보낸 수) − (엔진 rdone 수) 가 < 2 일 때만 다음 이미지를 쓴다
//   (= 엔진이 아직 안 읽은 bank 를 덮어쓰지 않음). 쓰기 완료 후 prior_wdone 1-cyc.
//
//   SRC_DW/DW/PACK 로 비대칭(bram_input: 8→32, PACK=4)과 대칭(c1c2: 64→64, PACK=1)
//   BRAM 을 한 모듈로 처리.
//==============================================================================
module producer_bfm #(
    parameter integer SRC_DW    = 8,        // 입력 hex element 폭 (bram_input=8, c1c2=64)
    parameter integer DW        = 32,       // BRAM Port A write 폭   (bram_input=32, c1c2=64)
    parameter integer WEA_W     = 4,        // wea 폭 (bram_input=4, c1c2=8)
    parameter integer AW        = 9,        // Port A addr 폭; bank = addr[AW-1]
    parameter integer WORDS     = 196,      // 이미지당 word 수
    parameter integer N_IMAGES  = 40,
    parameter         IMG_HEX   = "data/multi_img/all_input.hex",
    parameter [15:0]  SEED      = 16'hACE1,
    parameter integer MAX_IDLE  = 2000,     // 이미지간 random idle 상한 (cyc)
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

    // 엔진 rdone counter (credit source)
    reg [31:0] rdone_cnt;
    always @(posedge clk) if (rst) rdone_cnt <= 32'd0; else if (rdone) rdone_cnt <= rdone_cnt + 1;

    // 16-bit Galois LFSR (taps 0xB400)
    reg [15:0] lfsr;
    function [15:0] lfsr_nxt;
        input [15:0] s;
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
            // 이미지간 random idle
            lfsr = lfsr_nxt(lfsr); idle = lfsr % (MAX_IDLE + 1);
            for (j = 0; j < idle; j = j + 1) @(negedge clk);
            // credit: outstanding < 2 (입력 bank 여유 대기)
            while ((img_sent - rdone_cnt) >= 2) @(negedge clk);
            // bank img_sent[0] 에 WORDS word write
            for (k = 0; k < WORDS; k = k + 1) begin
                lfsr = lfsr_nxt(lfsr);
                if (lfsr[7:0] < STALL_PCT) begin ena = 1'b0; wea = {WEA_W{1'b0}}; @(negedge clk); end
                word = {DW{1'b0}};
                for (j = 0; j < PACK; j = j + 1)
                    word[j*SRC_DW +: SRC_DW] = src_mem[img*WORDS*PACK + k*PACK + j];
                ena   = 1'b1;
                wea   = {WEA_W{1'b1}};
                addra = {img_sent[0], k[AW-2:0]};
                dina  = word;
                @(negedge clk);
            end
            ena = 1'b0; wea = {WEA_W{1'b0}};
            for (s = 0; s < SETTLE; s = s + 1) @(negedge clk);
            prior_wdone = 1'b1; @(negedge clk); prior_wdone = 1'b0;
            img_sent = img_sent + 1;
        end
        done = 1'b1;
    end

    // 프로토콜 assertion (negedge: img_sent / rdone_cnt 안정 시점)
    always @(negedge clk) if (!rst) begin
        if (rdone_cnt > img_sent)        assert_fail = assert_fail + 1; // 안 보낸 bank 를 엔진이 read
        if ((img_sent - rdone_cnt) > 2)  assert_fail = assert_fail + 1; // credit overflow (>2 outstanding)
    end
endmodule


//==============================================================================
// consumer_bfm — 하류(뒷단): 출력 BRAM Port B read + succ_rdone, wdone 감시
//
//   엔진 wdone 마다 available = (엔진 wdone 수) − (소비한 수) 가 > 0 이면 bank
//   img_recv&1 을 읽어 exp_mem 과 bit-exact 비교, 완료 후 succ_rdone 1-cyc.
//   읽기는 연속(gap 없음) — bram_c1_to_c2(enb-gated 양 stage)와 bram_c2_to_pool
//   (regceb always-follow) 양쪽에서 동일한 L=READ_LAT 정렬 성립 (conv1 single 검증 패턴).
//   SETTLE: conv1 의 마지막 c1c2 write 가 wdone+1 cycle 이므로 wdone 후 최소 대기.
//==============================================================================
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

    // 엔진 wdone counter (availability source)
    reg [31:0] wdone_cnt;
    always @(posedge clk) if (rst) wdone_cnt <= 32'd0; else if (wdone) wdone_cnt <= wdone_cnt + 1;

    reg [15:0] lfsr;
    function [15:0] lfsr_nxt;
        input [15:0] s;
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
            // 이미지간 random idle (consumer backpressure)
            lfsr = lfsr_nxt(lfsr); idle = lfsr % (MAX_IDLE + 1);
            for (j = 0; j < idle; j = j + 1) @(negedge clk);
            // availability: 엔진이 생산한 미소비 이미지 존재 대기
            while (wdone_cnt <= img_recv) @(negedge clk);
            // settle (conv1: 마지막 c1c2 write 가 wdone+1)
            for (j = 0; j < SETTLE; j = j + 1) @(negedge clk);
            bank = img_recv[0];
            mm   = 0;
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

    // 프로토콜 assertion
    always @(negedge clk) if (!rst) begin
        if (wdone_cnt < img_recv)        assert_fail = assert_fail + 1;
        if ((wdone_cnt - img_recv) > 2)  assert_fail = assert_fail + 1; // 엔진 output_avail(after_diff<2) 위반
    end
endmodule
