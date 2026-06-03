`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv2_engine.v  (single image — RTL_single 용)
//
//   RTL_single/conv2/conv2_engine.v 검증
//   ping-pong / 4-way handshake 없음
//
//   자극 순서:
//     reset → init_weight → write_c1c2 → start (weight load) → prior_wdone (image) → wait wdone → compare
//////////////////////////////////////////////////////////////////////////////////

`define DATA_DIR   "data_single"
`define CONV1_HEX  `DATA_DIR "/conv1_output_c1c2.hex"
`define WEIGHT_HEX `DATA_DIR "/conv2_weights_simd.hex"
`define CONV2_HEX  `DATA_DIR "/conv2_output_c2pool.hex"

module tb_conv2_engine;

    parameter CLK_PERIOD = 10;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    // DUT 포트
    reg          start      = 1'b0;
    reg          prior_wdone = 1'b0;
    wire         wdone;

    // conv2_weight_bram Port A
    reg          c2w_ena   = 1'b0;
    reg  [3:0]   c2w_wea   = 4'd0;
    reg  [9:0]   c2w_addra = 10'd0;
    reg  [31:0]  c2w_dina  = 32'd0;

    // c1c2 BRAM (10-bit addr, 64-bit × 1024)
    wire         c1c2_re;
    wire [9:0]   c1c2_addr_b;
    wire [63:0]  c1c2_dout_b;

    reg          c1c2_ena_a  = 1'b0;
    reg  [7:0]   c1c2_wea_a  = 8'h00;
    reg  [9:0]   c1c2_addr_a = 10'd0;
    reg  [63:0]  c1c2_din_a  = 64'd0;

    // c2pool BRAM (10-bit addr, 128-bit × 1024)
    wire         c2pool_we_a;
    wire [9:0]   c2pool_addr_a;
    wire [127:0] c2pool_din_a;

    reg          c2pool_enb   = 1'b0;
    reg  [9:0]   c2pool_addrb = 10'd0;
    wire [127:0] c2pool_doutb;

    //--------------------------------------------------------------------------
    // 내장 BRAM 모델
    //--------------------------------------------------------------------------
    // c1c2 BRAM (byte-write, 64-bit × 1024)
    reg [7:0] c1c2_mem [0:8191];

    always @(posedge clk) begin : c1c2_portA
        integer bi;
        if (c1c2_ena_a) begin
            for (bi = 0; bi < 8; bi = bi + 1)
                if (c1c2_wea_a[bi])
                    c1c2_mem[{c1c2_addr_a, 3'b000} + bi] <= c1c2_din_a[bi*8 +: 8];
        end
    end

    // L=2 : 2-stage pipeline read
    reg [63:0] c1c2_pipe1, c1c2_pipe2;
    always @(posedge clk) begin : c1c2_portB
        integer bi;
        reg [63:0] word;
        if (c1c2_re) begin
            for (bi = 0; bi < 8; bi = bi + 1)
                word[bi*8 +: 8] = c1c2_mem[{c1c2_addr_b, 3'b000} + bi];
            c1c2_pipe1 <= word;
            c1c2_pipe2 <= c1c2_pipe1;
        end
    end
    assign c1c2_dout_b = c1c2_pipe2;

    // c2pool BRAM (128-bit × 1024)
    reg [7:0] c2pool_mem [0:16383];

    always @(posedge clk) begin : c2pool_portA
        integer bi;
        if (c2pool_we_a) begin
            for (bi = 0; bi < 16; bi = bi + 1)
                c2pool_mem[{c2pool_addr_a, 4'b0000} + bi] <= c2pool_din_a[bi*8 +: 8];
        end
    end

    reg [127:0] c2pool_doutb_r;
    always @(posedge clk) begin : c2pool_portB
        integer bi;
        if (c2pool_enb) begin
            for (bi = 0; bi < 16; bi = bi + 1)
                c2pool_doutb_r[bi*8 +: 8] <= c2pool_mem[{c2pool_addrb, 4'b0000} + bi];
        end
    end
    assign c2pool_doutb = c2pool_doutb_r;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    conv2_engine dut (
        .clk          (clk), .rst(rst),
        .start        (start),

        .c2w_ena      (c2w_ena), .c2w_wea(c2w_wea),
        .c2w_addra    (c2w_addra), .c2w_dina(c2w_dina),

        .c1c2_re      (c1c2_re),
        .c1c2_addr    (c1c2_addr_b),
        .c1c2_dout    (c1c2_dout_b),

        .c2pool_we    (c2pool_we_a),
        .c2pool_addr  (c2pool_addr_a),
        .c2pool_din   (c2pool_din_a),

        .prior_wdone  (prior_wdone),
        .wdone        (wdone)
    );

    //--------------------------------------------------------------------------
    // TB-local data
    //--------------------------------------------------------------------------
    reg [63:0]  c1c2_data       [0:1023];
    reg [31:0]  weight_mem      [0:575];
    reg [127:0] expected_c2pool [0:575];

    integer cycle_cnt = 0;
    integer cycle_at_start, cycle_at_prior, cycle_at_wdone;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //--------------------------------------------------------------------------
    // Task: init_weight
    //--------------------------------------------------------------------------
    task init_weight;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight (576 words)", cycle_cnt);
            for (wi = 0; wi < 576; wi = wi + 1) begin
                @(negedge clk);
                c2w_ena   = 1'b1; c2w_wea = 4'hF;
                c2w_addra = wi[9:0];
                c2w_dina  = weight_mem[wi];
            end
            @(negedge clk); c2w_ena = 1'b0; c2w_wea = 4'd0;
            $display("[TB] @ cycle %0d : init_weight done", cycle_cnt);
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: write_c1c2 (가상 Conv1 출력 씀)
    //--------------------------------------------------------------------------
    task write_c1c2;
        integer k;
        begin
            $display("[TB] @ cycle %0d : write_c1c2 (1024 entries)", cycle_cnt);
            for (k = 0; k < 1024; k = k + 1) begin
                @(negedge clk);
                c1c2_ena_a  = 1'b1;
                c1c2_wea_a  = 8'hFF;
                c1c2_addr_a = k[9:0];
                c1c2_din_a  = c1c2_data[k];
            end
            @(negedge clk); c1c2_ena_a = 1'b0; c1c2_wea_a = 8'h00;
            $display("[TB] @ cycle %0d : write_c1c2 done", cycle_cnt);
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: compare_c2pool (L=1)
    //--------------------------------------------------------------------------
    integer total_mm;
    task compare_c2pool;
        integer i;
        reg [127:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing c2pool (576 entries, L=1) vs expected ...");
            for (i = 0; i < 577; i = i + 1) begin
                @(negedge clk);
                if (i < 576) begin
                    c2pool_enb   = 1'b1;
                    c2pool_addrb = i[9:0];
                end else
                    c2pool_enb = 1'b0;
                if (i > 0) begin
                    got = c2pool_doutb;
                    exp = expected_c2pool[i-1];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ addr %0d (h=%0d w=%0d) : got=%h, exp=%h",
                                     i-1, (i-1)/24, (i-1)%24, got, exp);
                    end
                end
            end
            @(negedge clk); c2pool_enb = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main
    //--------------------------------------------------------------------------
    initial begin
        $display("[TB] === Conv2 single-image test (RTL_single) ===");
        $readmemh(`CONV1_HEX,  c1c2_data);
        $readmemh(`WEIGHT_HEX, weight_mem);
        $readmemh(`CONV2_HEX,  expected_c2pool);

        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        init_weight();
        write_c1c2();

        // start → LOAD_WEIGHTS
        @(negedge clk); start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk); start = 1'b0;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start);

        // prior_wdone → PIPELINE_FILL (weight loading 이 완료된 후 pulse)
        repeat (620) @(posedge clk);   // weight loading ~600 cycle 여유 대기
        @(negedge clk); prior_wdone = 1'b1;
        cycle_at_prior = cycle_cnt;
        @(negedge clk); prior_wdone = 1'b0;
        $display("[TB] @ cycle %0d : prior_wdone pulsed", cycle_at_prior);

        // wait wdone
        @(posedge wdone);
        cycle_at_wdone = cycle_cnt;
        $display("[TB] @ cycle %0d : wdone received", cycle_at_wdone);

        repeat (5) @(posedge clk);
        compare_c2pool();

        $display("");
        $display("================================================");
        $display("  Conv2 single-image (RTL_single) result");
        $display("================================================");
        $display("  start        @ cycle %0d", cycle_at_start);
        $display("  prior_wdone  @ cycle %0d", cycle_at_prior);
        $display("  wdone        @ cycle %0d", cycle_at_wdone);
        $display("  compute (prior_wdone→wdone) : %0d cycles",
                 cycle_at_wdone - cycle_at_prior);
        $display("  mismatches : %0d / 576", total_mm);
        if (total_mm == 0)
            $display("  *** PASS ***");
        else
            $display("  *** FAIL ***");
        $display("================================================");
        $finish;
    end

    initial begin
        #500000;
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule


//==============================================================================
// conv2_weight_bram behavioral model  (SDP, 32-bit × 1024, L=2)
//==============================================================================
module conv2_weight_bram (
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,
    input  wire [9:0]  addra,
    input  wire [31:0] dina,

    input  wire        clkb,
    input  wire        enb,
    input  wire [9:0]  addrb,
    output reg  [31:0] doutb,
    input  wire        regceb
);
    reg [31:0] mem [0:1023];
    reg [31:0] doutb_pipe;
    integer mi;
    initial begin
        for (mi = 0; mi < 1024; mi = mi + 1) mem[mi] = 32'd0;
        doutb_pipe = 32'd0; doutb = 32'd0;
    end
    always @(posedge clka) begin
        if (ena) begin
            if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
            if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
            if (wea[2]) mem[addra][23:16] <= dina[23:16];
            if (wea[3]) mem[addra][31:24] <= dina[31:24];
        end
    end
    always @(posedge clkb) begin
        if (enb)    doutb_pipe <= mem[addrb];
        if (regceb) doutb      <= doutb_pipe;
    end
endmodule
