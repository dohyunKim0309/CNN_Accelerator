`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_pe_array
// Description:
//   FC SIMD PE array.
//
//   x_flat  : 16 channel activation, 16 * 8 = 128-bit
//   w0_flat : even output column weights, 16 * 8 = 128-bit
//   w1_flat : odd  output column weights, 16 * 8 = 128-bit
//
//   Each lane uses one SIMD-packed DSP cell that computes:
//     p0 = x[ch] * w0[ch]
//     p1 = x[ch] * w1[ch]
//////////////////////////////////////////////////////////////////////////////////

module fc_pe_array (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,

    input  wire [127:0] x_flat,
    input  wire [127:0] w0_flat,
    input  wire [127:0] w1_flat,

    output wire [255:0] p0_flat,
    output wire [255:0] p1_flat
);

    genvar ch;
    generate
        for (ch = 0; ch < 16; ch = ch + 1) begin : gen_ch
            wire signed [7:0]  x_ch  = x_flat [ch*8 +: 8];
            wire signed [7:0]  w0_ch = w0_flat[ch*8 +: 8];
            wire signed [7:0]  w1_ch = w1_flat[ch*8 +: 8];
            wire signed [15:0] p0_ch;
            wire signed [15:0] p1_ch;

            fc_pe_cell cell_inst (
                .clk   (clk),
                .rst   (rst),
                .en    (en),
                .x     (x_ch),
                .w0    (w0_ch),
                .w1    (w1_ch),
                .p0_out(p0_ch),
                .p1_out(p1_ch)
            );

            assign p0_flat[ch*16 +: 16] = p0_ch;
            assign p1_flat[ch*16 +: 16] = p1_ch;
        end
    endgenerate

endmodule
