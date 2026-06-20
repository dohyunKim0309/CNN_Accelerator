`timescale 1ns / 1ps
//==============================================================================
// tb_conv1_conv2_multi.v — conv1+conv2 통합 멀티 stress (임의 속도 BFM, N 이미지 bit-exact)
//
//   producer ─[bram_input]─▶ conv1 ─[bram_c1_to_c2]─▶ conv2 ─[bram_c2_to_pool]─▶ consumer
//
//   ★ 중간 핸드쉐이크는 실제 wire (SW 수동 펄스 제거):
//        conv1.wdone → conv2.prior_wdone,   conv2.rdone → conv1.succ_rdone
//   경계만 임의 속도 BFM: producer(앞단, conv1 입력) / consumer(뒷단, conv2 출력).
//   두 엔진이 ping-pong 버퍼 + 개수차 카운터로 자율 동기화하는 "독립 작동" 을
//   random boundary 조건에서 검증 + 프로토콜 assertion. conv1 의 bank_sel_pipe race
//   fix(docs/conv1_timing_table.md)도 random pacing 에서 교차검증.
//
//   BMG: bmg_sim_models.v(iverilog) / 실 IP(Vivado). conv1/conv2 weight = 엔진 내부.
//==============================================================================
`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define ALL_C2POOL_HEX   "data/multi_img/all_c2pool.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "data/weights_simd/conv2_weights_simd.hex"
`else
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define ALL_C2POOL_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
  `define CONV2_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
