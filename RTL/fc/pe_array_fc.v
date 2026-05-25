`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_pe_array
// Description:
//   FC layer 의 16-channel MAC lane (= 16 DSP).
//   매 cycle 한 spatial 위치 s 의 16 channel activation 과 그에 대응하는
//   16 channel weight 를 받아 16개 product 를 동시에 생성.
//
//   image1 hierarchy: pe_array_fc.v → pe_cell.v
//   image2 spec     : FC layer 에서 16 DSP 사용
//
//   입력 packing (maxpool_engine 의 write 순서와 일치):
//     x_flat[ch*8  +: 8]  = activation channel ch  (ch = 0..15)
//     w_flat[ch*8  +: 8]  = weight     channel ch
//     → x_flat / w_flat 모두 128-bit (16 × INT8)
//
//   출력:
//     prod_flat[ch*16 +: 16] = x[ch] * w[ch]   (16 × 16-bit signed)
//
//   Latency: 1 cycle (fc_pe_cell)
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_array (
    input  wire                clk,
    input  wire                rst,
    input  wire                en,             // pipeline enable

    input  wire [127:0]        x_flat,         // 16 ch activation (INT8 packed)
    input  wire [127:0]        w_flat,         // 16 ch weight     (INT8 packed)

    output wire [16*16-1:0]    prod_flat       // 16 × 16-bit signed product
);

    genvar ch;
    generate
        for (ch = 0; ch < 16; ch = ch + 1) begin : gen_lane
            wire signed [7:0]  x_ch = x_flat[ch*8 +: 8];
            wire signed [7:0]  w_ch = w_flat[ch*8 +: 8];
            wire signed [15:0] p_ch;

            fc_pe_cell pe_inst (
                .clk     (clk),
                .rst     (rst),
                .en      (en),
                .x       (x_ch),
                .w       (w_ch),
                .product (p_ch)
            );

            assign prod_flat[ch*16 +: 16] = p_ch;
        end
    endgenerate

endmodule