`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: truncate_relu
// Description:
//   - 누적 결과(24비트 signed)를 INT8로 변환
//   - 처리: >>> 10 (arithmetic) → saturate [-128,127] → ReLU → INT8
//
//   Conv1 용도: N=4 (동시 4채널 처리, 2라운드 × 4채널 = 8OC 총)
//
//   포트 인터페이스 (conv1_engine과 일치):
//     개별 포트 사용: sum0~sum3 (24bit signed 입력)
//                    out0~out3 (8bit signed 출력)
//
//   >>> 10 이유:
//     weight, activation 모두 INT8 quantized (scale = 2^10 추정)
//     >>> 10 후 14비트 signed 범위로 축소
//
//   Saturation + ReLU 통합:
//     val > 127  → 127
//     val < 0    → 0   (ReLU가 음수 saturation 포함)
//     0~127      → 그대로
//
//   레이턴시: 1사이클
//////////////////////////////////////////////////////////////////////////////////

module truncate_relu (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,

    input  wire signed [23:0] sum0,
    input  wire signed [23:0] sum1,
    input  wire signed [23:0] sum2,
    input  wire signed [23:0] sum3,

    output reg signed [7:0] out0,
    output reg signed [7:0] out1,
    output reg signed [7:0] out2,
    output reg signed [7:0] out3
);

    //==========================================================================
    // sat_relu 함수
    //   입력: 14비트 signed (>>> 10 결과)
    //   출력:  8비트 signed
    //==========================================================================
    function signed [7:0] sat_relu;
        input signed [13:0] val;
        begin
            if (val > 14'sd127)
                sat_relu = 8'sd127;
            else if (val < 14'sd0)
                sat_relu = 8'sd0;    // ReLU: 음수 → 0
            else
                sat_relu = val[7:0];
        end
    endfunction

    // arithmetic right shift >>> 10
    wire signed [13:0] sh0 = sum0 >>> 10;
    wire signed [13:0] sh1 = sum1 >>> 10;
    wire signed [13:0] sh2 = sum2 >>> 10;
    wire signed [13:0] sh3 = sum3 >>> 10;

    always @(posedge clk) begin
        if (rst) begin
            out0 <= 8'sd0;
            out1 <= 8'sd0;
            out2 <= 8'sd0;
            out3 <= 8'sd0;
        end else if (en) begin
            out0 <= sat_relu(sh0);
            out1 <= sat_relu(sh1);
            out2 <= sat_relu(sh2);
            out3 <= sat_relu(sh3);
        end
    end

endmodule
