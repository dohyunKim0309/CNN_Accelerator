`timescale 1ns / 1ps
//==============================================================================
// tb_conv2_engine_multi.v — conv2 단독 멀티 stress (임의 속도 BFM, N 이미지 bit-exact)
//
//   producer ─[bram_c1_to_c2]─▶ conv2_engine ─[bram_c2_to_pool]─▶ consumer
//
//   임의 속도 producer(가상 conv1)/consumer(가상 maxpool)가 conv2 의 실제 핸드쉐이크
//   포트로 자율 동작 → 2-deep credit ping-pong + 개수차 카운터를 random backpressure
//   로 독립 검증 + 프로토콜 assertion. conv2 는 start 1회(LOAD_WEIGHTS) 후 prior_wdone 구동.
//
//   BMG: bmg_sim_models.v(iverilog) / 실 IP(Vivado). conv2_weight_bram = conv2 내부.
//   상세: docs/superpowers/specs/2026-06-20-conv12-handshake-stress-tb-design.md
//==============================================================================
`ifdef __ICARUS__
  `define ALL_C1C2_HEX     "data/multi_img/all_c1c2.hex"
  `define ALL_C2POOL_HEX   "data/multi_img/all_c2pool.hex"
  `define CONV2_WEIGHT_HEX "data/weights_simd/conv2_weights_simd.hex"
`else
  `define ALL_C1C2_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c1c2.hex"
  `define ALL_C2POOL_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
  `define CONV2_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"
`endif

