`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_engine (single image)
// Description:
//   Conv1 top-level — single image 전용 (ping-pong bank / 4-way handshake 제거)
//
//   원본(conv1_engine.v) 대비 변경점:
//     - input_bank_sel / bank_sel / bank_sel_pipe / bank_change 제거
//     - prior_wdone / succ_rdone / rdone / wdone 포트 제거
//     - in_bram_addr: 10-bit (bank bit 제거, 단일 bank)
//     - c1c2_addr:    10-bit (bank bit 제거, 단일 bank)
//     - in_addr reset: rst || lb_rst || load_start 만으로 단순화
//     - start / done 인터페이스
//////////////////////////////////////////////////////////////////////////////////

module conv1_engine (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire        done,

    // 입력 BRAM (Read, Port B, 11-bit addr — bank=0 고정)
    output wire [10:0]       in_bram_addr,
    output wire              in_bram_en,
    input  wire signed [7:0] in_bram_dout,

    // Conv1 weight BRAM Port A (PS write)
    input  wire        c1w_ena,
    input  wire [3:0]  c1w_wea,
    input  wire [5:0]  c1w_addra,
    input  wire [31:0] c1w_dina,

    // c1c2 BRAM Port A (byte-write, 64-bit, 11-bit addr — bank=0 고정)
    output wire        c1c2_we,
    output wire [7:0]  c1c2_wea,
    output wire [10:0] c1c2_addr,
    output wire [63:0] c1c2_din
);

    //==========================================================================
    // 1. FSM
    //==========================================================================
    wire        load_start, load_done;
    wire        pipe_en, sel, lb_rst;
    wire [4:0]  out_row, out_col;
    wire        out_valid, out_sel;

    conv1_fsm fsm (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .load_start (load_start),
        .load_done  (load_done),
        .pipe_en    (pipe_en),
        .sel        (sel),
        .lb_rst     (lb_rst),
        .out_row    (out_row),
        .out_col    (out_col),
        .out_valid  (out_valid),
        .out_sel    (out_sel),
        .done       (done)
    );

    //==========================================================================
    // 2. 입력 BRAM 주소 카운터 (10-bit, bank 없음)
    //
    //   reset 조건: rst || lb_rst || load_start
    //   (원본의 bank_change 조건 제거)
    //==========================================================================
    reg [9:0] in_addr;

    always @(posedge clk) begin
        if (rst || lb_rst || load_start)
            in_addr <= 10'd0;
        else if (pipe_en) begin
            if (in_addr == 10'd783)
                in_addr <= 10'd0;
            else
                in_addr <= in_addr + 1'b1;
        end
    end

    assign in_bram_addr = {1'b0, in_addr};   // bank=0 고정
    assign in_bram_en   = pipe_en;

    //==========================================================================
    // 3. weight BRAM + weight_loader
    //==========================================================================
    wire [24:0]  pe_packed_w;
    wire [17:0]  pe_load_en;
    wire         pe_load_idx;

    wire [5:0]  w_bram_addr;
    wire        w_bram_en;
    wire [31:0] w_bram_dout;

    conv1_weight_bram c1w_bmg_inst (
        .clka  (clk),
        .ena   (c1w_ena),
        .wea   (c1w_wea),
        .addra (c1w_addra),
        .dina  (c1w_dina),

        .clkb  (clk),
        .enb   (w_bram_en),
        .addrb (w_bram_addr),
        .doutb (w_bram_dout),
        .regceb(1'b1)
    );

    conv1_weight_loader #(.NUM_PE(18), .ADDR_W(6)) wloader (
        .clk         (clk),
        .rst         (rst),
        .load_start  (load_start),
        .load_done   (load_done),
        .bram_addr   (w_bram_addr),
        .bram_en     (w_bram_en),
        .bram_dout   (w_bram_dout),
        .pe_packed_w (pe_packed_w),
        .pe_load_en  (pe_load_en),
        .pe_load_idx (pe_load_idx)
    );

    //==========================================================================
    // 4. line_buffer × 2
    //==========================================================================
    wire signed [7:0] lb1_out, lb2_out;
    wire lb_rst_combined = rst | lb_rst;

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb1 (
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .din(in_bram_dout), .dout(lb1_out)
    );

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb2 (
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .din(lb1_out), .dout(lb2_out)
    );

    //==========================================================================
    // 5. window_register
    //==========================================================================
    wire signed [7:0] k0,k1,k2,k3,k4,k5,k6,k7,k8;

    window_register #(.WIDTH(8)) win (
        .clk(clk), .rst(lb_rst_combined), .en(pipe_en),
        .row2_in(in_bram_dout), .row1_in(lb1_out), .row0_in(lb2_out),
        .k0(k0),.k1(k1),.k2(k2),
        .k3(k3),.k4(k4),.k5(k5),
        .k6(k6),.k7(k7),.k8(k8)
    );

    wire signed [7:0] kx [0:8];
    assign kx[0]=k0; assign kx[1]=k1; assign kx[2]=k2;
    assign kx[3]=k3; assign kx[4]=k4; assign kx[5]=k5;
    assign kx[6]=k6; assign kx[7]=k7; assign kx[8]=k8;

    //==========================================================================
    // 6. pe_cell × 18
    //==========================================================================
    wire signed [16:0] mul0_g1 [0:8];
    wire signed [16:0] mul1_g1 [0:8];
    wire signed [16:0] mul0_g2 [0:8];
    wire signed [16:0] mul1_g2 [0:8];

    genvar gi;
    generate
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g1
            pe_cell #(.DEPTH(2)) pe (
                .clk(clk), .rst(rst),
                .packed_w(pe_packed_w),
                .load_idx(pe_load_idx),
                .load_en(pe_load_en[gi]),
                .sel(sel),
                .en(pipe_en),
                .x(kx[gi]),
                .mul0(mul0_g1[gi]),
                .mul1(mul1_g1[gi])
            );
        end
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g2
            pe_cell #(.DEPTH(2)) pe (
                .clk(clk), .rst(rst),
                .packed_w(pe_packed_w),
                .load_idx(pe_load_idx),
                .load_en(pe_load_en[gi+9]),
                .sel(sel),
                .en(pipe_en),
                .x(kx[gi]),
                .mul0(mul0_g2[gi]),
                .mul1(mul1_g2[gi])
            );
        end
    endgenerate

    //==========================================================================
    // 7. adder_tree × 2
    //==========================================================================
    wire signed [23:0] sum0_g1, sum1_g1, sum0_g2, sum1_g2;

    conv1_adder_tree at_g1 (
        .clk(clk), .rst(rst), .en(pipe_en),
        .mul0_0(mul0_g1[0]),.mul0_1(mul0_g1[1]),.mul0_2(mul0_g1[2]),
        .mul0_3(mul0_g1[3]),.mul0_4(mul0_g1[4]),.mul0_5(mul0_g1[5]),
        .mul0_6(mul0_g1[6]),.mul0_7(mul0_g1[7]),.mul0_8(mul0_g1[8]),
        .mul1_0(mul1_g1[0]),.mul1_1(mul1_g1[1]),.mul1_2(mul1_g1[2]),
        .mul1_3(mul1_g1[3]),.mul1_4(mul1_g1[4]),.mul1_5(mul1_g1[5]),
        .mul1_6(mul1_g1[6]),.mul1_7(mul1_g1[7]),.mul1_8(mul1_g1[8]),
        .sum0(sum0_g1), .sum1(sum1_g1)
    );

    conv1_adder_tree at_g2 (
        .clk(clk), .rst(rst), .en(pipe_en),
        .mul0_0(mul0_g2[0]),.mul0_1(mul0_g2[1]),.mul0_2(mul0_g2[2]),
        .mul0_3(mul0_g2[3]),.mul0_4(mul0_g2[4]),.mul0_5(mul0_g2[5]),
        .mul0_6(mul0_g2[6]),.mul0_7(mul0_g2[7]),.mul0_8(mul0_g2[8]),
        .mul1_0(mul1_g2[0]),.mul1_1(mul1_g2[1]),.mul1_2(mul1_g2[2]),
        .mul1_3(mul1_g2[3]),.mul1_4(mul1_g2[4]),.mul1_5(mul1_g2[5]),
        .mul1_6(mul1_g2[6]),.mul1_7(mul1_g2[7]),.mul1_8(mul1_g2[8]),
        .sum0(sum0_g2), .sum1(sum1_g2)
    );

    //==========================================================================
    // 8. truncate_relu (N=4)
    //==========================================================================
    wire [95:0] tr_sum_flat = {sum1_g2, sum0_g2, sum1_g1, sum0_g1};
    wire [31:0] tr_out_flat;

    wire signed [7:0] tr_out0 = tr_out_flat[ 7: 0];
    wire signed [7:0] tr_out1 = tr_out_flat[15: 8];
    wire signed [7:0] tr_out2 = tr_out_flat[23:16];
    wire signed [7:0] tr_out3 = tr_out_flat[31:24];

    truncate_relu #(.N(4)) tr (
        .clk(clk), .rst(rst), .en(pipe_en),
        .sum_flat(tr_sum_flat),
        .out_flat(tr_out_flat)
    );

    //==========================================================================
    // 9. 제어 신호 3단 파이프라인 시프트 (bank_sel_pipe 없음)
    //==========================================================================
    reg signed [7:0] ch0_final, ch1_final, ch2_final, ch3_final;

    reg [2:0] we_pipe;
    reg [2:0] sel_pipe;
    reg [9:0] addr_pipe [0:2];

    always @(posedge clk) begin
        if (rst) begin
            ch0_final <= 8'sd0; ch1_final <= 8'sd0;
            ch2_final <= 8'sd0; ch3_final <= 8'sd0;
            we_pipe   <= 3'b000;
            sel_pipe  <= 3'b000;
            addr_pipe[0] <= 10'd0; addr_pipe[1] <= 10'd0; addr_pipe[2] <= 10'd0;
        end else begin
            ch0_final <= tr_out0;
            ch1_final <= tr_out1;
            ch2_final <= tr_out2;
            ch3_final <= tr_out3;

            we_pipe  <= {we_pipe[1:0],  out_valid};
            sel_pipe <= {sel_pipe[1:0], out_sel};

            addr_pipe[0] <= {out_row[4:0], out_col[4:0]};
            addr_pipe[1] <= addr_pipe[0];
            addr_pipe[2] <= addr_pipe[1];
        end
    end

    //==========================================================================
    // 10. c1c2 BRAM Port A 결선 (10-bit addr, bank 없음)
    //==========================================================================
    wire round0_active = (sel_pipe[2] == 1'b0);

    wire [63:0] din_round0 = {32'd0,
                              ch3_final, ch2_final, ch1_final, ch0_final};
    wire [63:0] din_round1 = {tr_out3, tr_out2, tr_out1, tr_out0,
                              32'd0};

    assign c1c2_we   = we_pipe[2];
    assign c1c2_wea  = round0_active ? 8'b00001111 : 8'b11110000;
    assign c1c2_addr = {1'b0, addr_pipe[2]};  // bank=0 고정
    assign c1c2_din  = round0_active ? din_round0 : din_round1;

endmodule
