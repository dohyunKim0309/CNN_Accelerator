`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv2_winograd_engine_multi.v
//   conv2_winograd_engine (drop-in) multi-image bit-exact.
//   weight = PS-writable pre-transformed U (winograd_u.hex) 를 c2w_* Port A 로 write
//   후 start → engine LOAD_WEIGHTS(loader) → image loop.  (옛 ROM init-없음 대체.)
//   c1c2 = all_c1c2.hex 주입(virtual conv1), c2pool == all_c2pool.hex (winograd==direct
//   라 기존 conv2 golden 재사용). 3-process (conv1 producer / DUT / maxpool consumer).
//
//   iverilog: TB/models/{bmg_sim_models,dsp48e1_model}.v + winograd RTL (RTL/conv2_winograd/*.v).
//   Vivado : 실 BMG IP(bram_c1_to_c2/bram_c2_to_pool/wino_weight_bram)+DSP48E1(UNISIM) →
//            TB/models/* 제외. c2pool 은 Port B read 로 비교(내부 .mem 접근 없음).
//////////////////////////////////////////////////////////////////////////////////

// hex 경로: iverilog=프로젝트 루트 상대 / Vivado=절대(다른 TB 와 동일 base).
`ifdef __ICARUS__
  `define WINO_C1C2_HEX "data/multi_img/all_c1c2.hex"
  `define WINO_C2P_HEX  "data/multi_img/all_c2pool.hex"
  `define WINO_W_HEX    "data/winograd/winograd_u.hex"
`else
  `define WINO_C1C2_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c1c2.hex"
  `define WINO_C2P_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_c2pool.hex"
  `define WINO_W_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/winograd/winograd_u.hex"
`endif

