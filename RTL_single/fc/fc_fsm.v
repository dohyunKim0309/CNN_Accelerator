`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_fsm (single image)
// Description:
//   FC FSM — single image 전용 (ping-pong / handshake 카운터 제거)
//
//   원본(fc_fsm.v) 대비 변경점:
//     - prior_diff / prior_diff_next 핸드셰이크 카운터 제거
//     - input_bank_sel toggle FF 제거 (고정 0, poolfc_addr = s_cnt 직접)
//     - rdone 포트 제거
//     - prior_wdone / start edge-detect → COMPUTE 진입 트리거
//////////////////////////////////////////////////////////////////////////////////

module fc_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,         // 첫 이미지 arm pulse (또는 각 이미지 트리거로 사용 가능)

    input  wire        prior_wdone,   // 이미지 처리 시작 트리거

    // Datapath counters
    output reg  [7:0]  s_cnt,
    output reg  [2:0]  pair_cnt,
    output reg  [9:0]  wbase,

    output reg         comp_v,
    output reg         s_first,
    output reg         s_last,
    output reg         busy
);

    localparam [1:0] IDLE    = 2'd0;
    localparam [1:0] COMPUTE = 2'd1;
    localparam [1:0] DRAIN   = 2'd2;
    localparam [1:0] DONE    = 2'd3;

    localparam [7:0] SPATIAL_LAST = 8'd143;
    localparam [9:0] WBASE_STEP   = 10'd144;
    localparam [3:0] DRAIN_MAX    = 4'd10;

    reg [1:0] state;
    reg [3:0] drain_cnt;

    // start edge-detect
    reg  start_d;
    wire start_pulse = start & ~start_d;
    always @(posedge clk) begin
        if (rst) start_d <= 1'b0;
        else     start_d <= start;
    end

    // prior_wdone edge-detect
    reg  pw_d;
    wire pw_pulse = prior_wdone & ~pw_d;
    always @(posedge clk) begin
        if (rst) pw_d <= 1'b0;
        else     pw_d <= prior_wdone;
    end

    wire ready = start_pulse | pw_pulse;

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            s_cnt     <= 8'd0;
            pair_cnt  <= 3'd0;
            wbase     <= 10'd0;
            drain_cnt <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    s_cnt     <= 8'd0;
                    pair_cnt  <= 3'd0;
                    wbase     <= 10'd0;
                    drain_cnt <= 4'd0;
                    if (ready)
                        state <= COMPUTE;
                end

                COMPUTE: begin
                    if (s_cnt == SPATIAL_LAST) begin
                        s_cnt <= 8'd0;
                        if (pair_cnt == 3'd4) begin
                            pair_cnt  <= 3'd0;
                            wbase     <= 10'd0;
                            drain_cnt <= 4'd0;
                            state     <= DRAIN;
                        end else begin
                            pair_cnt <= pair_cnt + 3'd1;
                            wbase    <= wbase + WBASE_STEP;
                        end
                    end else
                        s_cnt <= s_cnt + 8'd1;
                end

                DRAIN: begin
                    if (drain_cnt == DRAIN_MAX - 4'd1) begin
                        drain_cnt <= 4'd0;
                        state     <= DONE;
                    end else
                        drain_cnt <= drain_cnt + 4'd1;
                end

                DONE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    always @(*) begin
        comp_v  = 1'b0;
        s_first = 1'b0;
        s_last  = 1'b0;
        busy    = (state == COMPUTE) || (state == DRAIN);
        if (state == COMPUTE) begin
            comp_v  = 1'b1;
            s_first = (s_cnt == 8'd0);
            s_last  = (s_cnt == SPATIAL_LAST);
        end
    end

endmodule
