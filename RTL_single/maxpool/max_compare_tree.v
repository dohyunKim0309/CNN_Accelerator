`timescale 1ns / 1ps

module max_compare_tree (
    input  wire                clk,
    input  wire                rst,
    input  wire                en,

    // Verilog 호환용 flatten 입력
    input  wire signed [127:0] p00_flat,
    input  wire signed [127:0] p01_flat,
    input  wire signed [127:0] p10_flat,
    input  wire signed [127:0] p11_flat,

    // Verilog 호환용 flatten 출력
    output reg  signed [127:0] max_out_flat
);

    //==========================================================================
    // Stage 1 결과 레지스터
    //==========================================================================
    reg signed [127:0] max_top_flat;
    reg signed [127:0] max_bot_flat;

    // Stage 2 구동용 1클럭 지연 활성화 신호
    reg en_d1;

    integer i;

    //==========================================================================
    // en 1클럭 지연
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            en_d1 <= 1'b0;
        else
            en_d1 <= en;
    end

    //==========================================================================
    // Stage 1
    // 각 채널별로 p00 vs p01, p10 vs p11 비교
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            max_top_flat <= 128'd0;
            max_bot_flat <= 128'd0;
        end else if (en) begin
            for (i = 0; i < 16; i = i + 1) begin
                max_top_flat[i*8 +: 8] <= 
                    ($signed(p00_flat[i*8 +: 8]) > $signed(p01_flat[i*8 +: 8])) ?
                    p00_flat[i*8 +: 8] : p01_flat[i*8 +: 8];

                max_bot_flat[i*8 +: 8] <= 
                    ($signed(p10_flat[i*8 +: 8]) > $signed(p11_flat[i*8 +: 8])) ?
                    p10_flat[i*8 +: 8] : p11_flat[i*8 +: 8];
            end
        end
    end

    //==========================================================================
    // Stage 2
    // 각 채널별로 max_top vs max_bot 비교
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            max_out_flat <= 128'd0;
        end else if (en_d1) begin
            for (i = 0; i < 16; i = i + 1) begin
                max_out_flat[i*8 +: 8] <= 
                    ($signed(max_top_flat[i*8 +: 8]) > $signed(max_bot_flat[i*8 +: 8])) ?
                    max_top_flat[i*8 +: 8] : max_bot_flat[i*8 +: 8];
            end
        end
    end

endmodule