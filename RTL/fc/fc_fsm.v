`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_fsm
// Description:
//   FC layer 의 제어 FSM (control plane).
//   10개 output class(OC) 를 순차 처리하고, 각 OC 마다 144개 spatial 위치를
//   scan 하여 buffer(activation) 와 weight BRAM 의 read addr 를 생성.
//
//   책임:
//     - 상태 전이 (FSM)
//     - OC counter (oc_cnt 0..9), spatial counter (s_cnt 0..143)
//     - read addr 생성용 좌표 (oc_cnt, s_cnt)
//     - compute valid(comp_v), oc 시작(oc_first_s), oc 마지막(oc_last_s) strobe
//     - 입력 측 handshake (vs Maxpool, poolfc buffer)
//
//   책임 아님 (datapath = fc_engine.v 측):
//     - 실제 BRAM addr 합성 ({bank_sel, addr})
//     - pipeline delay 정렬 (accumulator clear/en, argmax in_valid)
//     - argmax 결과 출력
//
//   FSM 상태:
//     IDLE    : start 대기 (그리고 입력 data_ready 대기)
//     COMPUTE : 10 OC × 144 spatial scan (issue read addr 매 cycle)
//     DRAIN   : 마지막 spatial issue 후 pipeline drain (8 cycle)
//               PE 1 + adder 4 + BRAM 2 + acc 1 = 8.
//     DONE    : 1 image 처리 완료, argmax done 후 IDLE 복귀
//
//   카운터:
//     s_cnt  : 0..143 (현재 cycle 에 issue 하는 spatial read addr)
//     oc_cnt : 0..9   (현재 처리 중인 output class)
//     s_cnt == 143 의 다음 edge 에 oc_cnt++ , s_cnt → 0
//     oc_cnt==9 && s_cnt==143 issue 후 DRAIN 진입
//
//   Handshake (vs Maxpool):
//     prior_diff = (FC rdone count) - (Maxpool wdone count)
//                  data_ready = (prior_diff < 0)  : 처리할 image 가 입력 bank 에 있음
//     입력 bank_sel toggle on rdone.
//     (FC 는 출력이 argmax 분류결과뿐이라 출력측 ping-pong handshake 불필요.)
//////////////////////////////////////////////////////////////////////////////////

module fc_fsm (
    input  wire        clk,
    input  wire        rst,

    //==========================================================================
    // System control
    //==========================================================================
    input  wire        start,            // PS 로부터 1-cycle pulse (시스템 시작)

    //==========================================================================
    // 입력측 handshake (vs Maxpool, poolfc buffer)
    //==========================================================================
    input  wire        prior_wdone,      // Maxpool 로부터 (외부)
    output reg         rdone,            // FC → Maxpool (1-cycle, image read 완료)
    output reg         input_bank_sel,   // poolfc ping-pong bank

    //==========================================================================
    // Datapath control
    //==========================================================================
    output reg  [7:0]  s_cnt,            // spatial read addr (0..143)
    output reg  [3:0]  oc_cnt,           // output class (0..9)
    output reg  [10:0] wbase,            // weight BRAM base = oc_cnt*144 (누산, 곱셈기 없음)

    output reg         comp_v,           // compute valid (이 cycle 에 addr issue)
    output reg         oc_first_s,       // 이 cycle issue 가 해당 OC 의 s=0
    output reg         oc_last_s,        // 이 cycle issue 가 해당 OC 의 s=143

    //==========================================================================
    // Status
    //==========================================================================
    output reg         busy              // COMPUTE/DRAIN 동안 1
);

    //==========================================================================
    // 1. 상태 정의
    //==========================================================================
    localparam [1:0] IDLE    = 2'd0;
    localparam [1:0] COMPUTE = 2'd1;
    localparam [1:0] DRAIN   = 2'd2;
    localparam [1:0] DONE    = 2'd3;

    reg [1:0] state;

    //==========================================================================
    // 2. drain counter (pipeline depth = 8)
    //   BRAM 2 + pe 1 + adder 4 + acc 1 = 8
    //==========================================================================
    localparam [3:0] DRAIN_MAX = 4'd8;
    reg [3:0] drain_cnt;

    //==========================================================================
    // 3. Handshake 차이 카운터 (signed 3-bit)
    //==========================================================================
    reg signed [2:0] prior_diff;
    wire data_ready = (prior_diff < 3'sd0);

    //==========================================================================
    // 4. State + counter update
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            s_cnt     <= 8'd0;
            oc_cnt    <= 4'd0;
            wbase     <= 11'd0;
            drain_cnt <= 4'd0;
        end else begin
            case (state)
                //------------------------------------------------------------------
                // IDLE: start & data_ready 대기
                //------------------------------------------------------------------
                IDLE: begin
                    s_cnt  <= 8'd0;
                    oc_cnt <= 4'd0;
                    wbase  <= 11'd0;
                    if (start && data_ready)
                        state <= COMPUTE;
                end

                //------------------------------------------------------------------
                // COMPUTE: 매 cycle spatial addr issue (s 0..143), OC 0..9
                //   wbase 는 OC 가 넘어갈 때마다 +144 누산 (곱셈기 제거).
                //   weight BRAM addr = wbase + s_cnt (덧셈만).
                //------------------------------------------------------------------
                COMPUTE: begin
                    if (s_cnt == 8'd143) begin
                        s_cnt <= 8'd0;
                        if (oc_cnt == 4'd9) begin
                            // 마지막 OC 의 마지막 spatial issue 완료 → DRAIN
                            oc_cnt    <= 4'd0;
                            wbase     <= 11'd0;
                            state     <= DRAIN;
                            drain_cnt <= 4'd0;
                        end else begin
                            oc_cnt <= oc_cnt + 4'd1;
                            wbase  <= wbase + 11'd144;   // 다음 OC base
                        end
                    end else begin
                        s_cnt <= s_cnt + 8'd1;
                    end
                end

                //------------------------------------------------------------------
                // DRAIN: pipeline 비우기 (8 cycle), 마지막 logit 까지 acc/argmax 도달
                //------------------------------------------------------------------
                DRAIN: begin
                    if (drain_cnt == DRAIN_MAX - 4'd1) begin
                        state     <= DONE;
                        drain_cnt <= 4'd0;
                    end else begin
                        drain_cnt <= drain_cnt + 4'd1;
                    end
                end

                //------------------------------------------------------------------
                // DONE: 1 image 완료. IDLE 복귀 (다음 image).
                //------------------------------------------------------------------
                DONE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    //==========================================================================
    // 5. Datapath control strobe (combinational from state/counters)
    //==========================================================================
    always @(*) begin
        comp_v     = 1'b0;
        oc_first_s = 1'b0;
        oc_last_s  = 1'b0;
        busy       = (state == COMPUTE) || (state == DRAIN);

        if (state == COMPUTE) begin
            comp_v     = 1'b1;
            oc_first_s = (s_cnt == 8'd0);
            oc_last_s  = (s_cnt == 8'd143);
        end
    end

    //==========================================================================
    // 6. rdone pulse
    //   COMPUTE 의 마지막 spatial issue (oc=9, s=143) 직후 image read 완료로 간주.
    //   → 그 cycle 에 rdone pulse (입력 bank 해제, Maxpool 에 통지).
    //==========================================================================
    always @(posedge clk) begin
        if (rst)
            rdone <= 1'b0;
        else
            rdone <= (state == COMPUTE) && (oc_cnt == 4'd9) && (s_cnt == 8'd143);
    end

    //==========================================================================
    // 7. Handshake counter + bank toggle
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            prior_diff <= 3'sd0;
        end else begin
            case ({rdone, prior_wdone})
                2'b10:   prior_diff <= prior_diff + 3'sd1;
                2'b01:   prior_diff <= prior_diff - 3'sd1;
                default: prior_diff <= prior_diff;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst)
            input_bank_sel <= 1'b0;
        else if (rdone)
            input_bank_sel <= ~input_bank_sel;
    end

endmodule