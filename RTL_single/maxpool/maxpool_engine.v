`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: maxpool_engine (single image)
// Description:
//   Maxpool top-level — single image 전용 (ping-pong bank / 4-way handshake 제거)
//
//   원본(maxpool_engine.v) 대비 변경점:
//     - rdone / wdone / succ_rdone 포트 제거 → done 단일 출력
//     - c2pool_rd_addr: 10-bit (bank bit 제거)
//     - poolfc_wr_addr: 8-bit (bank bit 제거)
//     - prior_wdone: 이미지 시작 트리거 (단순 edge-detect)
//////////////////////////////////////////////////////////////////////////////////

module maxpool_engine (
    input  wire         clk,
    input  wire         rst,
    output wire         done,          // 처리 완료 pulse

    // prior_wdone: 이미지 준비 트리거
    input  wire         prior_wdone,

    // C2Pool BRAM 읽기 (11-bit addr — bank=0 고정)
    output wire [10:0]  c2pool_rd_addr,
    output wire         c2pool_rd_en,
    input  wire signed [127:0] c2pool_rd_data,

    // PoolFC BRAM 쓰기 (9-bit addr — bank=0 고정)
    output wire [8:0]   poolfc_wr_addr,
    output wire         poolfc_wr_en,
    output wire [127:0] poolfc_wr_data
);

    wire         mc_en;
    wire [9:0]   fsm_rd_addr;
    wire signed [127:0] p00_flat, p01_flat, p10_flat, p11_flat;
    wire         out_valid;
    wire [7:0]   out_addr;
    wire signed [127:0] max_out_flat;

    maxpool_fsm fsm (
        .clk        (clk),
        .rst        (rst),
        .prior_wdone(prior_wdone),
        .done       (done),
        .rd_addr    (fsm_rd_addr),
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

    assign c2pool_rd_addr = {1'b0, fsm_rd_addr};  // bank=0 고정
    assign poolfc_wr_data = max_out_flat;
    assign poolfc_wr_addr = {1'b0, out_addr};     // bank=0 고정
    assign poolfc_wr_en   = out_valid;

endmodule
