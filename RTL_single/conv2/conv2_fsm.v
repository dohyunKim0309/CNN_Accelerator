`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv2_fsm (single image)
// Description:
//   Conv2 제어 FSM — single image 전용 (ping-pong / 4-way handshake 제거)
//
//   원본(conv2_fsm.v) 대비 변경점:
//     - prior_diff / after_diff 핸드셰이크 카운터 제거
//     - succ_rdone / rdone / wdone 포트 제거
//     - input_bank_sel / output_bank_sel toggle FF 제거 (고정 0)
//     - DONE_LW 상태에서 prior_wdone 1-cycle pulse 대기 후 PIPELINE_FILL 진입
//     - 이미지 처리 완료 후 DRAIN → DONE_LW 복귀 (다음 이미지 대기)
//
//   인터페이스:
//     start       : 1-cycle pulse → LOAD_WEIGHTS 진입
//     prior_wdone : 1-cycle pulse → 이미지 처리 시작 (PIPELINE_FILL)
//////////////////////////////////////////////////////////////////////////////////

module conv2_fsm (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,         // weight load 트리거

    output reg         loader_start,
    input  wire        loader_done,

    input  wire        prior_wdone,   // 이미지 처리 시작 트리거

    output wire [1:0]  sel,
    output wire [1:0]  col_sel,
    output reg         shift_en,
    output reg         pe_en,

    output reg  [4:0]  row_cnt,
    output reg  [4:0]  col_cnt,
    output reg  [9:0]  output_pixel_cnt
);

    localparam [2:0] IDLE             = 3'd0;
    localparam [2:0] LOAD_WEIGHTS     = 3'd1;
    localparam [2:0] DONE_LW          = 3'd2;
    localparam [2:0] PIPELINE_FILL    = 3'd3;
    localparam [2:0] COMPUTE_HOLD     = 3'd4;
    localparam [2:0] COMPUTE_ADVANCE  = 3'd5;
    localparam [2:0] COMPUTE_WRAP     = 3'd6;
    localparam [2:0] DRAIN            = 3'd7;

    reg [2:0] state;
    reg [1:0] kw_cnt;
    reg [1:0] wrap_cnt;
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

    // FSM
    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            kw_cnt     <= 2'd0;
            wrap_cnt   <= 2'd0;
            drain_cnt  <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (start_pulse)
                        state <= LOAD_WEIGHTS;
                end

                LOAD_WEIGHTS: begin
                    if (loader_done)
                        state <= DONE_LW;
                end

                DONE_LW: begin
                    if (pw_pulse)
                        state <= PIPELINE_FILL;
                end

                PIPELINE_FILL: begin
                    if (row_cnt == 5'd2 && col_cnt == 5'd4)
                        state <= COMPUTE_HOLD;
                end

                COMPUTE_HOLD: begin
                    if (kw_cnt == 2'd1) begin
                        state  <= COMPUTE_ADVANCE;
                        kw_cnt <= 2'd2;
                    end else
                        kw_cnt <= kw_cnt + 2'd1;
                end

                COMPUTE_ADVANCE: begin
                    kw_cnt <= 2'd0;
                    if (output_pixel_cnt == 10'd575)
                        state <= DRAIN;
                    else if (col_cnt == 5'd1)
                        state <= COMPUTE_WRAP;
                    else
                        state <= COMPUTE_HOLD;
                end

                COMPUTE_WRAP: begin
                    if (wrap_cnt == 2'd2) begin
                        state    <= COMPUTE_HOLD;
                        wrap_cnt <= 2'd0;
                        kw_cnt   <= 2'd0;
                    end else begin
                        wrap_cnt <= wrap_cnt + 2'd1;
                        kw_cnt   <= kw_cnt + 2'd1;
                    end
                end

                DRAIN: begin
                    if (drain_cnt == 4'd11) begin
                        state     <= DONE_LW;
                        drain_cnt <= 4'd0;
                    end else
                        drain_cnt <= drain_cnt + 4'd1;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // row_cnt / col_cnt
    always @(posedge clk) begin
        if (rst) begin
            row_cnt <= 5'd0; col_cnt <= 5'd0;
        end else if (state == DRAIN && drain_cnt == 4'd11) begin
            row_cnt <= 5'd0; col_cnt <= 5'd0;
        end else if (shift_en) begin
            if (row_cnt == 5'd25 && col_cnt == 5'd25) begin
                // cap
            end else if (col_cnt == 5'd25) begin
                col_cnt <= 5'd0;
                row_cnt <= row_cnt + 5'd1;
            end else
                col_cnt <= col_cnt + 5'd1;
        end
    end

    // output_pixel_cnt
    always @(posedge clk) begin
        if (rst)
            output_pixel_cnt <= 10'd0;
        else if (state == DRAIN && drain_cnt == 4'd11)
            output_pixel_cnt <= 10'd0;
        else if (state == COMPUTE_ADVANCE)
            output_pixel_cnt <= output_pixel_cnt + 10'd1;
        else if (state == COMPUTE_WRAP && wrap_cnt == 2'd2)
            output_pixel_cnt <= output_pixel_cnt + 10'd1;
    end

    // loader_start
    always @(posedge clk) begin
        if (rst)
            loader_start <= 1'b0;
        else
            loader_start <= (state == IDLE) && start_pulse;
    end

    // datapath control
    assign sel     = kw_cnt;
    assign col_sel = (state == COMPUTE_WRAP) ? 2'd0 : kw_cnt;

    always @(*) begin
        shift_en = 1'b0;
        pe_en    = 1'b0;
        case (state)
            PIPELINE_FILL:   shift_en = 1'b1;
            COMPUTE_HOLD:    pe_en    = 1'b1;
            COMPUTE_ADVANCE: begin shift_en = 1'b1; pe_en = 1'b1; end
            COMPUTE_WRAP:    begin shift_en = 1'b1; pe_en = 1'b1; end
            default: begin end
        endcase
    end

endmodule
