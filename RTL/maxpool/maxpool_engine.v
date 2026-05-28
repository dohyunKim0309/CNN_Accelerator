`timescale 1ns / 1ps

module maxpool_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,           // one-shot system init (legacy)
    output wire         done,            // image 처리 완료 pulse (legacy/debug)

    // 4-way handshake (conv2 패턴 차용)
    //   prior_wdone : Conv2 의 wdone (외부, c2pool buffer 에 새 image 도착 알림)
    //   succ_rdone  : FC 의 rdone (외부, poolfc 의 한 bank 비움 알림)
    //   rdone       : Maxpool 의 c2pool read 완료 (외부 c2pool_pingpong_buffer.maxpool_rdone 으로 연결)
    //   wdone       : Maxpool 의 poolfc write 완료 (외부 poolfc 측 buffer 로)
    input  wire         prior_wdone,
    input  wire         succ_rdone,
    output wire         rdone,
    output wire         wdone,

    // C2Pool ping-pong buffer 읽기 (Port B). local addr only (0~575).
    // bank prepend 는 c2pool_pingpong_buffer 가 자동 처리.
    output wire [9:0]   c2pool_rd_addr,
    output wire         c2pool_rd_en,
    input  wire signed [127:0] c2pool_rd_data,  // 16채널 packed

    // PoolFC buffer 쓰기 (Port A)
    output wire [8:0]   poolfc_wr_addr,
    output wire         poolfc_wr_en,
    output wire [127:0] poolfc_wr_data,
    input  wire         poolfc_bank_sel
);

    //==========================================================================
    // 내부 시그널 선언
    //==========================================================================
    wire         mc_en;

    // Verilog 호환을 위해 unpacked array port 제거
    wire signed [127:0] p00_flat;
    wire signed [127:0] p01_flat;
    wire signed [127:0] p10_flat;
    wire signed [127:0] p11_flat;

    wire         out_valid;
    wire [7:0]   out_addr;

    wire signed [127:0] max_out_flat;

    //==========================================================================
    // 1. MaxPool FSM
    //==========================================================================
    maxpool_fsm fsm (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .done       (done),

        .prior_wdone(prior_wdone),
        .succ_rdone (succ_rdone),
        .rdone      (rdone),
        .wdone      (wdone),

        .rd_addr    (c2pool_rd_addr),
        .rd_en      (c2pool_rd_en),
        .rd_data    (c2pool_rd_data),

        .mc_en      (mc_en),
        .p00_flat   (p00_flat),
        .p01_flat   (p01_flat),
        .p10_flat   (p10_flat),
        .p11_flat   (p11_flat),

        .out_valid  (out_valid),
        .out_addr   (out_addr)
    );

    //==========================================================================
    // 2. Max Compare Tree
    //==========================================================================
    max_compare_tree mct (
        .clk          (clk),
        .rst          (rst),
        .en           (mc_en),
        .p00_flat     (p00_flat),
        .p01_flat     (p01_flat),
        .p10_flat     (p10_flat),
        .p11_flat     (p11_flat),
        .max_out_flat (max_out_flat)
    );

    //==========================================================================
    // 3. Output Stream Packing & Bank Address Generation
    //==========================================================================
    assign poolfc_wr_data = max_out_flat;

    // MSB: bank 선택, LSB 8bit: bank 내부 주소
    assign poolfc_wr_addr = {poolfc_bank_sel, out_addr};
    assign poolfc_wr_en   = out_valid;

endmodule