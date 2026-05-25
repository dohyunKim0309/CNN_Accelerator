`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fc_engine
// Description:
//   FC layer top-level integration.
//   Layer: input (16 ch × 12 × 12 = 2304) INT8 → output 10 logit → argmax.
//
//   구조 (image1 hierarchy 반영, ReLU 제거):
//     fc_fsm           : 제어 (OC 0..9 × spatial 0..143 scan)
//     fc_pe_array      : 16 DSP MAC lane (16 ch product/cycle)
//     fc_adder_tree    : 16:1 signed adder tree (4-stage)
//     fc_accumulator   : 144 spatial partial sum 누적 → logit (24-bit)
//     fc_argmax        : 10 logit 중 최댓값 index(0~9) 탐색
//
//   ★ FC 에는 ReLU 없음. 결과는 ping-pong buffer 에 쓰지 않고 곧바로 argmax.
//
//   데이터 경로:
//     poolfc buffer (16 ch INT8, 128-bit) ──┐
//                                            ├─→ fc_pe_array → fc_adder_tree
//     fc_weight BRAM (16 ch INT8, 128-bit) ─┘        ↓
//                                              fc_accumulator → fc_argmax → 분류결과
//
//   메모리 매핑:
//     poolfc buffer  : addr = {input_bank_sel, s_cnt[7:0]}   (depth 144/bank)
//                      data = {ch15..ch0} INT8 packed (maxpool write 와 동일)
//     fc_weight BRAM : addr = oc_cnt*144 + s_cnt              (depth 1440)
//                      data = {w[oc,s,ch15]..w[oc,s,ch0]} INT8 packed
//                      (fc1_weight.coe/.mem 로 초기화)
//
//   Pipeline depth (FSM addr issue @ T → accumulator updated):
//     BRAM L=2 (2) + pe_array (1) + adder_tree (4) + accumulator (1) = 8 cycle
//
//   외부 BMG IP 가정 (Vivado Block Memory Generator):
//     fc_weight_bram : SDP, 128-bit × 1440, Port B Primitive Output Reg Enable (L=2)
//     poolfc buffer  : 외부 ping-pong (maxpool 이 write, FC 가 Port B read)
//////////////////////////////////////////////////////////////////////////////////

module fc_engine #(
    parameter ACC_W = 24
)(
    input  wire         clk,
    input  wire         rst,                  // active-high synchronous
    input  wire         start,                // PS 로부터 1-cycle pulse

    //==========================================================================
    // FC weight BMG Port A (PS write via AXI BRAM Ctrl)
    //==========================================================================
    input  wire         fcw_ena,              // write enable
    input  wire [10:0]  fcw_addra,            // 0..1439 (11-bit)
    input  wire [127:0] fcw_dina,

    //==========================================================================
    // poolfc buffer Port B (read, L=2) — maxpool 출력 ping-pong
    //==========================================================================
    output wire         poolfc_re,            // ENA = REGCE
    output wire [8:0]   poolfc_addr,          // {input_bank_sel, s_cnt[7:0]}
    input  wire [127:0] poolfc_dout,          // 16 ch × 8b packed

    //==========================================================================
    // 입력측 handshake (vs Maxpool, 1-cycle pulse)
    //==========================================================================
    input  wire         prior_wdone,          // Maxpool → FC
    output wire         rdone,                // FC → Maxpool

    //==========================================================================
    // 분류 결과 출력 (argmax 인덱스만)
    //==========================================================================
    output wire [3:0]   class_idx,            // argmax (0~9)
    output wire         class_valid           // 1-cycle pulse (분류 완료)
);

    //==========================================================================
    // FSM ↔ datapath 신호
    //==========================================================================
    wire [7:0] fsm_s_cnt;
    wire [3:0] fsm_oc_cnt;
    wire [10:0] fsm_wbase;
    wire       fsm_comp_v;
    wire       fsm_oc_first_s;
    wire       fsm_oc_last_s;
    wire       fsm_busy;
    wire       fsm_input_bank_sel;

    //==========================================================================
    // 1. FSM
    //==========================================================================
    fc_fsm fsm_inst (
        .clk            (clk),
        .rst            (rst),
        .start          (start),

        .prior_wdone    (prior_wdone),
        .rdone          (rdone),
        .input_bank_sel (fsm_input_bank_sel),

        .s_cnt          (fsm_s_cnt),
        .oc_cnt         (fsm_oc_cnt),
        .wbase          (fsm_wbase),

        .comp_v         (fsm_comp_v),
        .oc_first_s     (fsm_oc_first_s),
        .oc_last_s      (fsm_oc_last_s),

        .busy           (fsm_busy)
    );

    //==========================================================================
    // 2. poolfc buffer read interface
    //
    //   ★ L=2 BRAM 의 출력 register 게이팅 주의:
    //     마지막 COMPUTE cycle(T)에 issue 한 read 의 data 는 T+2 에 dout 에 등장.
    //     이때 regceb(=output reg clock-enable)가 T+1, T+2 에도 high 여야 한다.
    //     comp_v 만으로 게이팅하면 DRAIN 진입(T+1)에서 regceb 가 떨어져
    //     마지막 2개 read 가 출력 register 에 latch 되지 못함 → stale data 누적.
    //
    //   해결: read/regce enable 를 comp_v 가 떨어진 뒤에도 2 cycle 더 유지
    //         (rd_en_ext = comp_v 또는 직전 2 cycle 동안 comp_v 였음).
    //         addr 는 hold 되지만 enb 로 인해 추가 read 가 일어나도 그 data 는
    //         사용되지 않음 (acc_en 이 정확히 144개만 strobe).
    //==========================================================================
    reg rd_v_d1, rd_v_d2, rd_v_d3;
    always @(posedge clk) begin
        if (rst) begin
            rd_v_d1 <= 1'b0;
            rd_v_d2 <= 1'b0;
            rd_v_d3 <= 1'b0;
        end else begin
            rd_v_d1 <= fsm_comp_v;
            rd_v_d2 <= rd_v_d1;
            rd_v_d3 <= rd_v_d2;
        end
    end
    // comp_v 가 high 였던 마지막 read 들이 출력 register 까지 흘러나오도록 연장
    // (L=2 + addr register 여유분 포함, 3 cycle 연장으로 s=143 까지 보장)
    wire rd_en_ext = fsm_comp_v | rd_v_d1 | rd_v_d2 | rd_v_d3;

    assign poolfc_re   = rd_en_ext;
    assign poolfc_addr = {fsm_input_bank_sel, fsm_s_cnt};

    //==========================================================================
    // 3. FC weight BMG IP (Vivado Block Memory Generator, 외부 IP 인스턴스)
    //   - SDP, common clock, Port B Primitive Output Register Enable (L=2)
    //   - 128-bit × 1440
    //   addr = wbase + s_cnt  (wbase = oc_cnt*144 누산, 곱셈기 없이 덧셈만)
    //==========================================================================
    wire [10:0] fcw_addrb = fsm_wbase + {3'd0, fsm_s_cnt};
    wire [127:0] fcw_doutb;

    fc_weight_bram fcw_bmg_inst (
        .clka  (clk),
        .wea   (fcw_ena),
        .addra (fcw_addra),
        .dina  (fcw_dina),

        .clkb  (clk),
        .enb   (rd_en_ext),
        .addrb (fcw_addrb),
        .doutb (fcw_doutb),
        .regceb(rd_en_ext)
    );

    //==========================================================================
    // 4. PE array (16 DSP) — activation × weight
    //   poolfc_dout 와 fcw_doutb 모두 BRAM L=2 로 동일 정렬됨.
    //   pe_array.en 은 rd_en_ext 를 2-cycle 지연 (BRAM L=2 만큼) 한 값.
    //   (rd_en_ext 기반으로 derive 해야 DRAIN 중 in-flight read 도 PE 까지 흐름)
    //==========================================================================
    reg rd_en_d1, rd_en_d2;
    always @(posedge clk) begin
        if (rst) begin
            rd_en_d1 <= 1'b0;
            rd_en_d2 <= 1'b0;
        end else begin
            rd_en_d1 <= rd_en_ext;
            rd_en_d2 <= rd_en_d1;            // BRAM dout valid 시점과 정렬
        end
    end

    wire [16*16-1:0] prod_flat;

    fc_pe_array pe_inst (
        .clk       (clk),
        .rst       (rst),
        .en        (rd_en_d2),               // BRAM dout 과 같은 cycle enable
        .x_flat    (poolfc_dout),
        .w_flat    (fcw_doutb),
        .prod_flat (prod_flat)
    );

    //==========================================================================
    // 5. 16:1 adder tree (4-stage)
    //   pe_array product 다음 cycle 부터 enable (rd_en_d2 를 1 더 지연 = rd_en_d3)
    //==========================================================================
    reg rd_en_d3;
    always @(posedge clk) begin
        if (rst) rd_en_d3 <= 1'b0;
        else     rd_en_d3 <= rd_en_d2;
    end

    wire signed [19:0] partial_sum;

    fc_adder_tree adder_inst (
        .clk     (clk),
        .rst     (rst),
        .en      (rd_en_d3),                 // product valid cycle 부터 enable
        .in_flat (prod_flat),
        .sum     (partial_sum)
    );

    //==========================================================================
    // 6. accumulator control 정렬
    //
    //   FSM addr issue @ T → partial_sum 이 adder_tree.sum 에 valid 한 시점은
    //   T + 2(BRAM) + 1(pe) + 4(adder) = T+7.
    //   accumulator 는 그 partial_sum 을 다음 edge(T+8)에 latch.
    //
    //   따라서 accumulator 의 en/clear 는 FSM 의 comp_v / oc_first_s 를 7-cycle
    //   지연한 값이어야 한다 (그 cycle 에 partial_sum 이 input 에 present).
    //
    //   oc_last_s 도 7-cycle 지연 → 그 logit 이 acc 에 latch 되는 cycle(T+8)에
    //   acc.out 이 완성 logit → argmax 로 strobe.
    //==========================================================================
    localparam ACC_DELAY = 7;

    reg [ACC_DELAY:0] comp_v_pipe;
    reg [ACC_DELAY:0] first_s_pipe;
    reg [ACC_DELAY:0] last_s_pipe;

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            comp_v_pipe  <= 0;
            first_s_pipe <= 0;
            last_s_pipe  <= 0;
        end else begin
            comp_v_pipe[0]  <= fsm_comp_v;
            first_s_pipe[0] <= fsm_oc_first_s;
            last_s_pipe[0]  <= fsm_oc_last_s;
            for (k = 1; k <= ACC_DELAY; k = k + 1) begin
                comp_v_pipe[k]  <= comp_v_pipe[k-1];
                first_s_pipe[k] <= first_s_pipe[k-1];
                last_s_pipe[k]  <= last_s_pipe[k-1];
            end
        end
    end

    wire acc_en    = comp_v_pipe[ACC_DELAY-1];   // T+7: partial_sum present
    wire acc_clear = first_s_pipe[ACC_DELAY-1];  // T+7: 해당 OC 첫 partial sum
    wire acc_last  = last_s_pipe[ACC_DELAY-1];   // T+7: 해당 OC 마지막 partial sum

    //==========================================================================
    // 7. accumulator (단일, OC 순차 처리)
    //==========================================================================
    wire signed [ACC_W-1:0] logit;

    fc_accumulator #(.ACC_W(ACC_W)) acc_inst (
        .clk       (clk),
        .rst       (rst),
        .en        (acc_en),
        .clear     (acc_clear),
        .in        (partial_sum),
        .out       (logit),
        .out_valid ()                          // 미사용 (상위에서 strobe)
    );

    //==========================================================================
    // 8. logit valid strobe → argmax in_valid
    //   acc_last 가 assert 된 cycle 의 partial_sum 이 다음 edge 에 acc.out 으로
    //   완성됨 → acc_last 를 1-cycle 지연한 신호가 logit valid.
    //==========================================================================
    reg logit_valid;
    always @(posedge clk) begin
        if (rst) logit_valid <= 1'b0;
        else     logit_valid <= acc_last;
    end

    //==========================================================================
    // 9. argmax start strobe
    //   첫 OC(oc=0) 의 첫 logit 비교 전에 초기화.
    //   oc_first_s @ oc=0 를 ACC_DELAY 만큼 지연한 뒤 1-cycle 앞당겨 strobe.
    //   간단히: 가장 첫 acc_clear (oc=0) 직전에 start.
    //   여기서는 FSM busy rising 직후 한 번 start 를 주는 방식 사용.
    //==========================================================================
    reg busy_d1;
    always @(posedge clk) begin
        if (rst) busy_d1 <= 1'b0;
        else     busy_d1 <= fsm_busy;
    end
    wire argmax_start = fsm_busy && ~busy_d1;   // COMPUTE 진입 1-cycle pulse

    //==========================================================================
    // 10. argmax
    //==========================================================================
    fc_argmax #(.ACC_W(ACC_W)) argmax_inst (
        .clk      (clk),
        .rst      (rst),
        .start    (argmax_start),
        .in_valid (logit_valid),
        .in_logit (logit),
        .class_idx(class_idx),
        .done     (class_valid)
    );

endmodule