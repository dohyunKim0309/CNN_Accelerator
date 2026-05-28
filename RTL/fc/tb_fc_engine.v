`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fc_engine (2026-05-29 update)
//
// 변경사항:
//   1. hex 경로: project data/ 폴더 기준 (data/single_img/, data/weights_simd/)
//   2. maxpool_output.hex 포맷: 1 byte/line, channel-major flatten
//      - shape (16, 12, 12) → byte at line c*144 + s where s = h*12 + w
//      - TB 가 byte stream 을 spatial-major 128-bit/word 로 재조립
//   3. fc_weights_simd.hex 포맷: 32-bit/line SIMD-packed (W1*2^17 + W0)
//      - 11520 lines = 5 pair × 144 spatial × 16 channel
//      - line index = pair*144*16 + s*16 + c
//      - TB 가 unpack 하여 (w_even, w_odd) 분리 후 256-bit BMG word 조립
//   4. fc_engine port 변경 반영:
//      - poolfc_addr: 10-bit → 9-bit
//      - fc_weight_bram: ENA + WEA 분리 결선
//   5. RTL/fc/maxpool_output.hex, fc1_weight_bram.hex (구 포맷) 삭제됨
//
// SIMD unpack 식:
//   W0 (8-bit signed) = packed[7:0]
//   W1 (8-bit signed) = packed[24:17] + (packed[16] ? 1 : 0)
//                       ↑ carry correction (negative W0 시)
//////////////////////////////////////////////////////////////////////////////////

// 경로는 Vivado sim 환경에 맞춰 조정. project root 기준 data/ 폴더.
`define POOLFC_HEX  "C:/Users/gimdohyeon/PycharmProjects/CNN_Accelerator/data/single_img/maxpool_output.hex"
`define FCW_HEX     "C:/Users/gimdohyeon/PycharmProjects/CNN_Accelerator/data/weights_simd/fc_weights_simd.hex"

module tb_fc_engine;

    //==========================================================================
    // 파라미터
    //==========================================================================
    parameter ACC_W      = 24;
    parameter CLK_PERIOD = 10;

    //==========================================================================
    // 기대 logit
    //==========================================================================
    localparam [23:0] EXP_OC0 = 24'h00010B;  //   267
    localparam [23:0] EXP_OC1 = 24'hFFF885;  // -1915
    localparam [23:0] EXP_OC2 = 24'h000AF9;  //  2809
    localparam [23:0] EXP_OC3 = 24'h001ABC;  //  6844
    localparam [23:0] EXP_OC4 = 24'hFFED99;  // -4711
    localparam [23:0] EXP_OC5 = 24'h00255D;  //  9565
    localparam [23:0] EXP_OC6 = 24'h00067A;  //  1658
    localparam [23:0] EXP_OC7 = 24'h001231;  //  4657
    localparam [23:0] EXP_OC8 = 24'h000D6B;  //  3435
    localparam [23:0] EXP_OC9 = 24'h000D7A;  //  3450

    //==========================================================================
    // 클럭 / 리셋
    //==========================================================================
    reg clk = 0;
    reg rst = 1;
    always #(CLK_PERIOD/2) clk = ~clk;

    //==========================================================================
    // DUT 포트
    //==========================================================================
    reg          start_r     = 0;
    reg          fcw_ena     = 0;
    reg  [9:0]   fcw_addra   = 0;
    reg  [255:0] fcw_dina    = 0;
    wire         poolfc_re;
    wire [8:0]   poolfc_addr;          // 9-bit (= bank_sel + s_cnt[7:0])
    reg  [127:0] poolfc_dout = 128'd0;
    reg          prior_wdone = 0;
    wire         rdone;
    wire [3:0]   class_idx;
    wire         class_valid;

    fc_engine #(.ACC_W(ACC_W)) dut (
        .clk(clk), .rst(rst), .start(start_r),
        .fcw_ena(fcw_ena), .fcw_addra(fcw_addra), .fcw_dina(fcw_dina),
        .poolfc_re(poolfc_re), .poolfc_addr(poolfc_addr), .poolfc_dout(poolfc_dout),
        .prior_wdone(prior_wdone), .rdone(rdone),
        .class_idx(class_idx), .class_valid(class_valid)
    );

    //==========================================================================
    // poolfc 버퍼 (depth 512, 128-bit per word, 1-cycle latency)
    //
    // hex 포맷 (new):
    //   2304 lines × 8-bit = pooled.flatten() (shape (16, 12, 12))
    //   line c*144 + s = channel c, spatial s (= h*12 + w)
    //
    // TB 가 byte array → spatial-major 128-bit 재조립:
    //   poolfc_mem[s][c*8 +: 8] = byte_mem[c*144 + s]
    //   bank 0: s=0..143. bank 1: s=144..287 (= bank 0 copy, single-image 용).
    //==========================================================================
    reg  [7:0]   poolfc_byte_mem [0:2303];
    reg  [127:0] poolfc_mem      [0:511];

    initial begin : poolfc_init
        integer s, c;
        $readmemh(`POOLFC_HEX, poolfc_byte_mem, 0, 2303);
        $display("[TB] %s loaded (%0d bytes)", `POOLFC_HEX, 2304);

        // bank 0: 16 byte → 128-bit per spatial (channel-major → spatial-major)
        for (s = 0; s < 144; s = s + 1) begin
            for (c = 0; c < 16; c = c + 1) begin
                poolfc_mem[s][c*8 +: 8] = poolfc_byte_mem[c*144 + s];
            end
        end
        // bank 1: copy bank 0 (single-image test 용 — ping-pong 검증 시 별도 데이터 필요)
        for (s = 144; s < 288; s = s + 1) begin
            poolfc_mem[s] = poolfc_mem[s - 144];
        end
        // depth 288..511 = padding, 0 유지.
        for (s = 288; s < 512; s = s + 1) begin
            poolfc_mem[s] = 128'd0;
        end
    end

    always @(posedge clk) begin
        if (poolfc_re)
            poolfc_dout <= poolfc_mem[poolfc_addr];
    end

    //==========================================================================
    // Weight BRAM 로드 (SIMD-packed → 256-bit unpack 후 write)
    //
    // hex 포맷 (new):
    //   11520 lines × 32-bit SIMD-packed
    //   line pair*144*16 + s*16 + c = packed weight for (pair, spatial, channel)
    //   packed = (W1 * 2^17 + W0) & 0x1FFFFFF  (25-bit pattern, MSB 7 = 0)
    //     W0 (8-bit signed) = even OC weight
    //     W1 (8-bit signed) = odd  OC weight
    //
    // SIMD unpack:
    //   W0 = packed[7:0]                            (= packed[16:0] truncated)
    //   W1 = packed[24:17] + (packed[16] ? 1 : 0)   (carry correction, W0<0 시)
    //
    // BMG 256-bit 조립 (per pair, spatial):
    //   dina[127:0]  = {w0_ch15, w0_ch14, ..., w0_ch0}   (even OC, 16 ch concat)
    //   dina[255:128]= {w1_ch15, w1_ch14, ..., w1_ch0}   (odd  OC, 16 ch concat)
    //==========================================================================
    reg [31:0] weight_simd_mem [0:11519];

    task load_weights;
        integer pair, s, c, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed [7:0]  w1_packed_8;
        reg [127:0]       w_even_concat, w_odd_concat;
        begin
            $readmemh(`FCW_HEX, weight_simd_mem);
            $display("[TB] %s loaded (%0d entries)", `FCW_HEX, 11520);

            for (pair = 0; pair < 5; pair = pair + 1) begin
                for (s = 0; s < 144; s = s + 1) begin
                    w_even_concat = 128'd0;
                    w_odd_concat  = 128'd0;
                    for (c = 0; c < 16; c = c + 1) begin
                        line_idx     = pair*144*16 + s*16 + c;
                        w0_packed_17 = $signed(weight_simd_mem[line_idx][16:0]);
                        w1_packed_8  = $signed(weight_simd_mem[line_idx][24:17]);
                        // unpack
                        w0 = w0_packed_17[7:0];
                        w1 = w1_packed_8 + (w0_packed_17[16] ? 8'sd1 : 8'sd0);
                        // concat: ch c 의 weight 를 [c*8 +: 8] 위치에
                        w_even_concat[c*8 +: 8] = w0;
                        w_odd_concat [c*8 +: 8] = w1;
                    end

                    @(negedge clk);
                    fcw_ena   = 1;
                    fcw_addra = pair * 144 + s;
                    // BMG 256-bit: MSB = odd, LSB = even (engine 의 unpacking 정합)
                    fcw_dina  = {w_odd_concat, w_even_concat};
                end
            end
            @(negedge clk); fcw_ena = 0; fcw_addra = 0; fcw_dina = 0;
            @(posedge clk);
            $display("[TB] Weight BRAM write done (720 entries)");
        end
    endtask

    //==========================================================================
    // 내부 신호 tap
    //==========================================================================
    wire                    logit_valid_w = dut.logit_valid;
    wire [2:0]              acc_pair_w    = dut.acc_pair_latch;  // latch된 pair 사용

    wire signed [ACC_W-1:0] lr [0:9];
    assign lr[0] = dut.logit_reg[0]; assign lr[1] = dut.logit_reg[1];
    assign lr[2] = dut.logit_reg[2]; assign lr[3] = dut.logit_reg[3];
    assign lr[4] = dut.logit_reg[4]; assign lr[5] = dut.logit_reg[5];
    assign lr[6] = dut.logit_reg[6]; assign lr[7] = dut.logit_reg[7];
    assign lr[8] = dut.logit_reg[8]; assign lr[9] = dut.logit_reg[9];

    //==========================================================================
    // 검증
    //==========================================================================
    integer pair_done_cnt = 0;
    integer pass_cnt      = 0;
    integer fail_cnt      = 0;

    reg       lv_d1   = 0;
    reg [2:0] pair_d1 = 0;
    always @(posedge clk) begin
        lv_d1   <= logit_valid_w;
        pair_d1 <= acc_pair_w;
    end

    task check_pair;
        input [3:0]  oc_even;
        input [3:0]  oc_odd;
        input [23:0] got0, got1;
        input [23:0] exp0, exp1;
        reg pass0, pass1;
        begin
            pass0 = (got0 === exp0);
            pass1 = (got1 === exp1);
            $display("------------------------------------------------------------");
            $display("[LOGIT] OC%0d / OC%0d  @ %0t ns", oc_even, oc_odd, $time);
            if (pass0) begin
                $display("  OC%0d : PASS  %0d  (0x%06H)", oc_even, $signed(got0), got0);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d (0x%06H)  exp=%0d (0x%06H)  diff=%0d",
                    oc_even, $signed(got0), got0, $signed(exp0), exp0,
                    $signed(got0) - $signed(exp0));
                fail_cnt = fail_cnt + 1;
            end
            if (pass1) begin
                $display("  OC%0d : PASS  %0d  (0x%06H)", oc_odd, $signed(got1), got1);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  OC%0d : FAIL  got=%0d (0x%06H)  exp=%0d (0x%06H)  diff=%0d",
                    oc_odd, $signed(got1), got1, $signed(exp1), exp1,
                    $signed(got1) - $signed(exp1));
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (lv_d1) begin
            pair_done_cnt = pair_done_cnt + 1;
            case (pair_d1)
                3'd0: check_pair(0, 1, lr[0][23:0], lr[1][23:0], EXP_OC0, EXP_OC1);
                3'd1: check_pair(2, 3, lr[2][23:0], lr[3][23:0], EXP_OC2, EXP_OC3);
                3'd2: check_pair(4, 5, lr[4][23:0], lr[5][23:0], EXP_OC4, EXP_OC5);
                3'd3: check_pair(6, 7, lr[6][23:0], lr[7][23:0], EXP_OC6, EXP_OC7);
                3'd4: check_pair(8, 9, lr[8][23:0], lr[9][23:0], EXP_OC8, EXP_OC9);
                default:
                    $display("[WARN] unexpected pair_d1=%0d @ %0t ns", pair_d1, $time);
            endcase
        end
    end

    //==========================================================================
    // FSM 모니터
    //==========================================================================
    reg [1:0] prev_state = 2'd0;
    always @(posedge clk) begin
        if (dut.fsm_inst.state !== prev_state) begin
            case (dut.fsm_inst.state)
                2'd0: $display("[FSM] IDLE    @ %0t ns", $time);
                2'd1: $display("[FSM] COMPUTE @ %0t ns", $time);
                2'd2: $display("[FSM] DRAIN   @ %0t ns", $time);
                2'd3: $display("[FSM] DONE    @ %0t ns", $time);
            endcase
            prev_state <= dut.fsm_inst.state;
        end
    end

    reg [2:0] prev_pair_mon = 3'd7;
    always @(posedge clk) begin
        if (dut.fsm_inst.state == 2'd1 &&
            dut.fsm_pair_cnt !== prev_pair_mon) begin
            $display("[FSM] pair=%0d started  wbase=%0d  @ %0t ns",
                      dut.fsm_pair_cnt, dut.fsm_wbase, $time);
            prev_pair_mon <= dut.fsm_pair_cnt;
        end
    end

    //==========================================================================
    // 메인 시퀀스
    //==========================================================================
    integer timeout_cnt;

    initial begin
        $display("============================================================");
        $display("[TB] fc_engine — logit verification (pre-argmax)");
        $display("     ACC_W=%0d, CLK_PERIOD=%0d ns", ACC_W, CLK_PERIOD);
        $display("============================================================");

        rst = 1;
        repeat(5) @(posedge clk);
        @(negedge clk); rst = 0;
        $display("[TB] Reset released @ %0t ns", $time);

        load_weights();
        repeat(3) @(posedge clk);

        @(negedge clk); prior_wdone = 1;
        @(negedge clk); prior_wdone = 0;
        @(negedge clk); start_r = 1;
        @(negedge clk); start_r = 0;
        $display("[TB] Start issued @ %0t ns", $time);

        timeout_cnt = 0;
        while (pair_done_cnt < 5 && timeout_cnt < 25000) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        repeat(5) @(posedge clk);

        $display("============================================================");
        if (timeout_cnt >= 25000)
            $display("[TIMEOUT] pair_done=%0d/5", pair_done_cnt);
        else
            $display("[INFO] 5 pairs completed in %0d cycles", timeout_cnt);

        $display("  PASS : %0d / 10", pass_cnt);
        $display("  FAIL : %0d / 10", fail_cnt);
        $display("------------------------------------------------------------");
        if (fail_cnt == 0 && pair_done_cnt == 5)
            $display("[FINAL] *** ALL PASS *** logit values correct (pre-argmax)");
        else if (fail_cnt > 0)
            $display("[FINAL] *** FAIL *** logit mismatch");
        else
            $display("[FINAL] *** INCOMPLETE *** pair 미완료");
        $display("============================================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_fc_engine.vcd");
        $dumpvars(0, tb_fc_engine);
    end

endmodule


//==============================================================================
// fc_weight_bram behavioral model
// Simple Dual-Port, 256-bit × 1024 (BMG spec depth; 720 entries 사용)
// Port A: write only — ENA + WEA 둘 다 결선 필수 (Byte Write Disable + Use ENA Pin)
// Port B: read with L=1 (Primitive Output Register Disable)
//
// Write: ena=1 AND wea=1 → mem[addra] = dina
//   dina[127:0]   = even OC weights (ch0..15 packed)
//   dina[255:128] = odd  OC weights (ch0..15 packed)
//
// Read:  enb=1 → 다음 cycle doutb 유효
//==============================================================================
module fc_weight_bram (
    input  wire         clka,
    input  wire         ena,                  // ★ ENA (BMG Use ENA Pin)
    input  wire         wea,                  // 1-bit WEA (Byte Write Disable)
    input  wire [9:0]   addra,
    input  wire [255:0] dina,

    input  wire         clkb,
    input  wire         enb,
    input  wire [9:0]   addrb,
    output reg  [255:0] doutb
);
    reg [255:0] mem [0:1023];

    integer mi;
    initial begin
        for (mi = 0; mi < 1024; mi = mi + 1) mem[mi] = 256'd0;
        doutb = 256'd0;
    end

    // Port A write: ENA AND WEA = 1 조건 (실제 BMG 거동과 일치)
    always @(posedge clka) begin
        if (ena && wea) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        if (enb) doutb <= mem[addrb];
    end
endmodule