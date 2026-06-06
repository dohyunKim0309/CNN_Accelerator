`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_2x_fsm
// Description:
//   - Conv1 2× (DSP 36, single-round) 제어 FSM. conv1_fsm 의 RUN2/FLUSH2/LBRST/sel
//     를 모두 제거한 5-state 버전.
//
//   DSP 를 18→36 으로 2배 늘려 8 OC 를 한 pass 에 산출 → round(sel) 자체가 사라짐.
//   따라서:
//     - state : 8 → 5 (IDLE/LOAD/RUN/FLUSH/DONE).  RUN2/FLUSH2/LBRST 삭제.
//     - sel / out_sel / lb_rst 출력 삭제 (round 전환이 없음 → line_buffer/window 클리어 불필요).
//     - sel_sr 삭제.
//
//   ★ 데이터패스(BRAM→PE→adder→trunc)는 conv1 과 동일 → PIPE_DELAY/FLUSH_LEN 불변.
//     단일 RUN 은 conv1 의 RUN1 과 동일 정합(in_addr == FSM 카운터, skew 없음)이라
//     engine 의 write pipe 가 we_pipe=2 (ch_final 제거)로 줄어듦. 상세: docs/winograd/conv1_2x_design.md §5.
//
//   인터페이스 (conv1_fsm 과 동일, sel/out_sel/lb_rst 만 제거):
//     - rst         : active-high synchronous reset (시스템 통일)
//     - start       : legacy system-init pulse (사용 X — prior_wdone 으로 trigger)
//     - prior_wdone : 외부에서 image 시작 trigger (입력 image 준비 알림)
//     - succ_rdone  : 외부 다운스트림 read 완료 알림 (Conv2.rdone direct wire)
//     - rdone       : Conv1 의 input bram read 완료 1-cycle pulse (RUN scan_done)
//     - wdone       : Conv1 의 c1c2 write 완료 1-cycle pulse (DONE) → Conv2.prior_wdone
//
//   Handshake counter (conv1_fsm 과 동일, race-free combinational next-value):
//     prior_diff = (rdone count) - (prior_wdone count) ; data_ready = (prior_diff_next < 0)
//     after_diff = (wdone count) - (succ_rdone count)  ; output_avail = (after_diff_next < 2)
//     docs/handshake_counter_nba_race.md 참조.
//
//   파이프라인 딜레이 (conv1 200MHz refactor 와 동일):
//     PIPE_DELAY = L + N_adder + 4 = 2 + 4 + 4 = 10  (valid_sr/row_sr/col_sr 깊이)
//     FLUSH_LEN  = PIPE_DELAY + 2 = 12               (마지막 픽셀 완전 drain)
//////////////////////////////////////////////////////////////////////////////////

module conv1_2x_fsm (
    input  wire        clk,
    input  wire        rst,                  // active-high synchronous
    input  wire        start,                // legacy system init (사용 X)

    // 4-way handshake
    input  wire        prior_wdone,
    input  wire        succ_rdone,
    output reg         rdone,
    output reg         wdone,

    // weight_loader 인터페이스
    output reg         load_start,
    input  wire        load_done,

    // 파이프라인 제어
    output reg         pipe_en,

    // 파이프라인 딜레이 보상 후 출력 주소
    output wire [4:0]  out_row,
    output wire [4:0]  out_col,
    output wire        out_valid,

    output reg         done                  // legacy (debug)
);

    //==========================================================================
    // FSM 상태 (5-state)
    //==========================================================================
    localparam IDLE  = 3'd0;
    localparam LOAD  = 3'd1;
    localparam RUN   = 3'd2;
    localparam FLUSH = 3'd3;
    localparam DONE  = 3'd4;

    reg [2:0] state;

    //==========================================================================
    // 래스터 스캔 카운터
    //==========================================================================
    localparam IMG_W = 28;
    localparam IMG_H = 28;

    // 200MHz refactor 파이프라인 보상 (conv1 과 동일 — 데이터패스 불변)
    //   PIPE_DELAY = OUT_DELAY = L + N_adder + 4  (valid_sr/row_sr/col_sr 깊이)
    //   FLUSH_LEN  = OUT_DELAY + 2                (마지막 픽셀 완전 drain)
    localparam BRAM_L       = 2;                       // bram_input L=2 (Primitives Output Register)
    localparam ADDER_STAGES = 4;                       // conv1_adder_tree pipeline depth
    localparam PIPE_DELAY   = BRAM_L + ADDER_STAGES + 4;
    localparam FLUSH_LEN    = PIPE_DELAY + 2;

    reg [4:0] row;
    reg [4:0] col;

    wire scan_done = (row == IMG_H-1) && (col == IMG_W-1);
    wire run_state = (state == RUN);

    always @(posedge clk) begin
        if (rst) begin
            row <= 5'd0;
            col <= 5'd0;
        end else if (state == FLUSH) begin
            row <= 5'd0;
            col <= 5'd0;
        end else if (run_state) begin
            if (col == IMG_W-1) begin
                col <= 5'd0;
                if (row == IMG_H-1)
                    row <= 5'd0;
                else
                    row <= row + 1'b1;
            end else begin
                col <= col + 1'b1;
            end
        end else begin
            row <= 5'd0;
            col <= 5'd0;
        end
    end

    //==========================================================================
    // pixel_valid: 유효 window (row>=2, col>=2). FSM 내부에서만 사용.
    //==========================================================================
    wire pixel_valid = run_state && (row >= 5'd2) && (col >= 5'd2);

    //==========================================================================
    // flush 카운터 (FLUSH_LEN 까지 카운트 → 4-bit)
    //==========================================================================
    reg [3:0] flush_cnt;

    //==========================================================================
    // Handshake counters (race-free combinational next value) — conv1_fsm 동일
    //==========================================================================
    reg signed [2:0] prior_diff;
    reg signed [2:0] after_diff;
    reg signed [2:0] prior_diff_next;
    reg signed [2:0] after_diff_next;

    always @(*) begin
        case ({rdone, prior_wdone})
            2'b10:   prior_diff_next = prior_diff + 3'sd1;
            2'b01:   prior_diff_next = prior_diff - 3'sd1;
            default: prior_diff_next = prior_diff;
        endcase
        case ({wdone, succ_rdone})
            2'b10:   after_diff_next = after_diff + 3'sd1;
            2'b01:   after_diff_next = after_diff - 3'sd1;
            default: after_diff_next = after_diff;
        endcase
    end

    wire data_ready   = (prior_diff_next < 3'sd0);
    wire output_avail = (after_diff_next < 3'sd2);

    // start edge-detect (legacy)
    reg start_d;
    wire start_pulse = start & ~start_d;

    always @(posedge clk) begin
        if (rst) begin
            prior_diff <= 3'sd0;
            after_diff <= 3'sd0;
            start_d    <= 1'b0;
        end else begin
            prior_diff <= prior_diff_next;
            after_diff <= after_diff_next;
            start_d    <= start;
        end
    end

    //==========================================================================
    // FSM
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            load_start <= 1'b0;
            pipe_en    <= 1'b0;
            done       <= 1'b0;
            rdone      <= 1'b0;
            wdone      <= 1'b0;
            flush_cnt  <= 4'd0;
        end else begin
            // default deasserts
            load_start <= 1'b0;
            done       <= 1'b0;
            rdone      <= 1'b0;
            wdone      <= 1'b0;

            case (state)
                //--------------------------------------------------------------
                IDLE: begin
                    pipe_en <= 1'b0;
                    // RUN 진입 조건: 입력 image 준비 + 출력 bank 여유
                    if ((data_ready && output_avail) || start_pulse) begin
                        load_start <= 1'b1;
                        state      <= LOAD;
                    end
                end

                //--------------------------------------------------------------
                LOAD: begin
                    pipe_en <= 1'b0;
                    if (load_done) begin
                        pipe_en <= 1'b1;          // RUN 진입과 동시에 pipe_en=1 (in_addr 정합)
                        state   <= RUN;
                    end
                end

                //--------------------------------------------------------------
                RUN: begin
                    pipe_en <= 1'b1;
                    if (scan_done) begin
                        flush_cnt <= 4'd0;
                        state     <= FLUSH;
                        rdone     <= 1'b1;        // ★ input read 완료 알림 (마지막 input 이 이 cycle 에 읽힘)
                    end
                end

                //--------------------------------------------------------------
                FLUSH: begin
                    pipe_en <= 1'b1;
                    if (flush_cnt == FLUSH_LEN-1) begin
                        pipe_en   <= 1'b0;
                        flush_cnt <= 4'd0;
                        state     <= DONE;
                    end else begin
                        flush_cnt <= flush_cnt + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                DONE: begin
                    done  <= 1'b1;
                    wdone <= 1'b1;                // ★ c1c2 write 완료 알림
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // 출력 주소 파이프라인 지연 (PIPE_DELAY 사이클) — sel_sr 제거
    //==========================================================================
    reg        valid_sr [0:PIPE_DELAY-1];
    reg [4:0]  row_sr   [0:PIPE_DELAY-1];
    reg [4:0]  col_sr   [0:PIPE_DELAY-1];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < PIPE_DELAY; i = i + 1) begin
                valid_sr[i] <= 1'b0;
                row_sr[i]   <= 5'd0;
                col_sr[i]   <= 5'd0;
            end
        end else begin
            valid_sr[0] <= pixel_valid;
            row_sr[0]   <= (row >= 5'd2) ? (row - 5'd2) : 5'd0;
            col_sr[0]   <= (col >= 5'd2) ? (col - 5'd2) : 5'd0;

            for (i = 1; i < PIPE_DELAY; i = i + 1) begin
                valid_sr[i] <= valid_sr[i-1];
                row_sr[i]   <= row_sr[i-1];
                col_sr[i]   <= col_sr[i-1];
            end
        end
    end

    assign out_valid = valid_sr[PIPE_DELAY-1];
    assign out_row   = row_sr  [PIPE_DELAY-1];
    assign out_col   = col_sr  [PIPE_DELAY-1];

endmodule
