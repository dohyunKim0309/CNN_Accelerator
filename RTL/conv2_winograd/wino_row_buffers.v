`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: wino_row_buffers
// Description:
//   Winograd tile feed 의 line buffer — 2-set × 6 row × 26 col × 64-bit(8 IC).
//   producer 가 set_load 에 tile-row 의 6 row 를 raster write, consumer 가 set_active
//   에서 tile(ty,tx) 의 6×6×8IC 를 **조합** 추출 (col base = 4*tx). 자세한 timing:
//   docs/winograd/conv2_winograd_timing.md §5/§6.
//
//   - write : (wr_en) rb[wr_set][wr_row(0..5)][wr_col(0..25)] <= wr_data (8 IC packed)
//   - read  : (조합) tile6_flat[(rr*6+cc)*64 +: 64] = rb[rd_set][rr][4*rd_tx + cc]
//             rr,cc 0..5. d[rr][cc] = input(4*ty+rr, 4*tx+cc) (golden 인덱스와 동일).
//
//   v1: reg array + 조합 36-way read (distributed RAM/FF + mux). 자원/타이밍 최적화는 후속.
//   ★ Vivado 합성 시 BRAM 추론 안 될 수 있음(comb 다중read) → FF/LUTRAM. 100T 여유 내.
//////////////////////////////////////////////////////////////////////////////////

module wino_row_buffers (
    input  wire        clk,
    input  wire        rst,

    // producer write
    input  wire        wr_en,
    input  wire        wr_set,        // 0/1
    input  wire [2:0]  wr_row,        // 0..5
    input  wire [4:0]  wr_col,        // 0..25
    input  wire [63:0] wr_data,       // 8 IC × 8b

    // consumer read (combinational tile extract)
    input  wire        rd_set,        // 0/1
    input  wire [2:0]  rd_tx,         // 0..5 (tile col index → col base 4*tx)
    output wire [6*6*64-1:0] tile6_flat   // [(rr*6+cc)*64 +: 64]
);

    reg [63:0] rb [0:1][0:5][0:25];

    // write (producer)
    always @(posedge clk) begin
        if (wr_en) rb[wr_set][wr_row][wr_col] <= wr_data;
    end

    // read (consumer, combinational): 6×6 window at col base 4*rd_tx
    // (procedural dynamic-index loop — generate+assign 의 3D 동적 index 가 iverilog 충돌)
    wire [4:0] cbase = {rd_tx, 2'b00};   // 4*rd_tx (0,4,8,12,16,20)
    reg [6*6*64-1:0] tile6_r;
    integer rr, cc;
    always @(*) begin
        for (rr = 0; rr < 6; rr = rr + 1)
            for (cc = 0; cc < 6; cc = cc + 1)
                tile6_r[(rr*6+cc)*64 +: 64] = rb[rd_set][rr][cbase + cc[4:0]];
    end
    assign tile6_flat = tile6_r;

endmodule
