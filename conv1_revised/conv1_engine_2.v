`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_engine
// Description:
//   Conv1 최상위 모듈.
//
//   입력  : (1, 28, 28) INT8 signed
//   출력  : (8, 26, 26) INT8 signed
//
//   DSP 사용: 18개 (pe_cell × 18, 각 DSP48E1 × 1)
//     g1 묶음: pe[0~8]  → oc0+oc1 (sel=0), oc4+oc5 (sel=1)
//     g2 묶음: pe[9~17] → oc2+oc3 (sel=0), oc6+oc7 (sel=1)
//
//   출력 BRAM 구조 변경 (핵심 수정):
//     이전: 단일 8bit 포트 → 4채널 순차 4사이클 → fill 1사이클 vs drain 4사이클
//           → FIFO 오버플로우 불가피
//     수정: 채널별 4개 독립 8bit BRAM → 1사이클에 4채널 동시 write
//
//     sel=0 라운드:
//       oc0_bram: addr=row*26+col(10bit), we, din=out0
//       oc1_bram: addr=row*26+col(10bit), we, din=out1
//       oc2_bram: addr=row*26+col(10bit), we, din=out2
//       oc3_bram: addr=row*26+col(10bit), we, din=out3
//     sel=1 라운드:
//       oc4_bram ~ oc7_bram: 동일 구조
//
//     총 8개의 독립 BRAM (각 26×26=676 depth, 8bit width)
//     상위 모듈에서 8개를 읽어 Conv2에 공급
//
//   출력 포트:
//     각 라운드(sel=0/1)에 4포트씩, 총 8포트
//     (이름: out_bram_addr[9:0], out_bram_we[7:0], out_bram_din_ch{0~7}[7:0])
//     → 실용적으로: addr 공통(동일 픽셀), we 별도, din 별도
//////////////////////////////////////////////////////////////////////////////////

module conv1_engine (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire        done,

    // 입력 BRAM (읽기)
    output wire [9:0]        in_bram_addr,
    output wire              in_bram_en,
    input  wire signed [7:0] in_bram_dout,

    // weight BRAM (읽기)
    output wire [5:0]  w_bram_addr,
    output wire        w_bram_en,
    input  wire [31:0] w_bram_dout,

    // 출력: 8채널 독립 포트 (동시 write)
    // addr: row*26+col (10bit, 0~675 공통)
    // we  : out_valid 시 1
    // din : 각 채널 INT8
    output wire [9:0]        out_addr,      // 공통 주소
    output wire              out_we,        // 공통 write enable

    output wire signed [7:0] out_din_ch0,   // oc0 (sel=0)
    output wire signed [7:0] out_din_ch1,   // oc1 (sel=0)
    output wire signed [7:0] out_din_ch2,   // oc2 (sel=0)
    output wire signed [7:0] out_din_ch3,   // oc3 (sel=0)
    output wire signed [7:0] out_din_ch4,   // oc4 (sel=1)
    output wire signed [7:0] out_din_ch5,   // oc5 (sel=1)
    output wire signed [7:0] out_din_ch6,   // oc6 (sel=1)
    output wire signed [7:0] out_din_ch7,   // oc7 (sel=1)

    output wire              out_sel_r      // 어느 라운드 출력인지 (레지스터)
);

    //==========================================================================
    // 1. conv1_fsm
    //==========================================================================
    wire        load_start, load_done;
    wire        pipe_en, sel, lb_rst;
    wire        pixel_valid;
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
        .pixel_valid(pixel_valid),
        .out_row    (out_row),
        .out_col    (out_col),
        .out_valid  (out_valid),
        .out_sel    (out_sel),
        .done       (done)
    );

    //==========================================================================
    // 2. 입력 BRAM 주소 카운터
    //==========================================================================
    reg [9:0] in_addr;

    always @(posedge clk) begin
        if (rst || lb_rst)
            in_addr <= 10'd0;
        else if (pipe_en) begin
            if (in_addr == 10'd783)
                in_addr <= 10'd0;
            else
                in_addr <= in_addr + 1'b1;
        end
    end

    assign in_bram_addr = in_addr;
    assign in_bram_en   = pipe_en;

    //==========================================================================
    // 3. weight_loader
    //==========================================================================
    wire [24:0]  pe_packed_w;
    wire [17:0]  pe_load_en;
    wire         pe_load_idx;

    weight_loader #(.NUM_PE(18), .ADDR_W(6)) wloader (
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
            pe_cell #(.DEPTH(2), .ADDR_W(1)) pe (
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
            pe_cell #(.DEPTH(2), .ADDR_W(1)) pe (
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

    adder_tree at_g1 (
        .clk(clk), .rst(rst), .en(pipe_en),
        .mul0_0(mul0_g1[0]),.mul0_1(mul0_g1[1]),.mul0_2(mul0_g1[2]),
        .mul0_3(mul0_g1[3]),.mul0_4(mul0_g1[4]),.mul0_5(mul0_g1[5]),
        .mul0_6(mul0_g1[6]),.mul0_7(mul0_g1[7]),.mul0_8(mul0_g1[8]),
        .mul1_0(mul1_g1[0]),.mul1_1(mul1_g1[1]),.mul1_2(mul1_g1[2]),
        .mul1_3(mul1_g1[3]),.mul1_4(mul1_g1[4]),.mul1_5(mul1_g1[5]),
        .mul1_6(mul1_g1[6]),.mul1_7(mul1_g1[7]),.mul1_8(mul1_g1[8]),
        .sum0(sum0_g1), .sum1(sum1_g1)
    );

    adder_tree at_g2 (
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
    // 8. truncate_relu
    //==========================================================================
    wire signed [7:0] tr_out0, tr_out1, tr_out2, tr_out3;

    truncate_relu tr (
        .clk(clk), .rst(rst), .en(pipe_en),
        .sum0(sum0_g1), .sum1(sum1_g1),
        .sum2(sum0_g2), .sum3(sum1_g2),
        .out0(tr_out0), .out1(tr_out1),
        .out2(tr_out2), .out3(tr_out3)
    );

    //==========================================================================
    // 9. 출력 주소 레지스터 + 동시 4채널 write
    //
    //   out_valid 1사이클에 4채널이 동시에 준비 → 4개 독립 BRAM에 동시 write
    //   → 버퍼, 순차 쓰기 전혀 불필요
    //
    //   출력 주소: row*26 + col (10bit, 0~675)
    //   출력 enable: out_valid 그대로 사용
    //
    //   sel=0: ch0~ch3 BRAM에 write, ch4~ch7 BRAM은 we=0
    //   sel=1: ch4~ch7 BRAM에 write, ch0~ch3 BRAM은 we=0
    //
    //   out_addr, out_we, out_sel_r 레지스터로 출력 (out_valid 기반)
    //==========================================================================
    reg [9:0]        out_addr_r;
    reg              out_we_r;
    reg              out_sel_rr;
    reg signed [7:0] ch0_r, ch1_r, ch2_r, ch3_r;

    always @(posedge clk) begin
        if (rst) begin
            out_addr_r <= 10'd0;
            out_we_r   <= 1'b0;
            out_sel_rr <= 1'b0;
            ch0_r <= 8'sd0; ch1_r <= 8'sd0;
            ch2_r <= 8'sd0; ch3_r <= 8'sd0;
        end else begin
            out_we_r   <= out_valid;
            out_sel_rr <= out_sel;
            if (out_valid) begin
                out_addr_r <= out_row * 10'd26 + {5'd0, out_col};
                ch0_r      <= tr_out0;
                ch1_r      <= tr_out1;
                ch2_r      <= tr_out2;
                ch3_r      <= tr_out3;
            end
        end
    end

    // sel=0: ch0~3 write, sel=1: ch4~7 write
    wire we_round0 = out_we_r & ~out_sel_rr;
    wire we_round1 = out_we_r &  out_sel_rr;

    assign out_addr     = out_addr_r;
    assign out_we       = out_we_r;
    assign out_sel_r    = out_sel_rr;

    assign out_din_ch0  = ch0_r;
    assign out_din_ch1  = ch1_r;
    assign out_din_ch2  = ch2_r;
    assign out_din_ch3  = ch3_r;
    // ch4~7는 sel=1 라운드에서 ch0~3과 동일한 데이터 (out_sel_r로 구분)
    assign out_din_ch4  = ch0_r;
    assign out_din_ch5  = ch1_r;
    assign out_din_ch6  = ch2_r;
    assign out_din_ch7  = ch3_r;

endmodule
