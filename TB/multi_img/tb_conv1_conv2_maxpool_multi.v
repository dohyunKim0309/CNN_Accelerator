`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_conv2_maxpool_multi.v
// Conv1 + Conv2 + Maxpool integration multi-image TB (N_IMAGES bit-exact)
//
//   Pipeline:
//     PS → bram_input → Conv1 → bram_c1_to_c2 → Conv2 → bram_c2_to_pool → Maxpool
//                                                                            ↓
//                                                                     poolfc behavioral mem
//                                                                            ↓
//                                                                        TB compare
//
//   3 process 병렬:
//     main_process       : reset → init w1/w2 → conv2 start (1회) → wait all_done → report
//     conv1_dispatcher   : per-image input write + bank toggle + conv1_start + done →
//                          TB pulse conv2.prior_wdone (conv1 측 handshake bridge)
//     compare_process    : @posedge maxpool.wdone → compare poolfc bank (i&1) → pulse maxpool.succ_rdone
//
//   Handshake wiring (4-way, 직접 wire 가능한 부분):
//     conv2.wdone   → maxpool.prior_wdone   (direct wire — conv2 가 image write 완료 알림)
//     maxpool.rdone → conv2.succ_rdone      (direct wire — maxpool 이 c2pool read 완료 알림)
//     conv1.done    → TB pulse → conv2.prior_wdone   (conv1 은 4-way 없으므로 TB 가 변환)
//     maxpool.wdone → TB wait → compare → maxpool.succ_rdone   (가상 FC 역할)
//
//   ping-pong bank:
//     conv1: input_bank_sel = bank_sel = i & 1 (TB driving)
//     conv2: 자동 (fsm_input_bank_sel, fsm_output_bank_sel)
//     c2pool read bank: maxpool_rdone_count[0] (TB 가 BMG addrb prepend)
//     poolfc write bank: maxpool_wdone_count[0] (TB 가 driving maxpool.poolfc_bank_sel)
//
//   필요한 BMG IP:
//     bram_input, conv1_weight_bram, bram_c1_to_c2, conv2_weight_bram, bram_c2_to_pool
//////////////////////////////////////////////////////////////////////////////////

`define ALL_INPUT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
`define ALL_MAXPOOL_HEX   "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_maxpool.hex"
`define CONV1_WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
`define CONV2_WEIGHT_HEX  "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv2_weights_simd.hex"


module tb_conv1_conv2_maxpool_multi;

    parameter N_IMAGES = 40;

    //==========================================================================
    // Clock / reset (100 MHz)
    //   Conv1 = active-low rst_n, Conv2/Maxpool = active-high rst
    //==========================================================================
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire rst = ~rst_n;
    always #5 clk = ~clk;

    //==========================================================================
    // Top-level control
    //==========================================================================
    reg          conv1_start    = 1'b0;
    reg          conv2_start    = 1'b0;
    reg          maxpool_start  = 1'b0;          // legacy (사용 X — prior_wdone 으로 trigger)
    wire         conv1_done;
    wire         maxpool_done;                   // legacy

    // Direct-wire handshake signals
    wire         conv2_rdone, conv2_wdone;
    wire         maxpool_rdone, maxpool_wdone;
    reg          conv2_prior_wdone   = 1'b0;     // TB pulses (from conv1.done)
    reg          maxpool_succ_rdone  = 1'b0;     // TB pulses (after compare, 가상 FC)

    // ping-pong bank for conv1 측 (TB driving)
    reg          input_bank_sel = 1'b0;
    reg          bank_sel       = 1'b0;          // conv1 c1c2 write bank

    //==========================================================================
    // BMG signal nets
    //==========================================================================
    // bram_input
    reg          in_ena   = 1'b0;
    reg          in_wea   = 1'b0;
    reg  [8:0]   in_addra = 9'd0;
    reg  [31:0]  in_dina  = 32'd0;
    wire [10:0]  in_addrb;
    wire         in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram
    reg          w1_ena   = 1'b0;
    reg          w1_wea   = 1'b0;
    reg  [5:0]   w1_addra = 6'd0;
    reg  [31:0]  w1_dina  = 32'd0;
    wire [5:0]   w1_addrb;
    wire         w1_enb;
    wire [31:0]  w1_doutb;

    // bram_c1_to_c2 (conv1 write A, conv2 read B)
    wire         c1c2_we_a;
    wire [7:0]   c1c2_wea_a;
    wire [10:0]  c1c2_addr_a;
    wire [63:0]  c1c2_din_a;
    wire         c1c2_re_b;
    wire [10:0]  c1c2_addr_b;
    wire [63:0]  c1c2_doutb_b;

    // conv2_weight_bram
    reg          c2w_ena   = 1'b0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // bram_c2_to_pool (conv2 write A, maxpool read B)
    wire         c2pool_we_a;
    wire [10:0]  c2pool_addr_a;
    wire [127:0] c2pool_din_a;
    wire [9:0]   maxpool_c2pool_rd_addr;       // 10-bit local addr from maxpool
    wire         c2pool_re_b;
    wire [127:0] c2pool_doutb_b;

    // poolfc 측 (behavioral mem)
    wire [8:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;
    wire         poolfc_bank_sel;              // = wdone_count[0]

    //==========================================================================
    // Counters (handshake-tracked, used for ping-pong bank derivation)
    //==========================================================================
    integer conv2_rdone_count    = 0;          // conv1 dispatcher backpressure
    integer maxpool_rdone_count  = 0;          // c2pool read bank
    integer maxpool_wdone_count  = 0;          // poolfc write bank

    always @(posedge clk) begin
        if (!rst_n) begin
            conv2_rdone_count    <= 0;
            maxpool_rdone_count  <= 0;
            maxpool_wdone_count  <= 0;
        end else begin
            if (conv2_rdone)   conv2_rdone_count   <= conv2_rdone_count   + 1;
            if (maxpool_rdone) maxpool_rdone_count <= maxpool_rdone_count + 1;
            if (maxpool_wdone) maxpool_wdone_count <= maxpool_wdone_count + 1;
        end
    end

    //==========================================================================
    // Bank derivation (TB driving)
    //==========================================================================
    wire c2pool_read_bank = maxpool_rdone_count[0];
    assign poolfc_bank_sel = maxpool_wdone_count[0];

    //==========================================================================
    // BMG IP instances
    //==========================================================================
    bram_input in_bmg (
        .clka  (clk), .ena (in_ena), .wea (in_wea),
        .addra (in_addra), .dina (in_dina),
        .clkb  (clk), .enb (in_enb),
        .addrb (in_addrb), .doutb (in_doutb)
    );

    conv1_weight_bram w1_bmg (
        .clka  (clk), .ena (w1_ena), .wea (w1_wea),
        .addra (w1_addra), .dina (w1_dina),
        .clkb  (clk), .enb (w1_enb),
        .addrb (w1_addrb), .doutb (w1_doutb),
        .regceb(1'b1)
    );

    bram_c1_to_c2 c1c2_bmg (
        .clka  (clk), .ena (c1c2_we_a), .wea (c1c2_wea_a),
        .addra (c1c2_addr_a), .dina (c1c2_din_a),
        .clkb  (clk), .enb (c1c2_re_b),
        .addrb (c1c2_addr_b), .doutb (c1c2_doutb_b)
    );

    bram_c2_to_pool c2pool_bmg (
        .clka  (clk), .ena (c2pool_we_a), .wea (c2pool_we_a),
        .addra (c2pool_addr_a), .dina (c2pool_din_a),
        .clkb  (clk), .enb (c2pool_re_b),
        .addrb ({c2pool_read_bank, maxpool_c2pool_rd_addr}),     // TB 가 bank prepend
        .doutb (c2pool_doutb_b)
    );

    //==========================================================================
    // DUT 1: Conv1
    //==========================================================================
    conv1_engine conv1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (conv1_start),
        .done         (conv1_done),

        .input_bank_sel (input_bank_sel),
        .bank_sel     (bank_sel),

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .w_bram_addr  (w1_addrb),
        .w_bram_en    (w1_enb),
        .w_bram_dout  (w1_doutb),

        .c1c2_we      (c1c2_we_a),
        .c1c2_wea     (c1c2_wea_a),
        .c1c2_addr    (c1c2_addr_a),
        .c1c2_din     (c1c2_din_a)
    );

    //==========================================================================
    // DUT 2: Conv2
    //   prior_wdone : TB pulse (from conv1 done)
    //   succ_rdone  : maxpool.rdone (direct wire)
    //==========================================================================
    conv2_engine conv2 (
        .clk         (clk),
        .rst         (rst),
        .start       (conv2_start),

        .c2w_ena     (c2w_ena),
        .c2w_addra   (c2w_addra),
        .c2w_dina    (c2w_dina),

        .c1c2_re     (c1c2_re_b),
        .c1c2_addr   (c1c2_addr_b),
        .c1c2_dout   (c1c2_doutb_b),

        .c2pool_we   (c2pool_we_a),
        .c2pool_addr (c2pool_addr_a),
        .c2pool_din  (c2pool_din_a),

        .prior_wdone (conv2_prior_wdone),
        .rdone       (conv2_rdone),
        .succ_rdone  (maxpool_rdone),            // direct wire
        .wdone       (conv2_wdone)
    );

    //==========================================================================
    // DUT 3: Maxpool
    //   prior_wdone : conv2.wdone (direct wire)
    //   succ_rdone  : TB pulse (after compare)
    //==========================================================================
    maxpool_engine maxpool (
        .clk             (clk),
        .rst             (rst),
        .start           (maxpool_start),         // legacy (사용 X)
        .done            (maxpool_done),

        .prior_wdone     (conv2_wdone),           // direct wire
        .succ_rdone      (maxpool_succ_rdone),
        .rdone           (maxpool_rdone),
        .wdone           (maxpool_wdone),

        .c2pool_rd_addr  (maxpool_c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_re_b),
        .c2pool_rd_data  (c2pool_doutb_b),

        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data),
        .poolfc_bank_sel (poolfc_bank_sel)
    );

    //==========================================================================
    // poolfc behavioral capture mem (FC 미구현 — 2 bank × 256 = 512 depth)
    //==========================================================================
    reg [127:0] poolfc_mem [0:511];

    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    //==========================================================================
    // TB-local memory
    //==========================================================================
    reg [7:0]   input_data       [0:N_IMAGES*784-1];
    reg [127:0] maxpool_expected [0:N_IMAGES*144-1];
    reg [31:0]  weight1_mem      [0:35];
    reg [31:0]  weight2_mem      [0:575];

    //==========================================================================
    // Statistics
    //==========================================================================
    integer per_image_mm [0:N_IMAGES-1];
    integer total_mismatches = 0;
    integer images_pass = 0;
    integer cycle_cnt = 0;
    integer cycle_at_img_start [0:N_IMAGES-1];
    integer cycle_at_wdone     [0:N_IMAGES-1];
    integer cycle_at_start_pulse = 0;

    always @(posedge clk) if (rst_n) cycle_cnt <= cycle_cnt + 1;

    //==========================================================================
    // Tasks
    //==========================================================================
    task init_weight1;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight1 start (36)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                w1_ena = 1'b1; w1_wea = 1'b1;
                w1_addra = wi[5:0]; w1_dina = weight1_mem[wi];
            end
            @(negedge clk); w1_ena = 1'b0; w1_wea = 1'b0;
            $display("[TB] @ cycle %0d : init_weight1 done", cycle_cnt);
        end
    endtask

    task init_weight2;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight2 start (576)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena = 1'b1;
                c2w_addra = wi[9:0]; c2w_dina = weight2_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0;
            $display("[TB] @ cycle %0d : init_weight2 done", cycle_cnt);
        end
    endtask

    task write_input;
        input integer img_idx;
        integer k;
        reg     bank;
        begin
            bank = img_idx[0];
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena = 1'b1; in_wea = 1'b1;
                in_addra = {bank, k[7:0]};
                in_dina  = {input_data[img_idx*784 + k*4 + 3],
                            input_data[img_idx*784 + k*4 + 2],
                            input_data[img_idx*784 + k*4 + 1],
                            input_data[img_idx*784 + k*4 + 0]};
            end
            @(negedge clk); in_ena = 1'b0; in_wea = 1'b0;
        end
    endtask

    task pulse_conv1_start;
        begin
            @(negedge clk); conv1_start = 1'b1;
            @(negedge clk); conv1_start = 1'b0;
        end
    endtask

    task pulse_conv2_prior_wdone;
        begin
            @(negedge clk); conv2_prior_wdone = 1'b1;
            @(negedge clk); conv2_prior_wdone = 1'b0;
        end
    endtask

    task pulse_maxpool_succ_rdone;
        begin
            @(negedge clk); maxpool_succ_rdone = 1'b1;
            @(negedge clk); maxpool_succ_rdone = 1'b0;
        end
    endtask

    // Read poolfc bank (img&1), compare 144 entry × 128-bit
    //   Bug fix: capture first/last mismatch pixel into separate vars (pixel quirk 회피)
    task compare_image;
        input integer img_idx;
        integer pixel, mm;
        integer first_mm_pixel, last_mm_pixel;
        reg     bank;
        reg [127:0] got, exp;
        reg [127:0] first_mm_got, first_mm_exp;
        begin
            bank = img_idx[0];
            mm = 0;
            first_mm_pixel = -1;
            last_mm_pixel  = -1;
            first_mm_got   = 128'd0;
            first_mm_exp   = 128'd0;

            for (pixel = 0; pixel < 144; pixel = pixel + 1) begin
                got = poolfc_mem[{bank, pixel[7:0]}];
                exp = maxpool_expected[img_idx * 144 + pixel];
                if (got !== exp) begin
                    mm = mm + 1;
                    if (mm == 1) begin
                        first_mm_pixel = pixel;
                        first_mm_got   = got;
                        first_mm_exp   = exp;
                    end
                    last_mm_pixel = pixel;
                end
            end

            if (mm > 0)
                $display("    MM-summary img=%0d : first_pixel=%0d (got=%h, exp=%h) last_pixel=%0d total=%0d/144",
                         img_idx, first_mm_pixel, first_mm_got, first_mm_exp, last_mm_pixel, mm);

            per_image_mm[img_idx] = mm;
            total_mismatches      = total_mismatches + mm;
            if (mm == 0) images_pass = images_pass + 1;
        end
    endtask

    //==========================================================================
    // Cross-process sync
    //==========================================================================
    reg weight_loaded_flag = 1'b0;
    reg all_done_flag      = 1'b0;

    //==========================================================================
    // PROCESS 1: Main
    //==========================================================================
    integer i_main;
    initial begin : main_process
        $display("\n==========================================");
        $display("  Conv1 + Conv2 + Maxpool multi-image TB (N=%0d)", N_IMAGES);
        $display("==========================================");
        $display("  ALL_INPUT_HEX     = %s", `ALL_INPUT_HEX);
        $display("  ALL_MAXPOOL_HEX   = %s", `ALL_MAXPOOL_HEX);
        $display("  CONV1_WEIGHT_HEX  = %s", `CONV1_WEIGHT_HEX);
        $display("  CONV2_WEIGHT_HEX  = %s", `CONV2_WEIGHT_HEX);
        $display("");

        $readmemh(`ALL_INPUT_HEX,    input_data);
        $readmemh(`ALL_MAXPOOL_HEX,  maxpool_expected);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`CONV2_WEIGHT_HEX, weight2_mem);
        $display("[TB] Loaded input (%0d), maxpool exp (%0d), w1 (36), w2 (576)",
                 N_IMAGES * 784, N_IMAGES * 144);

        for (i_main = 0; i_main < N_IMAGES; i_main = i_main + 1) begin
            per_image_mm[i_main]       = 0;
            cycle_at_img_start[i_main] = 0;
            cycle_at_wdone[i_main]     = 0;
        end

        // Reset
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        // Init weights
        init_weight1();
        init_weight2();
        weight_loaded_flag = 1'b1;
        $display("[TB] @ cycle %0d : both weights loaded", cycle_cnt);

        // Conv2 start pulse (LOAD_WEIGHTS 1회)
        @(negedge clk); conv2_start = 1'b1;
        @(negedge clk); conv2_start = 1'b0;
        cycle_at_start_pulse = cycle_cnt;
        $display("[TB] @ cycle %0d : conv2_start pulsed", cycle_at_start_pulse);

        wait (all_done_flag == 1'b1);

        // Final report
        $display("\n=========================================");
        $display("  FINAL RESULT");
        $display("=========================================");
        $display("  images PASS    : %0d / %0d", images_pass, N_IMAGES);
        $display("  total compare  : %0d", N_IMAGES * 144);
        $display("  total mismatch : %0d", total_mismatches);
        $display("  total cycles   : %0d (start → last maxpool.wdone)",
                 cycle_at_wdone[N_IMAGES-1] - cycle_at_start_pulse);
        $display("  avg cycle/img  : %0d",
                 (cycle_at_wdone[N_IMAGES-1] - cycle_at_start_pulse) / N_IMAGES);
        if (total_mismatches == 0 && images_pass == N_IMAGES)
            $display("  *** PASS *** (all %0d images bit-exact)", N_IMAGES);
        else
            $display("  *** FAIL ***");
        $display("=========================================");

        $finish;
    end

    //==========================================================================
    // PROCESS 2: Conv1 dispatcher
    //   per-image input write + bank toggle + conv1_start → conv1.done → TB pulse conv2.prior_wdone
    //==========================================================================
    integer i_conv1;
    initial begin : conv1_dispatcher
        wait (weight_loaded_flag == 1'b1);
        @(negedge clk);

        for (i_conv1 = 0; i_conv1 < N_IMAGES; i_conv1 = i_conv1 + 1) begin
            // Backpressure: c1c2 ping-pong 2-bank → conv2 처리 1개 뒤까지만 허용
            wait ((i_conv1 - conv2_rdone_count) < 2);

            // Set bank for this image
            @(negedge clk);
            input_bank_sel = i_conv1[0];
            bank_sel       = i_conv1[0];

            // Write input to bram_input bank
            write_input(i_conv1);

            // Conv1 start
            cycle_at_img_start[i_conv1] = cycle_cnt;
            pulse_conv1_start();

            // Wait Conv1 done
            @(posedge conv1_done);
            repeat (3) @(posedge clk);          // BMG settle (c1c2 last write commit)

            // Pulse conv2 prior_wdone (conv1 → conv2 handshake bridge)
            pulse_conv2_prior_wdone();
        end
    end

    //==========================================================================
    // PROCESS 3: Compare (가상 FC) — @maxpool.wdone → compare → pulse maxpool.succ_rdone
    //==========================================================================
    integer i_cmp;
    initial begin : compare_process
        wait (rst_n == 1'b1);
        @(negedge clk);

        for (i_cmp = 0; i_cmp < N_IMAGES; i_cmp = i_cmp + 1) begin
            @(posedge maxpool_wdone);
            cycle_at_wdone[i_cmp] = cycle_cnt;

            repeat (3) @(posedge clk);          // poolfc mem settle

            compare_image(i_cmp);
            pulse_maxpool_succ_rdone();

            if (per_image_mm[i_cmp] == 0)
                $display("[TB] img %3d : PASS  @ wdone cycle %0d", i_cmp, cycle_at_wdone[i_cmp]);
            else
                $display("[TB] img %3d : FAIL  @ wdone cycle %0d  (%0d mm)",
                         i_cmp, cycle_at_wdone[i_cmp], per_image_mm[i_cmp]);
        end

        all_done_flag = 1'b1;
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #10000000;
        $display("\n[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

    //==========================================================================
    // DEBUG monitors — bank race / handshake event trace
    //   Drop these blocks once root cause is fixed.
    //==========================================================================

    // Additional counter: conv2 wdone count
    integer conv2_wdone_count = 0;
    always @(posedge clk) begin
        if (!rst_n)            conv2_wdone_count <= 0;
        else if (conv2_wdone)  conv2_wdone_count <= conv2_wdone_count + 1;
    end

    // (1) Handshake events
    always @(posedge clk) begin
        if (rst_n) begin
            if (conv2_wdone)
                $display("[DBG H] cyc=%0d : conv2.wdone   → maxpool.prior_wdone (conv2_wdone count→%0d)",
                         cycle_cnt, conv2_wdone_count + 1);
            if (maxpool_rdone)
                $display("[DBG H] cyc=%0d : maxpool.rdone → conv2.succ_rdone   (maxpool_rdone count→%0d)",
                         cycle_cnt, maxpool_rdone_count + 1);
            if (maxpool_wdone)
                $display("[DBG H] cyc=%0d : maxpool.wdone                       (maxpool_wdone count→%0d)",
                         cycle_cnt, maxpool_wdone_count + 1);
            if (conv2_prior_wdone)
                $display("[DBG H] cyc=%0d : conv2.prior_wdone pulsed (from TB)", cycle_cnt);
            if (maxpool_succ_rdone)
                $display("[DBG H] cyc=%0d : maxpool.succ_rdone pulsed (from TB)", cycle_cnt);
        end
    end

    // (2) c2pool first write per image (한 image 의 첫 write 만 print)
    //     이전 write 의 bank 와 다른 bank 의 write 시 첫 write 로 간주
    reg  [10:0] prev_wr_addr = 11'h7FF;          // 이전 write addr
    integer wr_count_in_image = 0;
    always @(posedge clk) begin
        if (rst_n && c2pool_we_a) begin
            if (c2pool_addr_a[10] != prev_wr_addr[10] || c2pool_addr_a[9:0] == 10'd0) begin
                // bank 바뀜 또는 local 0 → 새 image 시작
                $display("[DBG WR] cyc=%0d : NEW IMG c2pool write start, bank=%b local=%h",
                         cycle_cnt, c2pool_addr_a[10], c2pool_addr_a[9:0]);
                wr_count_in_image <= 1;
            end else begin
                wr_count_in_image <= wr_count_in_image + 1;
            end
            prev_wr_addr <= c2pool_addr_a;
        end
    end

    // (3) c2pool first read per image (read_bank 변화 시 print)
    reg c2pool_read_bank_prev = 1'b0;
    integer rd_count_in_image = 0;
    always @(posedge clk) begin
        c2pool_read_bank_prev <= c2pool_read_bank;
        if (rst_n && c2pool_re_b) begin
            if (c2pool_read_bank != c2pool_read_bank_prev) begin
                $display("[DBG RD] cyc=%0d : NEW IMG c2pool read start, bank=%b (rdone_count=%0d)",
                         cycle_cnt, c2pool_read_bank, maxpool_rdone_count);
                rd_count_in_image <= 1;
            end else begin
                rd_count_in_image <= rd_count_in_image + 1;
            end
        end
    end

    // (3b) Periodic snapshot: 매 200 cycle 마다 write/read 진행도 print
    integer snap_cycle = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            snap_cycle <= snap_cycle + 1;
            if (snap_cycle >= 200) begin
                snap_cycle <= 0;
                $display("[DBG SNAP] cyc=%0d : wr_in_img=%0d (bank=%b local=%h), rd_in_img=%0d (bank=%b local=%h)",
                         cycle_cnt,
                         wr_count_in_image, c2pool_addr_a[10], c2pool_addr_a[9:0],
                         rd_count_in_image, c2pool_read_bank, maxpool_c2pool_rd_addr);
            end
        end
    end

    // (4) Maxpool RUN entry detection — first cycle that c2pool_rd_addr 가 변할 때
    reg [9:0] maxpool_rd_addr_prev = 10'd0;
    always @(posedge clk) maxpool_rd_addr_prev <= maxpool_c2pool_rd_addr;

    // (5) Bank consistency check at the moment of conv2 wdone
    always @(posedge clk) begin
        if (rst_n && conv2_wdone) begin
            $display("[DBG B] cyc=%0d : conv2.wdone — write_bank just done = %b (output_bank_sel), maxpool will read bank=%b",
                     cycle_cnt, c2pool_addr_a[10], c2pool_read_bank);
        end
    end

    // (6) Last c2pool write before conv2.wdone — 정확한 마지막 write addr 확인
    reg [10:0] last_c2pool_wr_addr = 11'd0;
    integer    last_c2pool_wr_cyc = 0;
    always @(posedge clk) begin
        if (rst_n && c2pool_we_a) begin
            last_c2pool_wr_addr <= c2pool_addr_a;
            last_c2pool_wr_cyc  <= cycle_cnt;
        end
        if (rst_n && conv2_wdone) begin
            $display("[DBG LW] cyc=%0d : conv2.wdone — last c2pool write was @ cyc=%0d addr=%h (bank=%b local=%h)",
                     cycle_cnt, last_c2pool_wr_cyc, last_c2pool_wr_addr,
                     last_c2pool_wr_addr[10], last_c2pool_wr_addr[9:0]);
        end
    end

    // (7) Maxpool RUN entry — IDLE→RUN transition 정확 시점 + 모든 state 값
    reg maxpool_was_idle = 1'b1;
    wire maxpool_in_run = (maxpool.fsm.state == 2'd1);  // RUN = 2'd1
    always @(posedge clk) begin
        if (rst_n && maxpool_in_run && maxpool_was_idle) begin
            $display("[DBG MX] cyc=%0d : maxpool IDLE→RUN | prior_diff=%0d prior_next=%0d after_diff=%0d after_next=%0d data_rdy=%b out_avail=%b",
                     cycle_cnt,
                     $signed(maxpool.fsm.prior_diff), $signed(maxpool.fsm.prior_diff_next),
                     $signed(maxpool.fsm.after_diff), $signed(maxpool.fsm.after_diff_next),
                     maxpool.fsm.data_ready, maxpool.fsm.output_avail);
        end
        if (rst_n) maxpool_was_idle <= (maxpool.fsm.state == 2'd0);  // IDLE = 2'd0
    end

    // (8) Maxpool first c2pool read — addr + dout 정확 시점 (RUN 진입 후 첫 read)
    reg c2pool_re_b_prev = 1'b0;
    always @(posedge clk) c2pool_re_b_prev <= c2pool_re_b;

    reg maxpool_first_read_done = 1'b0;
    reg [10:0] expected_first_read_addr = 11'd0;
    integer first_read_cyc = 0;
    always @(posedge clk) begin
        if (rst_n && c2pool_re_b && !c2pool_re_b_prev && !maxpool_first_read_done) begin
            expected_first_read_addr <= {c2pool_read_bank, maxpool_c2pool_rd_addr};
            first_read_cyc            <= cycle_cnt;
            $display("[DBG FR] cyc=%0d : maxpool first read after RUN | addr={%b,%h}",
                     cycle_cnt, c2pool_read_bank, maxpool_c2pool_rd_addr);
            maxpool_first_read_done <= 1'b1;
        end
    end

    // (9) Maxpool first read dout — BMG L=1, dout 1 cycle 후
    integer first_read_dout_cyc = 0;
    reg first_dout_captured = 1'b0;
    always @(posedge clk) begin
        if (rst_n && maxpool_first_read_done && !first_dout_captured) begin
            if (cycle_cnt == first_read_cyc + 1) begin
                $display("[DBG FD] cyc=%0d : maxpool first read dout = %h (low 32b)",
                         cycle_cnt, c2pool_doutb_b[31:0]);
                first_dout_captured <= 1'b1;
            end
        end
    end

endmodule
