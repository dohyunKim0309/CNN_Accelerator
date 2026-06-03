`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_engine (single image)
// Description:
//   FC engine — single image 전용 (ping-pong / handshake 제거)
//
//   원본(fc_engine.v) 대비 변경점:
//     - rdone 포트 제거
//     - poolfc_addr: 8-bit (bank bit 제거, s_cnt 직접 사용)
//     - prior_wdone: 이미지 처리 트리거 (edge-detect)
//     - prior_diff 핸드셰이크 카운터 제거 (fc_fsm 내부)
//     - input_bank_sel 제거 (fc_fsm 내부)
//////////////////////////////////////////////////////////////////////////////////

module fc_engine #(
    parameter ACC_W = 24
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    // FC weight BRAM Port A
    input  wire         fcw_ena,
    input  wire [3:0]   fcw_wea,
    input  wire [12:0]  fcw_addra,
    input  wire [31:0]  fcw_dina,

    // poolfc BRAM read (9-bit addr — bank=0 고정)
    output wire         poolfc_re,
    output wire [8:0]   poolfc_addr,
    input  wire [127:0] poolfc_dout,

    // image trigger
    input  wire         prior_wdone,

    // result
    output wire [3:0]   class_idx,
    output wire         class_valid
);

    //==========================================================================
    // 1. FSM
    //==========================================================================
    wire [7:0] fsm_s_cnt;
    wire [2:0] fsm_pair_cnt;
    wire [9:0] fsm_wbase;
    wire       fsm_comp_v;
    wire       fsm_s_first;
    wire       fsm_s_last;
    wire       fsm_busy;

    fc_fsm fsm_inst (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .prior_wdone (prior_wdone),
        .s_cnt       (fsm_s_cnt),
        .pair_cnt    (fsm_pair_cnt),
        .wbase       (fsm_wbase),
        .comp_v      (fsm_comp_v),
        .s_first     (fsm_s_first),
        .s_last      (fsm_s_last),
        .busy        (fsm_busy)
    );

    //==========================================================================
    // 2. poolfc BRAM read (8-bit addr, no bank)
    //==========================================================================
    assign poolfc_re   = fsm_comp_v;
    assign poolfc_addr = {1'b0, fsm_s_cnt};  // bank=0 고정

    //==========================================================================
    // 3. Weight BRAM
    //==========================================================================
    wire [9:0]   fcw_addrb = fsm_wbase + {2'd0, fsm_s_cnt};
    wire [255:0] fcw_doutb;

    fc_weight_bram fcw_bmg_inst (
        .clka  (clk), .ena (fcw_ena), .wea (fcw_wea),
        .addra (fcw_addra), .dina (fcw_dina),
        .clkb  (clk), .enb (fsm_comp_v),
        .addrb (fcw_addrb), .doutb (fcw_doutb)
    );

    wire [127:0] w_even_flat = fcw_doutb[127:0];
    wire [127:0] w_odd_flat  = fcw_doutb[255:128];

    //==========================================================================
    // 4. Control pipeline
    //==========================================================================
    localparam CTRL_DELAY = 8;

    reg [CTRL_DELAY:0] comp_pipe;
    reg [CTRL_DELAY:0] first_pipe;
    reg [CTRL_DELAY:0] last_pipe;
    reg [2:0]          pair_pipe [0:CTRL_DELAY];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            comp_pipe  <= {(CTRL_DELAY+1){1'b0}};
            first_pipe <= {(CTRL_DELAY+1){1'b0}};
            last_pipe  <= {(CTRL_DELAY+1){1'b0}};
            for (k = 0; k <= CTRL_DELAY; k = k + 1)
                pair_pipe[k] <= 3'd0;
        end else begin
            comp_pipe[0]  <= fsm_comp_v;
            first_pipe[0] <= fsm_s_first;
            last_pipe[0]  <= fsm_s_last;
            pair_pipe[0]  <= fsm_pair_cnt;
            for (k = 1; k <= CTRL_DELAY; k = k + 1) begin
                comp_pipe[k]  <= comp_pipe[k-1];
                first_pipe[k] <= first_pipe[k-1];
                last_pipe[k]  <= last_pipe[k-1];
                pair_pipe[k]  <= pair_pipe[k-1];
            end
        end
    end

    wire pe_en    = comp_pipe[0] | comp_pipe[1] | comp_pipe[2] | comp_pipe[3];
    wire adder_en = comp_pipe[4] | comp_pipe[5] | comp_pipe[6] | comp_pipe[7];

    wire       acc_en    = comp_pipe [CTRL_DELAY];
    wire       acc_clear = first_pipe[CTRL_DELAY];
    wire       acc_last  = last_pipe [CTRL_DELAY];
    wire [2:0] acc_pair  = pair_pipe [CTRL_DELAY];

    //==========================================================================
    // 5. PE array
    //==========================================================================
    wire [255:0] p_even_flat, p_odd_flat;

    fc_pe_array pe_inst (
        .clk(clk), .rst(rst), .en(pe_en),
        .x_flat (poolfc_dout),
        .w0_flat(w_even_flat),
        .w1_flat(w_odd_flat),
        .p0_flat(p_even_flat),
        .p1_flat(p_odd_flat)
    );

    //==========================================================================
    // 6. Adder tree
    //==========================================================================
    wire signed [19:0] sum_even, sum_odd;

    fc_adder_tree adder_inst (
        .clk(clk), .rst(rst), .en(adder_en),
        .p0_flat(p_even_flat), .p1_flat(p_odd_flat),
        .sum0(sum_even), .sum1(sum_odd)
    );

    //==========================================================================
    // 7. Accumulator
    //==========================================================================
    wire signed [ACC_W-1:0] logit_even_acc, logit_odd_acc;
    wire                    logit_valid;

    fc_accumulator #(.ACC_W(ACC_W)) acc_inst (
        .clk        (clk), .rst(rst),
        .en         (acc_en),
        .clear      (acc_clear),
        .last       (acc_last),
        .sum0       (sum_even),
        .sum1       (sum_odd),
        .logit0     (logit_even_acc),
        .logit1     (logit_odd_acc),
        .logit_valid(logit_valid)
    );

    //==========================================================================
    // 8. Logit collection
    //==========================================================================
    reg signed [ACC_W-1:0] logit_reg [0:9];
    reg [2:0] acc_pair_latch;

    always @(posedge clk) begin
        if (rst) acc_pair_latch <= 3'd0;
        else if (acc_en && acc_last)
            acc_pair_latch <= acc_pair;
    end

    integer oc;
    always @(posedge clk) begin
        if (rst) begin
            for (oc = 0; oc < 10; oc = oc + 1)
                logit_reg[oc] <= {ACC_W{1'b0}};
        end else if (logit_valid) begin
            logit_reg[{1'b0, acc_pair_latch} * 2    ] <= logit_even_acc;
            logit_reg[{1'b0, acc_pair_latch} * 2 + 1] <= logit_odd_acc;
        end
    end

    wire [10*ACC_W-1:0] logit_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : flat_pack
            assign logit_flat[gi*ACC_W +: ACC_W] = logit_reg[gi];
        end
    endgenerate

    reg all_ready;
    always @(posedge clk) begin
        if (rst) all_ready <= 1'b0;
        else     all_ready <= logit_valid && (acc_pair_latch == 3'd4);
    end

    //==========================================================================
    // 9. Argmax
    //==========================================================================
    fc_argmax #(.ACC_W(ACC_W)) argmax_inst (
        .clk      (clk), .rst(rst),
        .in_valid  (all_ready),
        .logit_flat(logit_flat),
        .class_idx (class_idx),
        .done      (class_valid)
    );

endmodule