module tb_conv2_engine_multi;
    parameter N_IMAGES = 40;
    parameter [15:0] SEED_P = 16'hC0DE;     // producer LFSR seed
    parameter [15:0] SEED_C = 16'h7A5A;     // consumer LFSR seed

    //--------------------------------------------------------------------------
    // clock / reset
    //--------------------------------------------------------------------------
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst        = 1'b1;     // engine reset (active-high)
    reg bfm_rst    = 1'b1;     // BFM hold until setup done
    reg conv2_start = 1'b0;

    //--------------------------------------------------------------------------
    // conv2 weight Port A (engine 내부 BMG — TB 가 적재)
    //--------------------------------------------------------------------------
    reg        c2w_ena   = 1'b0;
    reg [3:0]  c2w_wea   = 4'd0;
    reg [9:0]  c2w_addra = 10'd0;
    reg [31:0] c2w_dina  = 32'd0;
    reg [31:0] weight2_mem [0:575];

    //--------------------------------------------------------------------------
    // nets
    //--------------------------------------------------------------------------
    wire        prior_wdone, rdone, succ_rdone, wdone;
    wire        in_ena;  wire [7:0]  in_wea;  wire [10:0] in_addra; wire [63:0] in_dina;
    wire        in_renb; wire [10:0] in_raddr; wire [63:0] in_rdout;
    wire        c2pool_we; wire [10:0] c2pool_addr; wire [127:0] c2pool_din;
    wire        c2_renb; wire [10:0] c2_raddr; wire [127:0] c2_rdout;
    wire [31:0] p_sent, p_af, c_recv, c_mm, c_af;
    wire        p_done, c_done;

    //--------------------------------------------------------------------------
    // BMG buffers
    //--------------------------------------------------------------------------
    bram_c1_to_c2 in_bmg (
        .clka(clk), .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .clkb(clk), .enb(in_renb), .addrb(in_raddr), .doutb(in_rdout));

    bram_c2_to_pool out_bmg (
        .clka(clk), .ena(c2pool_we), .wea(c2pool_we), .addra(c2pool_addr), .dina(c2pool_din),
        .clkb(clk), .enb(c2_renb), .addrb(c2_raddr), .doutb(c2_rdout), .regceb(1'b1));

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    conv2_engine conv2 (
        .clk(clk), .rst(rst), .start(conv2_start),
        .c2w_ena(c2w_ena), .c2w_wea(c2w_wea), .c2w_addra(c2w_addra), .c2w_dina(c2w_dina),
        .c1c2_re(in_renb), .c1c2_addr(in_raddr), .c1c2_dout(in_rdout),
        .c2pool_we(c2pool_we), .c2pool_addr(c2pool_addr), .c2pool_din(c2pool_din),
        .prior_wdone(prior_wdone), .rdone(rdone), .succ_rdone(succ_rdone), .wdone(wdone));

    //--------------------------------------------------------------------------
    // BFM: 앞단 producer (bram_c1_to_c2) / 뒷단 consumer (bram_c2_to_pool)
    //--------------------------------------------------------------------------
    producer_bfm #(.SRC_DW(64), .DW(64), .WEA_W(8), .AW(11), .WORDS(1024),
                   .N_IMAGES(N_IMAGES), .IMG_HEX(`ALL_C1C2_HEX), .SEED(SEED_P),
                   .MAX_IDLE(2000), .STALL_PCT(40), .SETTLE(2)) prod (
        .clk(clk), .rst(bfm_rst), .prior_wdone(prior_wdone), .rdone(rdone),
        .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .img_sent(p_sent), .assert_fail(p_af), .done(p_done));

    // ★ consumer MAX_IDLE 를 크게 (producer burst 1024 ≫ consumer burst 576 구조라
    //   consumer 가 가끔 길게 쉬어야 출력측 backpressure(available=2)가 발생).
    consumer_bfm #(.DW(128), .AW(11), .WORDS(576), .READ_LAT(2),
                   .N_IMAGES(N_IMAGES), .EXP_HEX(`ALL_C2POOL_HEX), .SEED(SEED_C),
                   .MAX_IDLE(5000), .SETTLE(3)) cons (
        .clk(clk), .rst(bfm_rst), .wdone(wdone), .succ_rdone(succ_rdone),
        .enb(c2_renb), .addrb(c2_raddr), .doutb(c2_rdout),
        .img_recv(c_recv), .mismatch_cnt(c_mm), .assert_fail(c_af), .done(c_done));

    //--------------------------------------------------------------------------
    // backpressure 통계 (outstanding=2 / available=2 도달 횟수)
    //--------------------------------------------------------------------------
    integer cyc = 0; always @(posedge clk) if (!bfm_rst) cyc <= cyc + 1;
    reg [31:0] rdc = 0, wdc = 0;
    reg out_sat_d = 0, av_sat_d = 0;
    integer prod_sat = 0, cons_sat = 0;
    always @(posedge clk) begin
        if (bfm_rst) begin rdc <= 0; wdc <= 0; end
        else begin if (rdone) rdc <= rdc + 1; if (wdone) wdc <= wdc + 1; end
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
        $display("\n=== tb_conv2_engine_multi (N=%0d, SEED_P=%h SEED_C=%h) ===", N_IMAGES, SEED_P, SEED_C);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);

        rst = 1'b1; bfm_rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;           // engine 가동
        load_w2();                            // conv2 weight BMG 적재
        @(negedge clk); conv2_start = 1'b1;   // LOAD_WEIGHTS 진입 (1회)
        @(negedge clk); conv2_start = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk); bfm_rst = 1'b0;       // BFM 시작
        $display("[TB] @ cyc %0d : setup done (weights + start), BFM released", cyc);

        wait (p_done && c_done);
        repeat (20) @(posedge clk);

        $display("\n=== conv2 standalone result ===");
        $display("  images        : sent=%0d recv=%0d (target %0d)", p_sent, c_recv, N_IMAGES);
        $display("  mismatch      : %0d", c_mm);
        $display("  assert_fail   : producer=%0d consumer=%0d", p_af, c_af);
        $display("  backpressure  : prod_sat=%0d cons_sat=%0d (outstanding/available=2 reached)", prod_sat, cons_sat);
        $display("  total cycles  : %0d", cyc);
        if (c_mm == 0 && p_af == 0 && c_af == 0 && c_recv == N_IMAGES)
            $display("  *** PASS *** (all %0d images bit-exact, no protocol violation)", N_IMAGES);
        else
            $display("  *** FAIL ***");
        $finish;
    end

    initial begin
        #80000000;
        $display("\n[TB] !!! TIMEOUT cyc=%0d sent=%0d recv=%0d !!!", cyc, p_sent, c_recv);
        $finish;
    end
endmodule
