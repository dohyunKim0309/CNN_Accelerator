`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_fc_engine.v  (single image — RTL_single 용)
//
//   RTL_single/fc/fc_engine.v 검증
//   ping-pong / handshake 카운터 없음
//   poolfc 주소: 8-bit (s_cnt 직접, bank 없음)
//
//   자극 순서:
//     reset → load_weights → init_poolfc → prior_wdone pulse → wait class_valid → check
//////////////////////////////////////////////////////////////////////////////////

`define DATA_DIR    "data_single"
`define POOLFC_HEX  `DATA_DIR "/maxpool_output.hex"
`define FCW_HEX     `DATA_DIR "/fc_weights_simd.hex"

module tb_fc_engine;

    parameter ACC_W      = 24;
    parameter CLK_PERIOD = 10;

    // Expected logits
    localparam signed [23:0] EXP_OC0 = 24'h00010B;
    localparam signed [23:0] EXP_OC1 = 24'hFFF885;
    localparam signed [23:0] EXP_OC2 = 24'h000AF9;
    localparam signed [23:0] EXP_OC3 = 24'h001ABC;
    localparam signed [23:0] EXP_OC4 = 24'hFFED99;
    localparam signed [23:0] EXP_OC5 = 24'h00255D;
    localparam signed [23:0] EXP_OC6 = 24'h00067A;
    localparam signed [23:0] EXP_OC7 = 24'h001231;
    localparam signed [23:0] EXP_OC8 = 24'h000D6B;
    localparam signed [23:0] EXP_OC9 = 24'h000D7A;
    localparam       [3:0]   EXP_CLS = 4'd5;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    // DUT 포트
    reg          start       = 1'b0;
    reg          prior_wdone = 1'b0;
    wire [3:0]   class_idx;
    wire         class_valid;

    // FC weight BRAM Port A
    reg          fcw_ena     = 1'b0;
    reg  [3:0]   fcw_wea     = 4'd0;
    reg  [12:0]  fcw_addra   = 13'd0;
    reg  [31:0]  fcw_dina    = 32'd0;

    // poolfc (8-bit addr, 128-bit)
    wire         poolfc_re;
    wire [7:0]   poolfc_addr;
    reg  [127:0] poolfc_dout = 128'd0;

    //--------------------------------------------------------------------------
    // poolfc behavioral mem (8-bit addr = 256 entries, 128-bit each)
    //--------------------------------------------------------------------------
    reg [7:0]   poolfc_byte_mem [0:2303];
    reg [127:0] poolfc_mem      [0:255];

    initial begin : poolfc_init
        integer s, c;
        for (s = 0; s < 256; s = s + 1) poolfc_mem[s] = 128'd0;
        $readmemh(`POOLFC_HEX, poolfc_byte_mem, 0, 2303);
        // channel-major → spatial-major 변환
        for (s = 0; s < 144; s = s + 1)
            for (c = 0; c < 16; c = c + 1)
                poolfc_mem[s][c*8 +: 8] = poolfc_byte_mem[c*144 + s];
    end

    always @(posedge clk) begin
        if (poolfc_re)
            poolfc_dout <= poolfc_mem[poolfc_addr];
    end

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    fc_engine #(.ACC_W(ACC_W)) dut (
        .clk         (clk), .rst(rst),
        .start       (start),

        .fcw_ena     (fcw_ena), .fcw_wea(fcw_wea),
        .fcw_addra   (fcw_addra), .fcw_dina(fcw_dina),

        .poolfc_re   (poolfc_re),
        .poolfc_addr (poolfc_addr),
        .poolfc_dout (poolfc_dout),

        .prior_wdone (prior_wdone),

        .class_idx   (class_idx),
        .class_valid (class_valid)
    );

    //--------------------------------------------------------------------------
    // Weight loader task
    //--------------------------------------------------------------------------
    reg [31:0] weight_simd_mem [0:11519];

    task load_weights;
        integer pair, s, c, k, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed  [7:0] w1_packed_8;
        reg [127:0]       w_even_concat, w_odd_concat;
        reg [255:0]       word;
        begin
            $readmemh(`FCW_HEX, weight_simd_mem);
            $display("[TB] %s loaded.", `FCW_HEX);

            for (pair = 0; pair < 5; pair = pair + 1) begin
                for (s = 0; s < 144; s = s + 1) begin
                    w_even_concat = 128'd0;
                    w_odd_concat  = 128'd0;
                    for (c = 0; c < 16; c = c + 1) begin
                        line_idx     = pair*144*16 + s*16 + c;
                        w0_packed_17 = $signed(weight_simd_mem[line_idx][16:0]);
                        w1_packed_8  = $signed(weight_simd_mem[line_idx][24:17]);
                        w0 = w0_packed_17[7:0];
                        w1 = w1_packed_8 + (w0_packed_17[16] ? 8'sd1 : 8'sd0);
                        w_even_concat[c*8 +: 8] = w0;
                        w_odd_concat [c*8 +: 8] = w1;
                    end
                    word = {w_odd_concat, w_even_concat};
                    for (k = 0; k < 8; k = k + 1) begin
                        @(negedge clk);
                        fcw_ena   = 1'b1; fcw_wea = 4'hF;
                        fcw_addra = (pair*144 + s)*8 + k;
                        fcw_dina  = word[k*32 +: 32];
                    end
                end
            end
            @(negedge clk);
            fcw_ena = 1'b0; fcw_wea = 4'd0;
            $display("[TB] Weight BRAM write done.");
        end
    endtask

    //--------------------------------------------------------------------------
    // Cycle counter
    //--------------------------------------------------------------------------
    integer cycle_cnt = 0;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //--------------------------------------------------------------------------
    // Logit 검증 (logit_valid 마다 확인)
    //--------------------------------------------------------------------------
    wire                    logit_valid_w = dut.logit_valid;
    wire [2:0]              acc_pair_w    = dut.acc_pair_latch;

    reg                     lv_d1   = 1'b0;
    reg [2:0]               pair_d1 = 3'd0;
    always @(posedge clk) begin
        lv_d1   <= logit_valid_w;
        pair_d1 <= acc_pair_w;
    end

    wire signed [ACC_W-1:0] lr [0:9];
    assign lr[0] = dut.logit_reg[0]; assign lr[1] = dut.logit_reg[1];
    assign lr[2] = dut.logit_reg[2]; assign lr[3] = dut.logit_reg[3];
    assign lr[4] = dut.logit_reg[4]; assign lr[5] = dut.logit_reg[5];
    assign lr[6] = dut.logit_reg[6]; assign lr[7] = dut.logit_reg[7];
    assign lr[8] = dut.logit_reg[8]; assign lr[9] = dut.logit_reg[9];

    integer pass_cnt = 0, fail_cnt = 0, pair_done_cnt = 0;

    task check_pair;
        input [3:0]   oc_even, oc_odd;
        input signed [23:0] got0, got1, exp0, exp1;
        begin
            $display("---------------------------------------------------------");
            $display("[LOGIT] OC%0d/OC%0d @ cyc=%0d", oc_even, oc_odd, cycle_cnt);
            if (got0 === exp0) begin
                $display("  OC%0d : PASS  %0d", oc_even, $signed(got0));
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d exp=%0d diff=%0d",
                    oc_even, $signed(got0), $signed(exp0), $signed(got0)-$signed(exp0));
                fail_cnt = fail_cnt + 1;
            end
            if (got1 === exp1) begin
                $display("  OC%0d : PASS  %0d", oc_odd, $signed(got1));
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d exp=%0d diff=%0d",
                    oc_odd, $signed(got1), $signed(exp1), $signed(got1)-$signed(exp1));
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (lv_d1) begin
            pair_done_cnt = pair_done_cnt + 1;
            case (pair_d1)
                3'd0: check_pair(0,1, lr[0][23:0],lr[1][23:0], EXP_OC0,EXP_OC1);
                3'd1: check_pair(2,3, lr[2][23:0],lr[3][23:0], EXP_OC2,EXP_OC3);
                3'd2: check_pair(4,5, lr[4][23:0],lr[5][23:0], EXP_OC4,EXP_OC5);
                3'd3: check_pair(6,7, lr[6][23:0],lr[7][23:0], EXP_OC6,EXP_OC7);
                3'd4: check_pair(8,9, lr[8][23:0],lr[9][23:0], EXP_OC8,EXP_OC9);
                default: $display("[WARN] unexpected pair_d1=%0d", pair_d1);
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Main
    //--------------------------------------------------------------------------
    integer timeout_cnt;
    initial begin
        $display("============================================================");
        $display("[TB] tb_fc_engine (RTL_single) — single-image verification");
        $display("============================================================");

        rst = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] cyc=%0d : reset released", cycle_cnt);

        load_weights();
        repeat (3) @(posedge clk);

        // prior_wdone: 이미지 처리 시작 트리거
        @(negedge clk); prior_wdone = 1'b1;
        @(negedge clk); prior_wdone = 1'b0;
        $display("[TB] cyc=%0d : prior_wdone pulsed", cycle_cnt);

        // class_valid 대기
        timeout_cnt = 0;
        while (!class_valid && timeout_cnt < 2000) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        if (!class_valid) begin
            $display("[TB] *** TIMEOUT *** class_valid never asserted");
            fail_cnt = fail_cnt + 1;
        end
        repeat (5) @(posedge clk);

        $display("============================================================");
        $display("[FINAL]");
        $display("  pair_done_cnt   = %0d / 5", pair_done_cnt);
        $display("  logit pass/fail = %0d / %0d", pass_cnt, fail_cnt);
        $display("  class_idx       = %0d (expected %0d) — %s",
                 class_idx, EXP_CLS, (class_idx == EXP_CLS) ? "PASS" : "FAIL");
        if (fail_cnt == 0 && pair_done_cnt == 5 && class_idx == EXP_CLS)
            $display("[FINAL] *** ALL PASS ***");
        else
            $display("[FINAL] *** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_fc_engine_single.vcd");
        $dumpvars(0, tb_fc_engine);
    end

endmodule


//==============================================================================
// fc_weight_bram behavioral model
//   Asymmetric: Port A 32b × 5760 write / Port B 256b × 720 read (L=1)
//==============================================================================
module fc_weight_bram (
    input  wire         clka,
    input  wire         ena,
    input  wire [3:0]   wea,
    input  wire [12:0]  addra,
    input  wire [31:0]  dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [9:0]   addrb,
    output reg  [255:0] doutb
);
    reg [31:0] mem [0:5759];
    integer mi, k;
    initial begin
        for (mi = 0; mi < 5760; mi = mi + 1) mem[mi] = 32'd0;
        doutb = 256'd0;
    end
    always @(posedge clka) begin
        if (ena) begin
            if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
            if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
            if (wea[2]) mem[addra][23:16] <= dina[23:16];
            if (wea[3]) mem[addra][31:24] <= dina[31:24];
        end
    end
    always @(posedge clkb) begin
        if (enb)
            for (k = 0; k < 8; k = k + 1)
                doutb[k*32 +: 32] <= mem[addrb*8 + k];
    end
endmodule
