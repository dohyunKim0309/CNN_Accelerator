`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_fsm
// Description:
//   FC layer FSM for input layout: input BRAM width = 16*8 = 128-bit,
//   depth = 144 spatial words.
//
//   Weight BRAM layout:
//     width = 256-bit, depth = 720
//     addr  = pair_cnt * 144 + s_cnt
//     LSB [127:0]   = even output column weights, 16ch
//     MSB [255:128] = odd  output column weights, 16ch
//
//   Operation:
//     5 output pairs are processed sequentially.
//     Each pair scans 144 spatial addresses.
//     Total compute issue cycles = 5 * 144 = 720.
//////////////////////////////////////////////////////////////////////////////////

module fc_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    // Handshake with previous ping-pong buffer
    input  wire        prior_wdone,
    output reg         rdone,
    output reg         input_bank_sel,

    // Datapath counters
    output reg  [7:0]  s_cnt,       // 0..143
    output reg  [2:0]  pair_cnt,    // 0..4
    output reg  [9:0]  wbase,       // pair_cnt * 144

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

    // Datapath latency drain margin.
    // Engine aligns control internally; this just keeps busy long enough after last issue.
    localparam [3:0] DRAIN_MAX = 4'd8;

    reg [1:0] state;
    reg [3:0] drain_cnt;

    //==========================================================================
    // Handshake counter (race-free, maxpool 패턴 차용)
    //
    // NBA 의 1-cycle 지연으로 인한 race 회피:
    //   - prior_diff 자체는 register (NBA 로 update)
    //   - data_ready 는 *combinational* prior_diff_next 기준으로 평가
    //   - 같은 cycle 에 rdone 가 high 가 되어도, prior_diff_next 가 즉시 반영
    //     → IDLE 의 transition check 가 정확한 값 사용
    //
    // 동일 cycle 의 race 시나리오 (maxpool 의 false positive 와 대칭):
    //   - PS 가 start, maxpool 이 prior_wdone 을 같은 edge 에 pulse
    //   - 수정 전: data_ready 가 stale prior_diff 봄 → 0 → start 손실 (false negative)
    //   - 수정 후: prior_diff_next 가 prior_wdone 반영 → -1 → data_ready=1 → COMPUTE 진입 ✓
    //
    // 상세 분석: docs/handshake_counter_nba_race.md
    //==========================================================================
    reg signed [2:0] prior_diff;
    reg signed [2:0] prior_diff_next;

    always @(*) begin
        case ({rdone, prior_wdone})
            2'b10:   prior_diff_next = prior_diff + 3'sd1;
            2'b01:   prior_diff_next = prior_diff - 3'sd1;
            2'b11:   prior_diff_next = prior_diff;
            default: prior_diff_next = prior_diff;
        endcase
    end

    wire data_ready = (prior_diff_next < 3'sd0);

    //==========================================================================
    // State + counters
    //==========================================================================
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
                    if (start && data_ready)
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
                    end else begin
                        s_cnt <= s_cnt + 8'd1;
                    end
                end

                DRAIN: begin
                    if (drain_cnt == DRAIN_MAX - 4'd1) begin
                        drain_cnt <= 4'd0;
                        state     <= DONE;
                    end else begin
                        drain_cnt <= drain_cnt + 4'd1;
                    end
                end

                DONE: begin
                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // Datapath strobes
    //==========================================================================
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

    //==========================================================================
    // rdone: one pulse when the last input bank has been consumed.
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            rdone <= 1'b0;
        else
            rdone <= (state == COMPUTE) && (pair_cnt == 3'd4) && (s_cnt == SPATIAL_LAST);
    end

    //==========================================================================
    // Handshake counter register update (next value 그대로 NBA)
    //   prior_wdone increments available written banks.
    //   rdone consumes one readable bank.
    //   *_next 는 위에서 combinational 으로 계산 — race-free.
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            prior_diff <= 3'sd0;
        else
            prior_diff <= prior_diff_next;
    end

    always @(posedge clk) begin
        if (rst)
            input_bank_sel <= 1'b0;
        else if (rdone)
            input_bank_sel <= ~input_bank_sel;
    end

endmodule
