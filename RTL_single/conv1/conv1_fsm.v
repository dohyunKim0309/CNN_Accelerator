`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_fsm (single image)
// Description:
//   Conv1 제어 FSM — single image 전용 (ping-pong / 4-way handshake 제거)
//
//   원본(conv1_fsm.v) 대비 변경점:
//     - prior_wdone / succ_rdone / rdone / wdone 제거
//     - prior_diff / after_diff 핸드셰이크 카운터 제거
//     - data_ready / output_avail 조건 제거
//     - start 1-cycle pulse → LOAD 직접 진입
//     - DONE 상태에서 done 1-cycle pulse 출력 후 IDLE 복귀
//
//   동작 순서 (원본과 동일):
//     IDLE → (start) → LOAD → RUN1 → FLUSH1 → LBRST → RUN2 → FLUSH2 → DONE → IDLE
//////////////////////////////////////////////////////////////////////////////////

module conv1_fsm (
    input  wire        clk,
    input  wire        rst,               // active-high synchronous
    input  wire        start,             // 1-cycle start pulse

    output reg         load_start,
    input  wire        load_done,

    output reg         pipe_en,
    output reg         sel,
    output reg         lb_rst,

    output wire [4:0]  out_row,
    output wire [4:0]  out_col,
    output wire        out_valid,
    output wire        out_sel,

    output reg         done
);

    localparam IDLE   = 3'd0;
    localparam LOAD   = 3'd1;
    localparam RUN1   = 3'd2;
    localparam FLUSH1 = 3'd3;
    localparam LBRST  = 3'd4;
    localparam RUN2   = 3'd5;
    localparam FLUSH2 = 3'd6;
    localparam DONE_S = 3'd7;

    localparam IMG_W      = 28;
    localparam IMG_H      = 28;
    localparam PIPE_DELAY = 6;

    reg [2:0] state;
    reg [4:0] row, col;
    reg [2:0] flush_cnt;

    // start edge-detect
    reg  start_d;
    wire start_pulse = start & ~start_d;
    always @(posedge clk) begin
        if (rst) start_d <= 1'b0;
        else     start_d <= start;
    end

    wire scan_done = (row == IMG_H-1) && (col == IMG_W-1);
    wire run_state = (state == RUN1) || (state == RUN2);

    // 래스터 스캔 카운터
    always @(posedge clk) begin
        if (rst) begin
            row <= 5'd0; col <= 5'd0;
        end else if (state == FLUSH1 || state == FLUSH2 || state == LBRST) begin
            row <= 5'd0; col <= 5'd0;
        end else if (run_state) begin
            if (col == IMG_W-1) begin
                col <= 5'd0;
                row <= (row == IMG_H-1) ? 5'd0 : row + 1'b1;
            end else
                col <= col + 1'b1;
        end else begin
            row <= 5'd0; col <= 5'd0;
        end
    end

    wire pixel_valid = run_state && (row >= 5'd2) && (col >= 5'd2);

    // FSM
    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            load_start <= 1'b0;
            pipe_en    <= 1'b0;
            sel        <= 1'b0;
            lb_rst     <= 1'b0;
            done       <= 1'b0;
            flush_cnt  <= 3'd0;
        end else begin
            load_start <= 1'b0;
            done       <= 1'b0;
            lb_rst     <= 1'b0;

            case (state)
                IDLE: begin
                    pipe_en <= 1'b0;
                    sel     <= 1'b0;
                    if (start_pulse) begin
                        load_start <= 1'b1;
                        state      <= LOAD;
                    end
                end

                LOAD: begin
                    pipe_en <= 1'b0;
                    if (load_done) begin
                        pipe_en <= 1'b1;
                        sel     <= 1'b0;
                        state   <= RUN1;
                    end
                end

                RUN1: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b0;
                    if (scan_done) begin
                        flush_cnt <= 3'd0;
                        state     <= FLUSH1;
                    end
                end

                FLUSH1: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b0;
                    if (flush_cnt == PIPE_DELAY-1) begin
                        pipe_en   <= 1'b0;
                        flush_cnt <= 3'd0;
                        state     <= LBRST;
                    end else
                        flush_cnt <= flush_cnt + 1'b1;
                end

                LBRST: begin
                    pipe_en <= 1'b0;
                    lb_rst  <= 1'b1;
                    sel     <= 1'b1;
                    state   <= RUN2;
                end

                RUN2: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b1;
                    if (scan_done) begin
                        flush_cnt <= 3'd0;
                        state     <= FLUSH2;
                    end
                end

                FLUSH2: begin
                    pipe_en <= 1'b1;
                    sel     <= 1'b1;
                    if (flush_cnt == PIPE_DELAY-1) begin
                        pipe_en   <= 1'b0;
                        flush_cnt <= 3'd0;
                        state     <= DONE_S;
                    end else
                        flush_cnt <= flush_cnt + 1'b1;
                end

                DONE_S: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // 출력 주소 파이프라인 지연
    reg        valid_sr [0:PIPE_DELAY-1];
    reg [4:0]  row_sr   [0:PIPE_DELAY-1];
    reg [4:0]  col_sr   [0:PIPE_DELAY-1];
    reg        sel_sr   [0:PIPE_DELAY-1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < PIPE_DELAY; i = i + 1) begin
                valid_sr[i] <= 1'b0;
                row_sr[i]   <= 5'd0;
                col_sr[i]   <= 5'd0;
                sel_sr[i]   <= 1'b0;
            end
        end else begin
            valid_sr[0] <= pixel_valid;
            row_sr[0]   <= (row >= 5'd2) ? (row - 5'd2) : 5'd0;
            col_sr[0]   <= (col >= 5'd2) ? (col - 5'd2) : 5'd0;
            sel_sr[0]   <= sel;
            for (i = 1; i < PIPE_DELAY; i = i + 1) begin
                valid_sr[i] <= valid_sr[i-1];
                row_sr[i]   <= row_sr[i-1];
                col_sr[i]   <= col_sr[i-1];
                sel_sr[i]   <= sel_sr[i-1];
            end
        end
    end

    assign out_valid = valid_sr[PIPE_DELAY-1];
    assign out_row   = row_sr  [PIPE_DELAY-1];
    assign out_col   = col_sr  [PIPE_DELAY-1];
    assign out_sel   = sel_sr  [PIPE_DELAY-1];

endmodule
