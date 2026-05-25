`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_argmax
// Description:
//   FC layer 의 10개 logit 중 최댓값의 index(0~9, 분류 클래스)를 찾는 모듈.
//   logit 이 OC 0 → 9 순서로 1개씩 streaming 으로 들어옴 (in_valid pulse).
//
//   ★ 출력은 argmax index(0~9) 만. (max logit 값은 출력 안 함)
//
//   동작:
//     start=1 cycle : 비교기 초기화 (best 를 가장 작은 값으로, idx 0)
//     in_valid=1    : in_logit 을 현재 best 와 비교, 더 크면 갱신
//                     (동률 시 먼저 들어온(작은 index) 유지 → strict '>')
//     10개 모두 비교 후 done=1 pulse, class_idx 확정.
//
//   인터페이스 가정:
//     - 10개 logit 이 순차적으로 들어온다 (fc_engine 이 OC 마다 in_valid strobe).
//     - 마지막(10번째, OC=9) logit 의 in_valid 직후 done pulse.
//
//   ping-pong buffer 에 쓰지 않고 곧바로 argmax → 최종 분류 인덱스만 출력.
//
//   Latency: 1 cycle per compare
//////////////////////////////////////////////////////////////////////////////////

module fc_argmax #(
    parameter ACC_W = 24
)(
    input  wire                    clk,
    input  wire                    rst,

    input  wire                    start,      // 1-cycle: 새 image 비교 시작 (초기화)
    input  wire                    in_valid,   // 1-cycle per logit
    input  wire signed [ACC_W-1:0] in_logit,   // OC logit (순서대로 0..9)

    output reg  [3:0]              class_idx,  // argmax (0~9)
    output reg                     done        // 10개 비교 완료 1-cycle pulse
);

    // 현재까지 들어온 logit 개수 (0~9)
    reg [3:0] logit_cnt;

    // best 후보 (비교 진행 중)
    reg [3:0]              best_idx;
    reg signed [ACC_W-1:0] best_val;

    // 가장 작은 값으로 초기화 (ACC_W-bit signed 최소값)
    localparam signed [ACC_W-1:0] NEG_MIN = {1'b1, {(ACC_W-1){1'b0}}};

    always @(posedge clk) begin
        if (rst) begin
            logit_cnt <= 4'd0;
            best_idx  <= 4'd0;
            best_val  <= NEG_MIN;
            class_idx <= 4'd0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start) begin
                // 새 image: 비교 초기화
                logit_cnt <= 4'd0;
                best_idx  <= 4'd0;
                best_val  <= NEG_MIN;
            end

            if (in_valid) begin
                // strict '>' : 동률이면 먼저 들어온(작은 idx) 클래스 유지
                if (in_logit > best_val) begin
                    best_val <= in_logit;
                    best_idx <= logit_cnt;       // 현재 logit 의 OC index
                end

                // 마지막(10번째) logit 이면 결과 확정 + done
                if (logit_cnt == 4'd9) begin
                    if (in_logit > best_val)
                        class_idx <= 4'd9;
                    else
                        class_idx <= best_idx;
                    done      <= 1'b1;
                    logit_cnt <= 4'd0;
                end else begin
                    logit_cnt <= logit_cnt + 4'd1;
                end
            end
        end
    end

endmodule