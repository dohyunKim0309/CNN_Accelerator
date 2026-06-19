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

    //==========================================================================
    // ★ 200MHz v2: 저장구조 = 6 row-bank × 64-deep(2set×26col) × 64b 분산 LUTRAM.
    //   routed 빌드 worst(−2.037)가 rb write broadcast (wr_data fo=312, route 93%,
    //   logic 0단)였고, read 쪽도 같은 20K-FF 산개가 근원 → 구조 교체:
    //   - FF 20K + 12:1 read-mux 트리(~5K LUT) 제거 → ~1.3K LUTRAM. 옛 col-mux 는
    //     RAM addressing({set, 4*tx+cc})으로 흡수, write broadcast 는 bank-local
    //     narrow write 로 소멸. (weight per-PE LUTRAM 화(Iter 2)와 동일 처방.)
    //   - write +1 register(wr_*_q): driver 복제 + landing 1-cycle 지연
    //     → engine PDRAIN 3-cycle 로 정렬 (set_ready 지연).
    //   - read-during-write 의미는 FF 판과 동일(edge 전 old 값) → bit-exact 불변.
    //==========================================================================
    // max_fanout 8: data bit 당 sink ~12 (6 bank × 2 copy) → 32 로는 복제가 아예
    //   안 일어났음 (routed: u_rb write 779 EP −1.2~−1.31) → 8 로 강제 분할
    (* max_fanout = 8 *) reg [63:0] wr_data_q;
    (* max_fanout = 8 *) reg        wr_set_q;
    (* max_fanout = 8 *) reg [4:0]  wr_col_q;
    // ★ bank WE 사전 디코드: 옛 [wr_en_q & (row==gr)] 디코드 LUT 출력이 bank 당
    //   fanout 516 net 으로 잔존 (routed −0.19) → row decode 를 q단 앞으로 옮겨
    //   bank 별 등록 WE + max_fanout 복제. write landing cycle 불변 (PDRAIN 3 유지).
    (* max_fanout = 64 *) reg [5:0] wr_bank_we_q;
    integer bi;
    always @(posedge clk) begin
        wr_set_q  <= wr_set;
        wr_col_q  <= wr_col;
        wr_data_q <= wr_data;
        for (bi = 0; bi < 6; bi = bi + 1)
            wr_bank_we_q[bi] <= wr_en && (wr_row == bi);
    end

    // read 주소 6개 (cc=0..5): cbase+cc ≤ 25 → set bit 로 carry 없음
    wire [4:0] cbase = {rd_tx, 2'b00};   // 4*rd_tx (0,4,8,12,16,20)
    reg [5:0] ra [0:5];
    integer ai;
    always @(*) for (ai=0; ai<6; ai=ai+1) ra[ai] = {rd_set, cbase} + ai;

    genvar gr;
    generate for (gr=0; gr<6; gr=gr+1) begin : g_row
        (* ram_style = "distributed" *) reg [63:0] mem [0:63];
        always @(posedge clk)
            if (wr_bank_we_q[gr])
                mem[{wr_set_q, wr_col_q}] <= wr_data_q;

        reg [6*64-1:0] row_rd;
        integer ci;
        always @(*) for (ci=0; ci<6; ci=ci+1)
            row_rd[ci*64 +: 64] = mem[ra[ci]];
        assign tile6_flat[gr*6*64 +: 6*64] = row_rd;
    end endgenerate

endmodule