`endif

module tb_conv1_conv2_multi;
    parameter N_IMAGES = 40;
    parameter [15:0] SEED_P = 16'h5A5A;     // producer LFSR seed
    parameter [15:0] SEED_C = 16'hF00D;     // consumer LFSR seed

    //--------------------------------------------------------------------------
    // clock / reset
    //--------------------------------------------------------------------------
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst         = 1'b1;     // engine reset (active-high)
    reg bfm_rst     = 1'b1;     // BFM hold until setup done
    reg conv2_start = 1'b0;

    //--------------------------------------------------------------------------
    // weight Port A (각 engine 내부 BMG — TB 가 적재)
    //--------------------------------------------------------------------------
    reg        c1w_ena   = 1'b0; reg [3:0] c1w_wea = 4'd0;
    reg [5:0]  c1w_addra = 6'd0; reg [31:0] c1w_dina = 32'd0;
    reg        c2w_ena   = 1'b0; reg [3:0] c2w_wea = 4'd0;
    reg [9:0]  c2w_addra = 10'd0; reg [31:0] c2w_dina = 32'd0;
    reg [31:0] weight1_mem [0:35];
    reg [31:0] weight2_mem [0:575];

    //--------------------------------------------------------------------------
    // nets
    //--------------------------------------------------------------------------
    wire        prior_wdone;             // producer → conv1
    wire        c1_rdone;                // conv1 → producer (credit)
    wire        c1_wdone;                // conv1 → conv2 (★ 실 wire)
    wire        c2_rdone;                // conv2 → conv1 (★ 실 wire)
    wire        c2_wdone;                // conv2 → consumer
    wire        succ_rdone;              // consumer → conv2

    wire        in_ena;  wire [3:0]  in_wea;  wire [8:0]  in_addra; wire [31:0] in_dina;
    wire        in_enb;  wire [10:0] in_addrb; wire signed [7:0] in_doutb;
    wire        m_we;    wire [7:0]  m_wea;   wire [10:0] m_addr;   wire [63:0] m_din;
    wire        m_re;    wire [10:0] m_raddr; wire [63:0] m_rdout;
    wire        c2pool_we; wire [10:0] c2pool_addr; wire [127:0] c2pool_din;
    wire        c2_renb; wire [10:0] c2_raddr; wire [127:0] c2_rdout;
    wire [31:0] p_sent, p_af, c_recv, c_mm, c_af;
    wire        p_done, c_done;

    //--------------------------------------------------------------------------
    // BMG buffers
    //--------------------------------------------------------------------------
    bram_input in_bmg (
        .clka(clk), .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .clkb(clk), .enb(in_enb), .addrb(in_addrb), .doutb(in_doutb));

    // 중간 c1c2 (conv1 write A, conv2 read B) — BFM 없음, 실 ping-pong
    bram_c1_to_c2 mid_bmg (
        .clka(clk), .ena(m_we), .wea(m_wea), .addra(m_addr), .dina(m_din),
        .clkb(clk), .enb(m_re), .addrb(m_raddr), .doutb(m_rdout));

    bram_c2_to_pool out_bmg (
        .clka(clk), .ena(c2pool_we), .wea(c2pool_we), .addra(c2pool_addr), .dina(c2pool_din),
        .clkb(clk), .enb(c2_renb), .addrb(c2_raddr), .doutb(c2_rdout), .regceb(1'b1));

    //--------------------------------------------------------------------------
    // DUTs (중간 핸드쉐이크 실 wire)
    //--------------------------------------------------------------------------
    conv1_engine conv1 (
        .clk(clk), .rst(rst), .start(1'b0), .done(),
        .prior_wdone(prior_wdone), .succ_rdone(c2_rdone), .rdone(c1_rdone), .wdone(c1_wdone),
        .in_bram_addr(in_addrb), .in_bram_en(in_enb), .in_bram_dout(in_doutb),
        .c1w_ena(c1w_ena), .c1w_wea(c1w_wea), .c1w_addra(c1w_addra), .c1w_dina(c1w_dina),
        .c1c2_we(m_we), .c1c2_wea(m_wea), .c1c2_addr(m_addr), .c1c2_din(m_din));

    conv2_engine conv2 (
        .clk(clk), .rst(rst), .start(conv2_start),
        .c2w_ena(c2w_ena), .c2w_wea(c2w_wea), .c2w_addra(c2w_addra), .c2w_dina(c2w_dina),
        .c1c2_re(m_re), .c1c2_addr(m_raddr), .c1c2_dout(m_rdout),
        .c2pool_we(c2pool_we), .c2pool_addr(c2pool_addr), .c2pool_din(c2pool_din),
        .prior_wdone(c1_wdone), .rdone(c2_rdone), .succ_rdone(succ_rdone), .wdone(c2_wdone));

    //--------------------------------------------------------------------------
    // 경계 BFM
    //--------------------------------------------------------------------------
    producer_bfm #(.SRC_DW(8), .DW(32), .WEA_W(4), .AW(9), .WORDS(196),
                   .N_IMAGES(N_IMAGES), .IMG_HEX(`ALL_INPUT_HEX), .SEED(SEED_P),
                   .MAX_IDLE(2000), .STALL_PCT(40), .SETTLE(2)) prod (
        .clk(clk), .rst(bfm_rst), .prior_wdone(prior_wdone), .rdone(c1_rdone),
        .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .img_sent(p_sent), .assert_fail(p_af), .done(p_done));

    // consumer MAX_IDLE 크게: 엔진 chain(~1796/img)보다 consumer burst(576)가 짧아
    // 출력측 backpressure(available=2) 유발 위해 가끔 길게 쉬게 함.
    consumer_bfm #(.DW(128), .AW(11), .WORDS(576), .READ_LAT(2),
                   .N_IMAGES(N_IMAGES), .EXP_HEX(`ALL_C2POOL_HEX), .SEED(SEED_C),
                   .MAX_IDLE(4000), .SETTLE(3)) cons (
        .clk(clk), .rst(bfm_rst), .wdone(c2_wdone), .succ_rdone(succ_rdone),
        .enb(c2_renb), .addrb(c2_raddr), .doutb(c2_rdout),
        .img_recv(c_recv), .mismatch_cnt(c_mm), .assert_fail(c_af), .done(c_done));

    //--------------------------------------------------------------------------
    // backpressure 통계 (입력측 outstanding=2 / 출력측 available=2 도달)
    //--------------------------------------------------------------------------
    integer cyc = 0; always @(posedge clk) if (!bfm_rst) cyc <= cyc + 1;
    reg [31:0] rdc = 0, wdc = 0;
    reg out_sat_d = 0, av_sat_d = 0;
    integer prod_sat = 0, cons_sat = 0;
    always @(posedge clk) begin
        if (bfm_rst) begin rdc <= 0; wdc <= 0; end
        else begin if (c1_rdone) rdc <= rdc + 1; if (c2_wdone) wdc <= wdc + 1; end
    end
    always @(negedge clk) if (!bfm_rst) begin
        if (((p_sent - rdc) >= 2) && !out_sat_d) prod_sat = prod_sat + 1;
        out_sat_d <= ((p_sent - rdc) >= 2);
        if (((wdc - c_recv) >= 2) && !av_sat_d)  cons_sat = cons_sat + 1;
        av_sat_d <= ((wdc - c_recv) >= 2);
    end

    //--------------------------------------------------------------------------
    // weight load
    //--------------------------------------------------------------------------
    task load_w1;
        integer wi;
        begin
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                c1w_ena = 1'b1; c1w_wea = 4'hF; c1w_addra = wi[5:0]; c1w_dina = weight1_mem[wi];
            end
            @(negedge clk); c1w_ena = 1'b0; c1w_wea = 4'd0;
        end
    endtask
    task load_w2;
        integer wi;
        begin
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1; c2w_wea = 4'hF; c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0; c2w_wea = 4'd0;
        end
    endtask

    //--------------------------------------------------------------------------
    // main
    //--------------------------------------------------------------------------
    initial begin : main
        $display("\n=== tb_conv1_conv2_multi (N=%0d, SEED_P=%h SEED_C=%h) ===", N_IMAGES, SEED_P, SEED_C);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);

        rst = 1'b1; bfm_rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;           // engine 가동
        load_w1(); load_w2();                 // weight BMG 적재
        @(negedge clk); conv2_start = 1'b1;   // conv2 LOAD_WEIGHTS (1회)
        @(negedge clk); conv2_start = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk); bfm_rst = 1'b0;       // BFM 시작
        $display("[TB] @ cyc %0d : setup done, BFM released", cyc);

        wait (p_done && c_done);
        repeat (20) @(posedge clk);

        $display("\n=== conv1+conv2 integration result ===");
        $display("  images        : sent=%0d recv=%0d (target %0d)", p_sent, c_recv, N_IMAGES);
        $display("  mismatch      : %0d", c_mm);
        $display("  assert_fail   : producer=%0d consumer=%0d", p_af, c_af);
        $display("  backpressure  : prod_sat=%0d cons_sat=%0d (in/out saturation reached)", prod_sat, cons_sat);
        $display("  total cycles  : %0d", cyc);
        if (c_mm == 0 && p_af == 0 && c_af == 0 && c_recv == N_IMAGES)
            $display("  *** PASS *** (all %0d images bit-exact, no protocol violation)", N_IMAGES);
        else
            $display("  *** FAIL ***");
        $finish;
    end

    initial begin
        #120000000;
        $display("\n[TB] !!! TIMEOUT cyc=%0d sent=%0d recv=%0d !!!", cyc, p_sent, c_recv);
        $finish;
    end
endmodule
