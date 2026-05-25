`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_pe_cell
// Description:
//   FC layer 의 단일 MAC(곱셈) cell. 1개 DSP48 에 매핑.
//   signed INT8 activation × signed INT8 weight → 16-bit signed product.
//
//   conv2 의 pe_cell 과 달리 FC 는 weight 가 매 cycle BRAM 에서 streaming 되므로
//   PE 내부에 weight register 가 없다 (image1: "no register" weight_streamer).
//   곱셈 결과만 1-cycle pipeline register 에 담아 다음 stage(adder tree)로 전달.
//
//   16개 instance 병렬 (16 channel lane = 16 DSP).
//
//   Latency: 1 cycle (x,w @ T → product @ T+1)
//   비트 폭: 8b signed × 8b signed = 16b signed (max |127×-128|=16256 < 2^15)
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_cell (
    input  wire                clk,
    input  wire                rst,
    input  wire                en,            // pipeline enable (= compute valid)

    input  wire signed [7:0]   x,             // activation (1 channel)
    input  wire signed [7:0]   w,             // weight     (1 channel)

    output reg  signed [15:0]  product        // x * w (registered)
);

    always @(posedge clk) begin
        if (rst)
            product <= 16'sd0;
        else if (en)
            product <= x * w;                  // signed * signed → signed
    end

endmodule