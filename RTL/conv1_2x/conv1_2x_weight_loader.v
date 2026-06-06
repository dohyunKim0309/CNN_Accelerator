`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_2x_weight_loader
// Description:
//   - Conv1 2× weight BRAM → pe_cell 36개 weight register 적재.
//   - conv1_weight_loader 와 타이밍 구조 100% 동일(36 word, BRAM L=2, latch 2-cycle
//     shift). ★ 차이는 PE 매핑뿐: 18 PE × depth2 → 36 PE × depth1.
//
//   ★ flat 1:1 매핑 (word k → PE k, 모두 w_regs[0]):
//     conv1_weights_simd[36] 내용은 conv1 과 byte-identical. conv1 은 같은 36 word 를
//     "18 PE × 2 depth(round)" 로 흩뿌렸지만(addr 18~35 → 앞 18 PE 의 w_regs[1]),
//     conv1_2x 는 4 group(36 PE) 이 한 pass 에 8 OC 를 내므로 word k 가 그대로 PE k:
//         addr 0~8   → PE 0~8   (group1, OC0/OC1)
//         addr 9~17  → PE 9~17  (group2, OC2/OC3)
//         addr 18~26 → PE 18~26 (group3, OC4/OC5)
//         addr 27~35 → PE 27~35 (group4, OC6/OC7)
//     DEPTH=1 → load_idx 항상 0 (pe_load_idx 미사용, pe_cell 이 w_regs[0] 직결).
//
//   타이밍 (Latency = 2, conv1_weight_loader 와 동일):
//     T+0 : load_start 수신 → req_cnt=0, active=1
//     T+1 : bram_addr=0 요청, latch_valid=1
//     T+3 : BRAM output register 캡처 → bram_dout=data[0] 유효, latch_valid_dd=1
//     T+4 : latch_cnt=0 적재 (PE 0)
//     ...
//     T+39: latch_cnt=35 처리 (PE 35), load_done=1
//////////////////////////////////////////////////////////////////////////////////

module conv1_2x_weight_loader #(
    parameter integer NUM_PE = 36,
    parameter integer ADDR_W = 6
)(
    input  wire        clk,
    input  wire        rst,                 // active-high (시스템 통일)

    input  wire        load_start,
    output reg         load_done,

    output reg  [ADDR_W-1:0] bram_addr,
    output reg               bram_en,
    input  wire [31:0]       bram_dout,

    output reg  [24:0]       pe_packed_w,
    output reg  [NUM_PE-1:0] pe_load_en,
    output reg               pe_load_idx          // DEPTH=1 → 항상 0
);

    reg        active;
    reg [5:0]  req_cnt;
    reg [5:0]  latch_cnt;
    reg        latch_valid;
    reg        latch_valid_d;
    reg        latch_valid_dd;     // 2사이클 지연 (BRAM L=2 대응)

    always @(posedge clk) begin
        if (rst) begin
            active        <= 1'b0;
            req_cnt       <= 6'd0;
            latch_cnt     <= 6'd0;
            latch_valid   <= 1'b0;
            latch_valid_d <= 1'b0;
            latch_valid_dd<= 1'b0;
            bram_en       <= 1'b0;
            bram_addr     <= {ADDR_W{1'b0}};
            load_done     <= 1'b0;
            pe_packed_w   <= 25'd0;
            pe_load_en    <= {NUM_PE{1'b0}};
            pe_load_idx   <= 1'b0;
        end else begin
            //------------------------------------------------------------------
            // 기본값
            //------------------------------------------------------------------
            load_done      <= 1'b0;
            pe_load_en     <= {NUM_PE{1'b0}};
            pe_load_idx    <= 1'b0;                 // DEPTH=1 → 고정 0
            latch_valid_d  <= latch_valid;
            latch_valid_dd <= latch_valid_d;        // 2 clk 지연 생성

            //------------------------------------------------------------------
            // load_start
            //------------------------------------------------------------------
            if (load_start) begin
                active    <= 1'b1;
                req_cnt   <= 6'd0;
                latch_cnt <= 6'd0;
            end

            //------------------------------------------------------------------
            // BRAM 읽기 요청 (addr 0~35)
            //------------------------------------------------------------------
            if (active && req_cnt <= 6'd35) begin
                bram_en     <= 1'b1;
                bram_addr   <= req_cnt;
                req_cnt     <= req_cnt + 1'b1;
                latch_valid <= 1'b1;
            end else begin
                bram_en     <= 1'b0;
                latch_valid <= 1'b0;
            end

            //------------------------------------------------------------------
            // 래치: latch_valid_dd=1 일 때 bram_dout 최종 유효.
            //   ★ flat 1:1 — word(latch_cnt) → PE(latch_cnt).w_regs[0].
            //------------------------------------------------------------------
            if (latch_valid_dd) begin
                pe_packed_w <= bram_dout[24:0];
                pe_load_en  <= (36'd1 << latch_cnt);    // one-hot, NUM_PE=36

                if (latch_cnt == 6'd35) begin
                    load_done <= 1'b1;
                    active    <= 1'b0;
                    latch_cnt <= 6'd0;
                end else begin
                    latch_cnt <= latch_cnt + 1'b1;
                end
            end
        end
    end

endmodule