module tb_conv2_winograd_engine_multi;

    parameter N_IMAGES = 40;      // user gate (data 는 100 까지 지원)
    parameter N_WWORD  = 5888;    // pre-transformed U operand word
    parameter CLK = 10;
    reg clk = 0, rst = 1;
    always #(CLK/2) clk = ~clk;

    reg          start = 0;

    // conv2 winograd weight BMG Port A (PS emulation write)
    reg          c2w_ena   = 0;
    reg  [3:0]   c2w_wea   = 0;
    reg  [12:0]  c2w_addra = 0;
    reg  [31:0]  c2w_dina  = 0;
    reg  [31:0]  wino_w [0:N_WWORD-1];

    // c1c2 Port B (DUT read)
    wire         c1c2_re;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_dout_b;
    // c1c2 Port A (virtual conv1 write)
    reg          c1c2_ena_a = 0;
    reg  [7:0]   c1c2_wea_a = 0;
    reg  [10:0]  c1c2_addr_a = 0;
    reg  [63:0]  c1c2_din_a = 0;
    // c2pool Port A (DUT write)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    // c2pool Port B (virtual maxpool read)
    reg          c2pool_enb_b = 0;
    reg  [10:0]  c2pool_addr_b = 0;
    wire [127:0] c2pool_doutb_b;
    // handshake
    reg          prior_wdone = 0;
    wire         rdone;
    reg          succ_rdone = 0;
    wire         wdone;

    bram_c1_to_c2 c1c2_bram (
        .clka(clk), .ena(c1c2_ena_a), .wea(c1c2_wea_a), .addra(c1c2_addr_a), .dina(c1c2_din_a),
        .clkb(clk), .enb(c1c2_re), .addrb(c1c2_addr_b), .doutb(c1c2_dout_b)
    );
    bram_c2_to_pool c2pool_bram (
        .clka(clk), .ena(c2pool_we_a), .wea(1'b1), .addra(c2pool_addr_a), .dina(c2pool_din_a),
        .clkb(clk), .enb(c2pool_enb_b), .addrb(c2pool_addr_b), .doutb(c2pool_doutb_b), .regceb(1'b1)
    );

    conv2_winograd_engine dut (
        .clk(clk), .rst(rst), .start(start),
        .c2w_ena(c2w_ena), .c2w_wea(c2w_wea), .c2w_addra(c2w_addra), .c2w_dina(c2w_dina),
        .c1c2_re(c1c2_re), .c1c2_addr(c1c2_addr_b), .c1c2_dout(c1c2_dout_b),
        .c2pool_we(c2pool_we_a), .c2pool_addr(c2pool_addr_a), .c2pool_din(c2pool_din_a),
        .prior_wdone(prior_wdone), .rdone(rdone), .succ_rdone(succ_rdone), .wdone(wdone)
    );

    //==========================================================================
    // c2pool write-bus snoop → shadow (★ Vivado-compatible: TB wire 만, 내부 .mem 접근 X).
    //   conv2 의 c2pool_we/addr/din(Port A) 를 그대로 기록 = DUT 출력 직접 검증.
    //   instant compare (clock cycle 0) → maxpool wdone cadence 안 깨짐 (read-loop 의
    //   1728cyc>1361 production → wdone miss/hang 문제 회피). addr={bank, local[9:0]}.
    //==========================================================================
    reg [127:0] c2pool_shadow [0:1][0:1023];
    always @(posedge clk)
        if (c2pool_we_a)
            c2pool_shadow[c2pool_addr_a[10]][c2pool_addr_a[9:0]] <= c2pool_din_a;

    reg [63:0]  c1c2_data   [0:N_IMAGES*1024-1];
    reg [127:0] c2pool_data [0:N_IMAGES*576-1];

    integer per_image_mm [0:N_IMAGES-1];
    integer total_mismatches = 0, images_pass = 0, cycle_cnt = 0;
    integer cycle_at_start = 0, cycle_at_wdone [0:N_IMAGES-1];
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    integer rdone_count = 0;
    always @(posedge clk) begin
        if (rst) rdone_count <= 0; else if (rdone) rdone_count <= rdone_count + 1;
    end

    task write_image; input integer img; integer k, bank; begin
        bank = img & 1;
        for (k=0; k<1024; k=k+1) begin
            @(negedge clk); c1c2_ena_a=1; c1c2_wea_a=8'hFF;
            c1c2_addr_a=(bank<<10)|k; c1c2_din_a=c1c2_data[img*1024+k];
        end
        @(negedge clk); c1c2_ena_a=0; c1c2_wea_a=0;
    end endtask

    task pulse_prior; begin @(negedge clk); prior_wdone=1; @(negedge clk); prior_wdone=0; end endtask
    task pulse_succ;  begin @(negedge clk); succ_rdone=1;  @(negedge clk); succ_rdone=0;  end endtask

    // PS emulation: pre-transformed U operand 을 c2w_* Port A 로 순차 write (start 前).
    task write_weights; integer k; begin
        $readmemh(`WINO_W_HEX, wino_w);
        for (k=0; k<N_WWORD; k=k+1) begin
            @(negedge clk); c2w_ena=1; c2w_wea=4'hF; c2w_addra=k[12:0]; c2w_dina=wino_w[k];
        end
        @(negedge clk); c2w_ena=0; c2w_wea=0;
    end endtask

    // shadow(=DUT 가 c2pool 에 쓴 값) 와 golden 비교 — instant (clock 소모 0).
    //   bank=img&1 (output_bank_sel 가 wdone 마다 toggle → image index LSB 와 일치).
    task compare_image; input integer img; integer k, bank, mm; reg [127:0] got, exp; begin
        bank = img & 1; mm = 0;
        for (k=0; k<576; k=k+1) begin
            got = c2pool_shadow[bank][k];
            exp = c2pool_data[img*576+k];
            if (got!==exp) begin
                mm=mm+1;
                if (mm<=6) $display("    MM img=%0d addr=%0d got=%h exp=%h", img, k, got, exp);
            end
        end
        per_image_mm[img]=mm; total_mismatches=total_mismatches+mm;
        if (mm==0) images_pass=images_pass+1;
    end endtask

    reg all_done_flag = 0;
    integer i_main;
    initial begin : main_process
        $display("\n==== conv2_winograd_engine multi (N=%0d, PS pre-transformed weights) ====", N_IMAGES);
        $readmemh(`WINO_C1C2_HEX, c1c2_data);
        $readmemh(`WINO_C2P_HEX, c2pool_data);
        for (i_main=0; i_main<N_IMAGES; i_main=i_main+1) per_image_mm[i_main]=0;

        rst=1; repeat(10) @(posedge clk); @(negedge clk); rst=0;
        write_weights();                  // PS write (c2w_*) 후 start
        @(negedge clk); start=1; @(negedge clk); start=0;
        cycle_at_start = cycle_cnt;
        $display("[TB] weights written, start @ cycle %0d (engine: LOAD_WEIGHTS→loop)", cycle_at_start);

        wait (all_done_flag==1);
        $display("\n==== RESULT : images PASS %0d/%0d, total mismatch %0d ====",
                 images_pass, N_IMAGES, total_mismatches);
        $display("  total cycles (start→last wdone, +weight load) = %0d",
                 cycle_at_wdone[N_IMAGES-1]-cycle_at_start);
        $display("  steady-state cyc/img (wdone[0]→wdone[N-1]) = %0d",
                 (cycle_at_wdone[N_IMAGES-1]-cycle_at_wdone[0])/(N_IMAGES-1));
        if (total_mismatches==0 && images_pass==N_IMAGES) $display("  *** PASS *** (%0d img bit-exact)", N_IMAGES);
        else $display("  *** FAIL ***");
        $finish;
    end

    integer i_c1;
    initial begin : conv1_process
        wait (rst==0); @(negedge clk);
        for (i_c1=0; i_c1<N_IMAGES; i_c1=i_c1+1) begin
            wait ((i_c1 - rdone_count) < 2);   // ping-pong backpressure
            write_image(i_c1);
            pulse_prior();
        end
    end

    integer i_mp;
    initial begin : maxpool_process
        wait (rst==0); @(negedge clk);
        for (i_mp=0; i_mp<N_IMAGES; i_mp=i_mp+1) begin
            @(posedge wdone);
            cycle_at_wdone[i_mp]=cycle_cnt;
            repeat(3) @(posedge clk);
            compare_image(i_mp);
            pulse_succ();
            if (per_image_mm[i_mp]==0) $display("[TB] img %0d PASS @ wdone cyc %0d", i_mp, cycle_at_wdone[i_mp]);
            else $display("[TB] img %0d FAIL (%0d mm) @ wdone cyc %0d", i_mp, per_image_mm[i_mp], cycle_at_wdone[i_mp]);
        end
        all_done_flag=1;
    end

    initial begin #30000000; $display("[TB] TIMEOUT @ cyc %0d (rdone_cnt=%0d)", cycle_cnt, rdone_count); $finish; end
endmodule
