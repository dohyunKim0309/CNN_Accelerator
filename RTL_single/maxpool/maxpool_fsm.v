`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: maxpool_fsm (single image)
// Description:
//   Maxpool 제어 FSM — single image 전용 (ping-pong / 4-way handshake 제거)
//
//   원본(maxpool_fsm.v) 대비 변경점:
//     - prior_diff / after_diff 핸드셰이크 카운터 제거
//     - succ_rdone 포트 제거
//     - rdone / wdone → done 단일 출력으로 통합
//     - input_bank_sel / output_bank_sel toggle FF 제거 (고정 0)
//     - prior_wdone 단순 edge-detect 로 RUN 진입
//////////////////////////////////////////////////////////////////////////////////

module maxpool_fsm (
    input  wire         clk,
    input  wire         rst,
    input  wire         prior_wdone,   // 이미지 시작 트리거
    output reg          done,          // 처리 완료 1-cycle pulse

    // rd/wr 인터페이스 (addr 폭 축소: bank bit 없음)
    output reg  [9:0]   rd_addr,       // c2pool local addr (no bank)
    output reg          rd_en,
    input  wire signed [127:0] rd_data,

    output reg          mc_en,

    output reg signed [127:0] p00_flat,
    output reg signed [127:0] p01_flat,
    output reg signed [127:0] p10_flat,
    output reg signed [127:0] p11_flat,

    output wire         out_valid,
    output wire [7:0]   out_addr
);

    localparam IDLE  = 2'd0;
    localparam RUN   = 2'd1;
    localparam FLUSH = 2'd2;
    localparam DONE  = 2'd3;

    reg [1:0] state;
    reg [3:0] out_row;
    reg [3:0] out_col;
    reg [2:0] phase;
    reg [2:0] flush_cnt;
    reg [7:0] cur_addr_reg;

    // prior_wdone edge-detect
    reg  pw_d;
    wire pw_pulse = prior_wdone & ~pw_d;
    always @(posedge clk) begin
        if (rst) pw_d <= 1'b0;
        else     pw_d <= prior_wdone;
    end

    wire [4:0] in_row = out_row << 1;
    wire [4:0] in_col = out_col << 1;

    wire [9:0] in_row_10 = {5'd0, in_row};
    wire [9:0] in_col_10 = {5'd0, in_col};

    integer j;

    always @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            done         <= 1'b0;
            rd_en        <= 1'b0;
            rd_addr      <= 10'd0;
            mc_en        <= 1'b0;
            out_row      <= 4'd0;
            out_col      <= 4'd0;
            phase        <= 3'd0;
            flush_cnt    <= 3'd0;
            cur_addr_reg <= 8'd0;
            p00_flat     <= 128'd0;
            p01_flat     <= 128'd0;
            p10_flat     <= 128'd0;
            p11_flat     <= 128'd0;
        end else begin
            done  <= 1'b0;
            mc_en <= 1'b0;

            case (state)
                IDLE: begin
                    rd_en     <= 1'b0;
                    out_row   <= 4'd0;
                    out_col   <= 4'd0;
                    phase     <= 3'd0;
                    flush_cnt <= 3'd0;
                    if (pw_pulse)
                        state <= RUN;
                end

                RUN: begin
                    case (phase)
                        3'd0: begin
                            rd_en   <= 1'b1;
                            rd_addr <= (in_row_10 * 10'd24) + in_col_10;
                            phase   <= 3'd1;
                        end
                        3'd1: begin
                            rd_en   <= 1'b1;
                            rd_addr <= (in_row_10 * 10'd24) + (in_col_10 + 10'd1);
                            phase   <= 3'd2;
                        end
                        3'd2: begin
                            rd_en   <= 1'b1;
                            for (j = 0; j < 16; j = j + 1)
                                p00_flat[j*8 +: 8] <= rd_data[j*8 +: 8];
                            rd_addr <= ((in_row_10 + 10'd1) * 10'd24) + in_col_10;
                            phase   <= 3'd3;
                        end
                        3'd3: begin
                            rd_en   <= 1'b1;
                            for (j = 0; j < 16; j = j + 1)
                                p01_flat[j*8 +: 8] <= rd_data[j*8 +: 8];
                            rd_addr <= ((in_row_10 + 10'd1) * 10'd24) + (in_col_10 + 10'd1);
                            phase   <= 3'd4;
                        end
                        3'd4: begin
                            rd_en <= 1'b0;
                            for (j = 0; j < 16; j = j + 1)
                                p10_flat[j*8 +: 8] <= rd_data[j*8 +: 8];
                            phase <= 3'd5;
                        end
                        3'd5: begin
                            rd_en <= 1'b0;
                            for (j = 0; j < 16; j = j + 1)
                                p11_flat[j*8 +: 8] <= rd_data[j*8 +: 8];

                            cur_addr_reg <= ({4'd0, out_row} * 8'd12) + {4'd0, out_col};
                            mc_en <= 1'b1;
                            phase <= 3'd0;

                            if (out_col == 4'd11) begin
                                out_col <= 4'd0;
                                if (out_row == 4'd11)
                                    state <= FLUSH;
                                else
                                    out_row <= out_row + 1'b1;
                            end else
                                out_col <= out_col + 1'b1;
                        end
                        default: phase <= 3'd0;
                    endcase
                end

                FLUSH: begin
                    rd_en     <= 1'b0;
                    flush_cnt <= flush_cnt + 1'b1;
                    if (flush_cnt == 3'd5)
                        state <= DONE;
                end

                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // compare tree latency alignment (2 cycle)
    reg       v_d1, v_d2;
    reg [7:0] a_d1, a_d2;

    always @(posedge clk) begin
        if (rst) begin
            v_d1 <= 1'b0; v_d2 <= 1'b0;
            a_d1 <= 8'd0; a_d2 <= 8'd0;
        end else begin
            v_d1 <= mc_en;        v_d2 <= v_d1;
            a_d1 <= cur_addr_reg; a_d2 <= a_d1;
        end
    end

    assign out_valid = v_d2;
    assign out_addr  = a_d2;

endmodule
