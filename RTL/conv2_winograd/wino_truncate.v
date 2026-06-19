`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: wino_truncate
// Description:
//   Winograd 출력 Y16(= 16·Y_true, signed) → INT8.
//   out = saturate( Y16 >>> SHIFT ) 후 ReLU  (= clip(Y16>>>14, 0, 127)).
//   SHIFT=14 = layer >>10 + winograd 1/16(>>4). 16·Y>>14 = Y>>10 = direct conv 동일값.
//
//   기존 RTL/core/truncate_relu.v 와 동일 의미(relu+sat) 이나, 입력폭 YW(36) 및 SHIFT(14)
//   가 달라 winograd 전용. N 채널 packed.  Latency 1 cycle (en).
//
//   sat_relu: 음수→0(ReLU+음수sat 통합), >127→127, else 하위 8-bit.
//   (post-shift 값이 8-bit 초과 가능 → 14-bit 비교폭으로 saturate.)
//////////////////////////////////////////////////////////////////////////////////

module wino_truncate #(
    parameter integer N  = 16,    // 동시 채널 수 (OC)
    parameter integer YW = 36,    // Y16 입력폭
    parameter integer SHIFT = 14
)(
    input  wire              clk,
    input  wire              rst,        // active-high synchronous
    input  wire              en,
    input  wire [N*YW-1:0]   y16_flat,   // 채널 i = [i*YW +: YW] (signed)
    // ★ max_fanout: out_flat 1bit → tile_out 32 FF(2bank×16oc) 산포 (routed −1.38,
    //   950 EP) → driver 복제로 collector cluster 근처 출발
    (* max_fanout = 16 *) output reg [N*8-1:0] out_flat   // 채널 i = [i*8 +: 8]
);
    // post-shift 폭 = YW-SHIFT. saturate 비교는 충분폭(여기선 그대로 signed 비교).
    localparam integer SW = YW - SHIFT;   // 22

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : ch
            wire signed [YW-1:0] y_i  = $signed(y16_flat[i*YW +: YW]);
            wire signed [SW-1:0] sh_i = y_i >>> SHIFT;     // arithmetic shift

            always @(posedge clk) begin
                if (rst)
                    out_flat[i*8 +: 8] <= 8'd0;
                else if (en) begin
                    if (sh_i < 0)               out_flat[i*8 +: 8] <= 8'd0;    // ReLU + 음수 sat
                    else if (sh_i > $signed({{(SW-8){1'b0}}, 8'sd127}))
                                                out_flat[i*8 +: 8] <= 8'd127;  // 양수 sat
                    else                        out_flat[i*8 +: 8] <= sh_i[7:0];
                end
            end
        end
    endgenerate
endmodule
