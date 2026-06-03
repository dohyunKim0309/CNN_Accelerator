`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cnn_accelerator (single image)
// Description:
//   Single-image CNN accelerator top-level.
//   원본(cnn_accelerator.v) 대비 변경점:
//     - ping-pong 제거: 모든 레이어 bank=0 고정 (BRAM IP 크기는 동일 유지)
//     - 4-way handshake 제거: 각 레이어 done → 다음 prior_wdone 직결
//     - img_ready / input_consumed 포트 제거 (single image 불필요)
//     - 제어: start → conv1 시작 + conv2 weight 적재 동시 시작
//             conv1_done → conv2 image 처리 → conv2_wdone → maxpool → maxpool_done → fc
//
//   BRAM IP (원본과 동일 depth/width):
//     bram_input      : Port A 32b×512 write / Port B 8b×2048 read, L=1
//     bram_c1_to_c2   : 64b×2048, byte-write 8b, L=2
//     bram_c2_to_pool : 128b×2048, L=1
//     bram_pool_to_fc : 128b×512, L=1
//     [engine 내부] conv1_weight_bram, conv2_weight_bram, fc_weight_bram
//////////////////////////////////////////////////////////////////////////////////

module cnn_accelerator (
    input  wire        clk,
    input  wire        resetn,        // active-low

    input  wire        enable,        // trigger qualify
    input  wire        start,         // 1-cycle pulse: weight load + image 처리 시작
    output wire [3:0]  result,
    output wire        img_done,      // image 처리 완료 pulse

    // Input BRAM Port A (PS write, 32b×512)
    input  wire        in_ena,
    input  wire [3:0]  in_wea,
    input  wire [8:0]  in_addra,      // {bank, word[7:0]} — single image는 bank=0 사용
    input  wire [31:0] in_dina,

    // Conv1 weight BRAM Port A
    input  wire        c1w_ena,
    input  wire [3:0]  c1w_wea,
    input  wire [5:0]  c1w_addra,
    input  wire [31:0] c1w_dina,

    // Conv2 weight BRAM Port A
    input  wire        c2w_ena,
    input  wire [3:0]  c2w_wea,
    input  wire [9:0]  c2w_addra,
    input  wire [31:0] c2w_dina,

    // FC weight BRAM Port A
    input  wire        fcw_ena,
    input  wire [3:0]  fcw_wea,
    input  wire [12:0] fcw_addra,
    input  wire [31:0] fcw_dina
);

    wire rst = ~resetn;
    wire start_q = start & enable;

    // 레이어 간 handshake
    wire conv1_done;
    wire conv2_wdone;
    wire maxpool_done;
    wire [3:0] class_idx;
    wire       class_valid;

    // BRAM 연결 nets
    // -- bram_input Port B (conv1 read)
    wire [10:0]        in_addrb;
    wire               in_enb;
    wire signed [7:0]  in_doutb;

    // -- bram_c1_to_c2
    wire        c1c2_we_a;
    wire [7:0]  c1c2_wea_a;
    wire [10:0] c1c2_addr_a;
    wire [63:0] c1c2_din_a;
    wire        c1c2_re_b;
    wire [10:0] c1c2_addr_b;
    wire [63:0] c1c2_doutb_b;

    // -- bram_c2_to_pool
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    wire [10:0]  c2pool_rd_addr;
    wire         c2pool_rd_en;
    wire [127:0] c2pool_rd_data;

    // -- bram_pool_to_fc
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;
    wire         fc_poolfc_re;
    wire [8:0]   fc_poolfc_addr;
    wire [127:0] fc_poolfc_dout;

    //==========================================================================
    // BRAM instances (원본과 동일 모듈명/크기)
    //==========================================================================
    bram_input in_bmg (
        .clka  (clk), .ena (in_ena), .wea (in_wea),
        .addra (in_addra), .dina (in_dina),
        .clkb  (clk), .enb (in_enb),
        .addrb (in_addrb), .doutb (in_doutb)
    );

    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk), .ena (c1c2_we_a), .wea (c1c2_wea_a),
        .addra (c1c2_addr_a), .dina (c1c2_din_a),
        .clkb  (clk), .enb (c1c2_re_b),
        .addrb (c1c2_addr_b), .doutb (c1c2_doutb_b)
    );

    bram_c2_to_pool c2pool_bmg (
        .clka  (clk), .ena (c2pool_we_a), .wea (c2pool_we_a),
        .addra (c2pool_addr_a), .dina (c2pool_din_a),
        .clkb  (clk), .enb (c2pool_rd_en),
        .addrb (c2pool_rd_addr), .doutb (c2pool_rd_data)
    );

    bram_pool_to_fc poolfc_bmg (
        .clka  (clk), .ena (poolfc_wr_en), .wea (poolfc_wr_en),
        .addra (poolfc_wr_addr), .dina (poolfc_wr_data),
        .clkb  (clk), .enb (fc_poolfc_re),
        .addrb (fc_poolfc_addr), .doutb (fc_poolfc_dout)
    );

    //==========================================================================
    // Conv1 engine
    //   start_q → weight load + image processing
    //==========================================================================
    conv1_engine conv1 (
        .clk          (clk), .rst(rst),
        .start        (start_q),
        .done         (conv1_done),

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .c1w_ena      (c1w_ena), .c1w_wea(c1w_wea),
        .c1w_addra    (c1w_addra), .c1w_dina(c1w_dina),

        .c1c2_we      (c1c2_we_a), .c1c2_wea(c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a), .c1c2_din(c1c2_din_a)
    );

    //==========================================================================
    // Conv2 engine
    //   start_q → weight load (conv1 image보다 먼저 완료 ~600 cycle)
    //   conv1_done → image 처리 시작
    //==========================================================================
    conv2_engine conv2 (
        .clk          (clk), .rst(rst),
        .start        (start_q),

        .c2w_ena      (c2w_ena), .c2w_wea(c2w_wea),
        .c2w_addra    (c2w_addra), .c2w_dina(c2w_dina),

        .c1c2_re      (c1c2_re_b),
        .c1c2_addr    (c1c2_addr_b),
        .c1c2_dout    (c1c2_doutb_b),

        .c2pool_we    (c2pool_we_a),
        .c2pool_addr  (c2pool_addr_a),
        .c2pool_din   (c2pool_din_a),

        .prior_wdone  (conv1_done),
        .wdone        (conv2_wdone)
    );

    //==========================================================================
    // Maxpool engine
    //   conv2_wdone → image 처리 시작
    //==========================================================================
    maxpool_engine maxpool (
        .clk             (clk), .rst(rst),
        .done            (maxpool_done),
        .prior_wdone     (conv2_wdone),

        .c2pool_rd_addr  (c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_rd_en),
        .c2pool_rd_data  (c2pool_rd_data),

        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data)
    );

    //==========================================================================
    // FC engine
    //   maxpool_done → image 처리 시작
    //==========================================================================
    fc_engine #(.ACC_W(24)) fc (
        .clk         (clk), .rst(rst),
        .start       (1'b0),            // prior_wdone 트리거만 사용

        .fcw_ena     (fcw_ena), .fcw_wea(fcw_wea),
        .fcw_addra   (fcw_addra), .fcw_dina(fcw_dina),

        .poolfc_re   (fc_poolfc_re),
        .poolfc_addr (fc_poolfc_addr),
        .poolfc_dout (fc_poolfc_dout),

        .prior_wdone (maxpool_done),

        .class_idx   (class_idx),
        .class_valid (class_valid)
    );

    //==========================================================================
    // Result latch
    //==========================================================================
    reg [3:0] result_r;
    reg       img_done_r;
    always @(posedge clk) begin
        if (rst) begin
            result_r   <= 4'd0;
            img_done_r <= 1'b0;
        end else begin
            img_done_r <= class_valid;
            if (class_valid)
                result_r <= class_idx;
        end
    end

    assign result   = result_r;
    assign img_done = img_done_r;

endmodule
