`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_adder_tree
// Description:
//   16:1 signed adder tree (4-stage pipeline).
//   한 spatial 위치 s 의 16 channel product (16-bit signed) 를 합산하여
//   1개 partial sum (20-bit signed) 출력.
//
//   비트 폭 계산:
//     16-bit 16개 합: 16 + ceil(log2(16)) = 16 + 4 = 20-bit
//
//   Stage 구조 (각 stage 1-cycle pipeline register):
//     Stage 1: 16 → 8  (8 adders, 16+16 → 17-bit)
//     Stage 2:  8 → 4  (4 adders, 17+17 → 18-bit)
//     Stage 3:  4 → 2  (2 adders, 18+18 → 19-bit)
//     Stage 4:  2 → 1  (1 adder, 19+19 → 20-bit)
//
//   Total latency: 4 cycle (input → output)
//   Throughput   : 1 result/cycle (en=1 동안)
//
//   conv2 의 krow_ic_adder_tree 와 동일한 설계 철학 (단 24:1 → 16:1).
//////////////////////////////////////////////////////////////////////////////////

module fc_adder_tree (
    input  wire                clk,
    input  wire                rst,
    input  wire                en,             // pipeline enable

    input  wire [16*16-1:0]    in_flat,        // 16 × 16-bit signed product

    output reg  signed [19:0]  sum             // 20-bit signed
);

    //==========================================================================
    // 0. 입력 unpack (16개 16-bit signed)
    //==========================================================================
    wire signed [15:0] in_arr [0:15];

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack
            assign in_arr[gi] = in_flat[gi*16 +: 16];
        end
    endgenerate

    //==========================================================================
    // 1. Stage 1: 16 → 8 (8 adders, 16+16 → 17-bit)
    //==========================================================================
    reg signed [16:0] s1 [0:7];
    integer i1;
    always @(posedge clk) begin
        if (rst) begin
            for (i1 = 0; i1 < 8; i1 = i1 + 1)
                s1[i1] <= 17'sd0;
        end else if (en) begin
            for (i1 = 0; i1 < 8; i1 = i1 + 1)
                s1[i1] <= in_arr[i1*2] + in_arr[i1*2 + 1];
        end
    end

    //==========================================================================
    // 2. Stage 2: 8 → 4 (4 adders, 17+17 → 18-bit)
    //==========================================================================
    reg signed [17:0] s2 [0:3];
    integer i2;
    always @(posedge clk) begin
        if (rst) begin
            for (i2 = 0; i2 < 4; i2 = i2 + 1)
                s2[i2] <= 18'sd0;
        end else if (en) begin
            for (i2 = 0; i2 < 4; i2 = i2 + 1)
                s2[i2] <= s1[i2*2] + s1[i2*2 + 1];
        end
    end

    //==========================================================================
    // 3. Stage 3: 4 → 2 (2 adders, 18+18 → 19-bit)
    //==========================================================================
    reg signed [18:0] s3 [0:1];
    integer i3;
    always @(posedge clk) begin
        if (rst) begin
            for (i3 = 0; i3 < 2; i3 = i3 + 1)
                s3[i3] <= 19'sd0;
        end else if (en) begin
            for (i3 = 0; i3 < 2; i3 = i3 + 1)
                s3[i3] <= s2[i3*2] + s2[i3*2 + 1];
        end
    end

    //==========================================================================
    // 4. Stage 4: 2 → 1 (1 adder, 19+19 → 20-bit)
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            sum <= 20'sd0;
        else if (en)
            sum <= s3[0] + s3[1];
    end

endmodule