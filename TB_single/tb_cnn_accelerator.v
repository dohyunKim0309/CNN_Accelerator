`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_cnn_accelerator.v  (single image — RTL_single 전체 검증)
//
//   RTL_single/cnn_accelerator.v 를 끝까지 구동하는 시스템 TB
//   원본(tb_cnn_accelerator_multi.v) 대비:
//     - 이미지 1장만 처리 (N_IMAGES=1)
//     - img_ready / input_consumed 없음 (단일 이미지, ping-pong 없음)
//     - start 1회 pulse → weight load + image 처리 시작
//     - img_done 에서 result 검증 (logit bit-exact + argmax)
//
//   iverilog 컴파일 방법 (CNN_Accelerator/ 에서 실행):
//     iverilog -g2005 -o sim_single \
//       TB_single/models/dsp48e1_model.v \
//       TB_single/models/bmg_sim_models.v \
//       RTL_single/core/pe_cell.v \
//       RTL_single/core/line_buffer.v \
//       RTL_single/core/window_register.v \
//       RTL_single/core/truncate_relu.v \
//       RTL_single/conv1/conv1_adder_tree.v \
//       RTL_single/conv1/conv1_weight_loader.v \
//       RTL_single/conv1/conv1_fsm.v \
//       RTL_single/conv1/conv1_engine.v \
//       RTL_single/conv2/kcol_accumulator.v \
//       RTL_single/conv2/krow_ic_adder_tree.v \
//       RTL_single/conv2/weight_loader.v \
//       RTL_single/conv2/conv2_fsm.v \
//       RTL_single/conv2/conv2_engine.v \
//       RTL_single/maxpool/max_compare_tree.v \
//       RTL_single/maxpool/maxpool_fsm.v \
//       RTL_single/maxpool/maxpool_engine.v \
//       RTL_single/fc/fc_pe_array.v \
//       RTL_single/fc/fc_adder_tree.v \
//       RTL_single/fc/fc_accumulator.v \
//       RTL_single/fc/fc_argmax.v \
//       RTL_single/fc/fc_fsm.v \
//       RTL_single/fc/fc_engine.v \
//       RTL_single/cnn_accelerator.v \
//       TB_single/tb_cnn_accelerator.v && ./sim_single
//
//   데이터 파일 (data_single/):
//     conv1_input.hex, conv1_weights_simd.hex, conv2_weights_simd.hex,
//     fc_weights_simd.hex, fc_output.hex (logit 검증용)
//////////////////////////////////////////////////////////////////////////////////

`define INPUT_HEX    "data_single/conv1_input.hex"
`define CONV1_WEIGHT "data_single/conv1_weights_simd.hex"
`define CONV2_WEIGHT "data_single/conv2_weights_simd.hex"
`define FCW_HEX      "data_single/fc_weights_simd.hex"

module tb_cnn_accelerator;

    parameter ACC_W = 24;

    // Expected logits (tb_fc_engine.v 와 동일)
    localparam signed [23:0] EXP_OC0 = 24'h00010B;
    localparam signed [23:0] EXP_OC1 = 24'hFFF885;
    localparam signed [23:0] EXP_OC2 = 24'h000AF9;
    localparam signed [23:0] EXP_OC3 = 24'h001ABC;
    localparam signed [23:0] EXP_OC4 = 24'hFFED99;
    localparam signed [23:0] EXP_OC5 = 24'h00255D;  // max → class 5
    localparam signed [23:0] EXP_OC6 = 24'h00067A;
    localparam signed [23:0] EXP_OC7 = 24'h001231;
    localparam signed [23:0] EXP_OC8 = 24'h000D6B;
    localparam signed [23:0] EXP_OC9 = 24'h000D7A;
    localparam        [3:0]  EXP_CLS = 4'd5;

    //==========================================================================
    // Clock / reset
    //==========================================================================
    reg clk    = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    //==========================================================================
    // DUT 포트
    //==========================================================================
    reg        enable    = 1'b0;
    reg        start     = 1'b0;
    wire [3:0] result;
    wire       img_done;

    // Input BRAM Port A
    reg        in_ena   = 1'b0;
    reg [3:0]  in_wea   = 4'd0;
    reg [8:0]  in_addra = 9'd0;
    reg [31:0] in_dina  = 32'd0;

    // Conv1 weight Port A
    reg        c1w_ena   = 1'b0;
    reg [3:0]  c1w_wea   = 4'd0;
    reg [5:0]  c1w_addra = 6'd0;
    reg [31:0] c1w_dina  = 32'd0;

    // Conv2 weight Port A
    reg        c2w_ena   = 1'b0;
    reg [3:0]  c2w_wea   = 4'd0;
    reg [9:0]  c2w_addra = 10'd0;
    reg [31:0] c2w_dina  = 32'd0;

    // FC weight Port A
    reg        fcw_ena   = 1'b0;
    reg [3:0]  fcw_wea   = 4'd0;
    reg [12:0] fcw_addra = 13'd0;
    reg [31:0] fcw_dina  = 32'd0;

    //==========================================================================
    // DUT
    //==========================================================================
    cnn_accelerator dut (
        .clk      (clk),
        .resetn   (resetn),
        .enable   (enable),
        .start    (start),
        .result   (result),
        .img_done (img_done),

        .in_ena   (in_ena),   .in_wea   (in_wea),
        .in_addra (in_addra), .in_dina  (in_dina),

        .c1w_ena   (c1w_ena),   .c1w_wea   (c1w_wea),
        .c1w_addra (c1w_addra), .c1w_dina  (c1w_dina),

        .c2w_ena   (c2w_ena),   .c2w_wea   (c2w_wea),
        .c2w_addra (c2w_addra), .c2w_dina  (c2w_dina),

        .fcw_ena   (fcw_ena),   .fcw_wea   (fcw_wea),
        .fcw_addra (fcw_addra), .fcw_dina  (fcw_dina)
    );

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]  input_data    [0:783];
    reg [31:0] weight1_mem   [0:35];
    reg [31:0] weight2_mem   [0:575];
    reg [31:0] fc_weight_simd[0:11519];

    //==========================================================================
    // Cycle counter
    //==========================================================================
    integer cycle_cnt = 0;
    always @(posedge clk) if (resetn) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Task: load_w1 — Conv1 weight (36 entries)
    //==========================================================================
    task load_w1;
        integer wi;
        begin
            $display("[TB] @ cyc %0d : load_w1 start (36 words)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                c1w_ena = 1'b1; c1w_wea = 4'hF;
                c1w_addra = wi[5:0]; c1w_dina = weight1_mem[wi];
            end
            @(negedge clk); c1w_ena = 1'b0; c1w_wea = 4'd0;
            $display("[TB] @ cyc %0d : load_w1 done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: load_w2 — Conv2 weight (576 entries)
    //==========================================================================
    task load_w2;
        integer wi;
        begin
            $display("[TB] @ cyc %0d : load_w2 start (576 words)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1; c2w_wea = 4'hF;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0; c2w_wea = 4'd0;
            $display("[TB] @ cyc %0d : load_w2 done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: load_fcw — FC weight (SIMD unpack → 256b word, asymmetric write)
    //   fc_weights_simd.hex: 11520 line × 32-bit SIMD-packed
    //   BMG Port A 32b×5760 (= 720 entries × 8 words × 32b)
    //==========================================================================
    task load_fcw;
        integer pair, s, c, k, line_idx;
        reg signed [7:0]  w0, w1;
        reg signed [16:0] w0_packed_17;
        reg signed  [7:0] w1_packed_8;
        reg [127:0]        w_even_concat, w_odd_concat;
        reg [255:0]        word;
        begin
            $display("[TB] @ cyc %0d : load_fcw start (720 entries × 256b)", cycle_cnt);
            for (pair = 0; pair < 5; pair = pair + 1) begin
                for (s = 0; s < 144; s = s + 1) begin
                    w_even_concat = 128'd0;
                    w_odd_concat  = 128'd0;
                    for (c = 0; c < 16; c = c + 1) begin
                        line_idx     = pair*144*16 + s*16 + c;
                        w0_packed_17 = $signed(fc_weight_simd[line_idx][16:0]);
                        w1_packed_8  = $signed(fc_weight_simd[line_idx][24:17]);
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
            fcw_ena = 1'b0; fcw_wea = 4'd0; fcw_addra = 13'd0; fcw_dina = 32'd0;
            $display("[TB] @ cyc %0d : load_fcw done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Task: write_input — bram_input Port A (bank 0, 196 word × 32b)
    //   bram_input Port A: 32b×512, addr = {bank, word[7:0]}
    //   single image: bank=0, word 0..195
    //==========================================================================
    task write_input;
        integer k;
        begin
            $display("[TB] @ cyc %0d : write_input start (196 words, bank 0)", cycle_cnt);
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena   = 1'b1; in_wea = 4'hF;
                in_addra = {1'b0, k[7:0]};   // bank=0
                in_dina  = {input_data[k*4+3], input_data[k*4+2],
                            input_data[k*4+1], input_data[k*4+0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 4'd0;
            $display("[TB] @ cyc %0d : write_input done", cycle_cnt);
        end
    endtask

    //==========================================================================
    // Logit 검증 (img_done 후 1 cycle에 logit_reg 안정)
    //==========================================================================
    wire signed [ACC_W-1:0] lr [0:9];
    assign lr[0] = dut.fc.logit_reg[0]; assign lr[1] = dut.fc.logit_reg[1];
    assign lr[2] = dut.fc.logit_reg[2]; assign lr[3] = dut.fc.logit_reg[3];
    assign lr[4] = dut.fc.logit_reg[4]; assign lr[5] = dut.fc.logit_reg[5];
    assign lr[6] = dut.fc.logit_reg[6]; assign lr[7] = dut.fc.logit_reg[7];
    assign lr[8] = dut.fc.logit_reg[8]; assign lr[9] = dut.fc.logit_reg[9];

    //==========================================================================
    // Main
    //==========================================================================
    integer cyc_start, cyc_done;
    integer logit_mm, oc;
    integer pass_cnt, fail_cnt;

    initial begin
        $display("============================================================");
        $display("[TB] cnn_accelerator (single image) system test");
        $display("     Uses RTL_single + TB_single/models/*.v");
        $display("============================================================");

        $readmemh(`INPUT_HEX,    input_data);
        $readmemh(`CONV1_WEIGHT, weight1_mem);
        $readmemh(`CONV2_WEIGHT, weight2_mem);
        $readmemh(`FCW_HEX,      fc_weight_simd);
        $display("[TB] Data files loaded.");

        // Reset
        resetn = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk); resetn = 1'b1;
        $display("[TB] @ cyc %0d : reset released", cycle_cnt);

        // Weight 적재 (start 전에 Port A write)
        load_w1();
        load_w2();
        load_fcw();
        $display("[TB] @ cyc %0d : all weights loaded", cycle_cnt);

        // Input image 적재
        write_input();

        // enable=1 + start pulse
        @(negedge clk); enable = 1'b1;
        @(negedge clk); start = 1'b1;
        cyc_start = cycle_cnt;
        @(negedge clk); start = 1'b0;
        $display("[TB] @ cyc %0d : start pulsed", cyc_start);

        // img_done 대기
        @(posedge img_done);
        cyc_done = cycle_cnt;
        $display("[TB] @ cyc %0d : img_done received", cyc_done);

        // logit_reg 안정화를 위해 1 cycle 대기
        @(posedge clk); #1;

        // Logit 검증
        logit_mm = 0;
        pass_cnt = 0; fail_cnt = 0;
        $display("------------------------------------------------------------");
        $display("[LOGIT] OC values:");

        if (lr[0][23:0] === EXP_OC0) begin pass_cnt=pass_cnt+1; $display("  OC0: PASS %0d", $signed(lr[0])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC0: FAIL got=%0d exp=%0d", $signed(lr[0]), $signed(EXP_OC0)); end

        if (lr[1][23:0] === EXP_OC1) begin pass_cnt=pass_cnt+1; $display("  OC1: PASS %0d", $signed(lr[1])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC1: FAIL got=%0d exp=%0d", $signed(lr[1]), $signed(EXP_OC1)); end

        if (lr[2][23:0] === EXP_OC2) begin pass_cnt=pass_cnt+1; $display("  OC2: PASS %0d", $signed(lr[2])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC2: FAIL got=%0d exp=%0d", $signed(lr[2]), $signed(EXP_OC2)); end

        if (lr[3][23:0] === EXP_OC3) begin pass_cnt=pass_cnt+1; $display("  OC3: PASS %0d", $signed(lr[3])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC3: FAIL got=%0d exp=%0d", $signed(lr[3]), $signed(EXP_OC3)); end

        if (lr[4][23:0] === EXP_OC4) begin pass_cnt=pass_cnt+1; $display("  OC4: PASS %0d", $signed(lr[4])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC4: FAIL got=%0d exp=%0d", $signed(lr[4]), $signed(EXP_OC4)); end

        if (lr[5][23:0] === EXP_OC5) begin pass_cnt=pass_cnt+1; $display("  OC5: PASS %0d (MAX)", $signed(lr[5])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC5: FAIL got=%0d exp=%0d", $signed(lr[5]), $signed(EXP_OC5)); end

        if (lr[6][23:0] === EXP_OC6) begin pass_cnt=pass_cnt+1; $display("  OC6: PASS %0d", $signed(lr[6])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC6: FAIL got=%0d exp=%0d", $signed(lr[6]), $signed(EXP_OC6)); end

        if (lr[7][23:0] === EXP_OC7) begin pass_cnt=pass_cnt+1; $display("  OC7: PASS %0d", $signed(lr[7])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC7: FAIL got=%0d exp=%0d", $signed(lr[7]), $signed(EXP_OC7)); end

        if (lr[8][23:0] === EXP_OC8) begin pass_cnt=pass_cnt+1; $display("  OC8: PASS %0d", $signed(lr[8])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC8: FAIL got=%0d exp=%0d", $signed(lr[8]), $signed(EXP_OC8)); end

        if (lr[9][23:0] === EXP_OC9) begin pass_cnt=pass_cnt+1; $display("  OC9: PASS %0d", $signed(lr[9])); end
        else begin fail_cnt=fail_cnt+1; logit_mm=logit_mm+1; $display("  OC9: FAIL got=%0d exp=%0d", $signed(lr[9]), $signed(EXP_OC9)); end

        $display("------------------------------------------------------------");
        $display("[RESULT] class_idx = %0d (expected %0d) — %s",
                 result, EXP_CLS, (result == EXP_CLS) ? "PASS" : "FAIL");
        $display("============================================================");
        $display("[SUMMARY]");
        $display("  start      @ cyc %0d", cyc_start);
        $display("  img_done   @ cyc %0d", cyc_done);
        $display("  latency    : %0d cycles", cyc_done - cyc_start);
        $display("  logit pass : %0d / 10", pass_cnt);
        $display("  logit fail : %0d / 10", fail_cnt);
        if (logit_mm == 0 && result == EXP_CLS)
            $display("  *** ALL PASS *** (logits bit-exact + argmax correct)");
        else
            $display("  *** FAIL ***");
        $display("============================================================");

        $finish;
    end

    //==========================================================================
    // FSM 상태 모니터링 (주요 전환 추적)
    //==========================================================================
    // Conv1 FSM state 모니터
    reg [2:0] prev_c1_state = 3'd0;
    always @(posedge clk) begin
        if (resetn && dut.conv1.fsm.state !== prev_c1_state) begin
            case (dut.conv1.fsm.state)
                3'd0: $display("[C1-FSM] cyc=%0d IDLE",   cycle_cnt);
                3'd1: $display("[C1-FSM] cyc=%0d LOAD",   cycle_cnt);
                3'd2: $display("[C1-FSM] cyc=%0d RUN1",   cycle_cnt);
                3'd3: $display("[C1-FSM] cyc=%0d FLUSH1", cycle_cnt);
                3'd4: $display("[C1-FSM] cyc=%0d LBRST",  cycle_cnt);
                3'd5: $display("[C1-FSM] cyc=%0d RUN2",   cycle_cnt);
                3'd6: $display("[C1-FSM] cyc=%0d FLUSH2", cycle_cnt);
                3'd7: $display("[C1-FSM] cyc=%0d DONE",   cycle_cnt);
            endcase
            prev_c1_state <= dut.conv1.fsm.state;
        end
    end

    // Conv2 FSM state 모니터 (COMPUTE_HOLD 첫 진입만 표시)
    reg [2:0] prev_c2_state = 3'd0;
    reg c2_hold_shown = 1'b0;
    always @(posedge clk) begin
        if (resetn && dut.conv2.fsm_inst.state !== prev_c2_state) begin
            case (dut.conv2.fsm_inst.state)
                3'd0: begin $display("[C2-FSM] cyc=%0d IDLE",          cycle_cnt); c2_hold_shown <= 1'b0; end
                3'd1: $display("[C2-FSM] cyc=%0d LOAD_WEIGHTS",  cycle_cnt);
                3'd2: begin $display("[C2-FSM] cyc=%0d DONE_LW",       cycle_cnt); c2_hold_shown <= 1'b0; end
                3'd3: $display("[C2-FSM] cyc=%0d PIPELINE_FILL", cycle_cnt);
                3'd4: begin
                    if (!c2_hold_shown) begin
                        $display("[C2-FSM] cyc=%0d COMPUTE_HOLD (first)", cycle_cnt);
                        c2_hold_shown <= 1'b1;
                    end
                end
                3'd7: $display("[C2-FSM] cyc=%0d DRAIN",         cycle_cnt);
            endcase
            prev_c2_state <= dut.conv2.fsm_inst.state;
        end
    end

    // Maxpool FSM state 모니터
    reg [1:0] prev_mp_state = 2'd0;
    always @(posedge clk) begin
        if (resetn && dut.maxpool.fsm.state !== prev_mp_state) begin
            case (dut.maxpool.fsm.state)
                2'd0: $display("[MP-FSM] cyc=%0d IDLE",  cycle_cnt);
                2'd1: $display("[MP-FSM] cyc=%0d RUN",   cycle_cnt);
                2'd2: $display("[MP-FSM] cyc=%0d FLUSH", cycle_cnt);
                2'd3: $display("[MP-FSM] cyc=%0d DONE",  cycle_cnt);
            endcase
            prev_mp_state <= dut.maxpool.fsm.state;
        end
    end

    // FC FSM state 모니터
    reg [1:0] prev_fc_state = 2'd0;
    always @(posedge clk) begin
        if (resetn && dut.fc.fsm_inst.state !== prev_fc_state) begin
            case (dut.fc.fsm_inst.state)
                2'd0: $display("[FC-FSM] cyc=%0d IDLE",    cycle_cnt);
                2'd1: $display("[FC-FSM] cyc=%0d COMPUTE", cycle_cnt);
                2'd2: $display("[FC-FSM] cyc=%0d DRAIN",   cycle_cnt);
                2'd3: $display("[FC-FSM] cyc=%0d DONE",    cycle_cnt);
            endcase
            prev_fc_state <= dut.fc.fsm_inst.state;
        end
    end

    //==========================================================================
    // Timeout (넉넉하게 12000 cycles)
    //==========================================================================
    initial begin
        #120000;   // 12000 cycles @ 100 MHz
        $display("\n[TB] !!! TIMEOUT @ cyc %0d !!!", cycle_cnt);
        $display("  conv1.state=%0d conv2.state=%0d maxpool.state=%0d fc.state=%0d",
                 dut.conv1.fsm.state, dut.conv2.fsm_inst.state,
                 dut.maxpool.fsm.state, dut.fc.fsm_inst.state);
        $finish;
    end

endmodule
