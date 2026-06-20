`timescale 1ns / 1ps
//==============================================================================
// tb_conv1_engine_multi.v — conv1 단독 멀티 stress (임의 속도 BFM, N 이미지 bit-exact)
//
//   producer ─[bram_input]─▶ conv1_engine ─[bram_c1_to_c2]─▶ consumer
//
//   임의 속도 producer(앞단)/consumer(뒷단)가 엔진의 실제 핸드쉐이크 포트로 자율
//   동작 → 2-deep credit ping-pong 과 개수차 카운터를 random backpressure 로 독립
//   검증. conv1 은 prior_wdone 으로 트리거(실 top cnn_accelerator.v 와 동일, start 미사용).
//
//   BMG: bmg_sim_models.v(iverilog) / 실 IP(Vivado). conv1_weight_bram = conv1 내부.
//   상세: docs/superpowers/specs/2026-06-20-conv12-handshake-stress-tb-design.md
//==============================================================================
`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define ALL_C1C2_HEX     "data/multi_img/all_c1c2.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
`else
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define ALL_C1C2_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c1c2.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`endif

module tb_conv1_engine_multi;
    parameter N_IMAGES = 40;
    parameter [15:0] SEED_P = 16'hACE1;     // producer LFSR seed
    parameter [15:0] SEED_C = 16'h1234;     // consumer LFSR seed

    //--------------------------------------------------------------------------
    // clock / reset
    //--------------------------------------------------------------------------
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst     = 1'b1;     // engine reset (active-high)
    reg bfm_rst = 1'b1;     // BFM hold until setup(weight load) done

    //--------------------------------------------------------------------------
    // conv1 weight Port A (engine 내부 BMG — TB 가 적재)
    //--------------------------------------------------------------------------
    reg        c1w_ena   = 1'b0;
    reg [3:0]  c1w_wea   = 4'd0;
    reg [5:0]  c1w_addra = 6'd0;
    reg [31:0] c1w_dina  = 32'd0;
    reg [31:0] weight1_mem [0:35];

    //--------------------------------------------------------------------------
    // nets
    //--------------------------------------------------------------------------
    wire        prior_wdone, rdone, succ_rdone, wdone;
    wire        in_ena;   wire [3:0]  in_wea;  wire [8:0]  in_addra; wire [31:0] in_dina;
    wire        in_enb;   wire [10:0] in_addrb; wire signed [7:0] in_doutb;
    wire        c1c2_we;  wire [7:0]  c1c2_wea; wire [10:0] c1c2_addr; wire [63:0] c1c2_din;
    wire        c1c2_renb; wire [10:0] c1c2_raddr; wire [63:0] c1c2_rdout;
    wire [31:0] p_sent, p_af, c_recv, c_mm, c_af;
    wire        p_done, c_done;

    //--------------------------------------------------------------------------
    // BMG buffers
    //--------------------------------------------------------------------------
    bram_input in_bmg (
        .clka(clk), .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .clkb(clk), .enb(in_enb), .addrb(in_addrb), .doutb(in_doutb));

    bram_c1_to_c2 c1c2_bmg (
        .clka(clk), .ena(c1c2_we), .wea(c1c2_wea), .addra(c1c2_addr), .dina(c1c2_din),
        .clkb(clk), .enb(c1c2_renb), .addrb(c1c2_raddr), .doutb(c1c2_rdout));

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    conv1_engine conv1 (
        .clk(clk), .rst(rst), .start(1'b0), .done(),
        .prior_wdone(prior_wdone), .succ_rdone(succ_rdone), .rdone(rdone), .wdone(wdone),
        .in_bram_addr(in_addrb), .in_bram_en(in_enb), .in_bram_dout(in_doutb),
        .c1w_ena(c1w_ena), .c1w_wea(c1w_wea), .c1w_addra(c1w_addra), .c1w_dina(c1w_dina),
        .c1c2_we(c1c2_we), .c1c2_wea(c1c2_wea), .c1c2_addr(c1c2_addr), .c1c2_din(c1c2_din));

    //--------------------------------------------------------------------------
    // BFM: 앞단 producer (bram_input) / 뒷단 consumer (bram_c1_to_c2)
    //--------------------------------------------------------------------------
    producer_bfm #(.SRC_DW(8), .DW(32), .WEA_W(4), .AW(9), .WORDS(196),
                   .N_IMAGES(N_IMAGES), .IMG_HEX(`ALL_INPUT_HEX), .SEED(SEED_P),
                   .MAX_IDLE(2000), .STALL_PCT(40), .SETTLE(2)) prod (
        .clk(clk), .rst(bfm_rst), .prior_wdone(prior_wdone), .rdone(rdone),
        .ena(in_ena), .wea(in_wea), .addra(in_addra), .dina(in_dina),
        .img_sent(p_sent), .assert_fail(p_af), .done(p_done));

    consumer_bfm #(.DW(64), .AW(11), .WORDS(1024), .READ_LAT(2),
                   .N_IMAGES(N_IMAGES), .EXP_HEX(`ALL_C1C2_HEX), .SEED(SEED_C),
                   .MAX_IDLE(2000), .SETTLE(3)) cons (
        .clk(clk), .rst(bfm_rst), .wdone(wdone), .succ_rdone(succ_rdone),
        .enb(c1c2_renb), .addrb(c1c2_raddr), .doutb(c1c2_rdout),
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

    //--------------------------------------------------------------------------
    // main
    //--------------------------------------------------------------------------
    initial begin : main
        $display("\n=== tb_conv1_engine_multi (N=%0d, SEED_P=%h SEED_C=%h) ===", N_IMAGES, SEED_P, SEED_C);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);

        rst = 1'b1; bfm_rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;           // engine 가동
        load_w1();                            // conv1 weight BMG 적재
        repeat (4) @(posedge clk);
        @(negedge clk); bfm_rst = 1'b0;       // BFM 시작
        $display("[TB] @ cyc %0d : setup done, BFM released", cyc);

        wait (p_done && c_done);
        repeat (20) @(posedge clk);

        $display("\n=== conv1 단독 결과 ===");
        $display("  images        : sent=%0d recv=%0d (target %0d)", p_sent, c_recv, N_IMAGES);
        $display("  mismatch      : %0d", c_mm);
        $display("  assert_fail   : producer=%0d consumer=%0d", p_af, c_af);
        $display("  backpressure  : prod_sat=%0d cons_sat=%0d (outstanding/available=2 도달)", prod_sat, cons_sat);
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
