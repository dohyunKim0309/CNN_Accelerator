`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_maxpool_engine.v  (single image — RTL_single 용)
//
//   RTL_single/maxpool/maxpool_engine.v 검증
//   ping-pong / 4-way handshake 없음
//
//   자극 순서:
//     reset → init_c2pool → prior_wdone pulse → wait done → compare
//////////////////////////////////////////////////////////////////////////////////

`define DATA_DIR      "data_single"
`define CONV2_HEX     `DATA_DIR "/conv2_output_c2pool.hex"
`define MAXPOOL_HEX   `DATA_DIR "/maxpool_output.hex"

module tb_maxpool_engine;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // DUT 포트
    wire         done;
    reg          prior_wdone = 1'b0;

    // c2pool BRAM (10-bit addr, 128-bit)
    reg          c2pool_ena_a = 1'b0;
    reg          c2pool_wea_a = 1'b0;
    reg  [9:0]   c2pool_addra = 10'd0;
    reg  [127:0] c2pool_dina  = 128'd0;

    wire [9:0]   c2pool_rd_addr;
    wire         c2pool_rd_en;
    wire [127:0] c2pool_rd_data;

    // poolfc (8-bit addr, 128-bit)
    wire [7:0]   poolfc_wr_addr;
    wire         poolfc_wr_en;
    wire [127:0] poolfc_wr_data;

    //--------------------------------------------------------------------------
    // 내장 BRAM 모델
    //--------------------------------------------------------------------------
    // c2pool BRAM (128-bit × 1024, L=1)
    reg [7:0] c2pool_mem [0:16383];

    always @(posedge clk) begin : c2pool_portA
        integer bi;
        if (c2pool_ena_a && c2pool_wea_a) begin
            for (bi = 0; bi < 16; bi = bi + 1)
                c2pool_mem[{c2pool_addra, 4'b0000} + bi] <= c2pool_dina[bi*8 +: 8];
        end
    end

    reg [127:0] c2pool_rd_r;
    always @(posedge clk) begin : c2pool_portB
        integer bi;
        if (c2pool_rd_en) begin
            for (bi = 0; bi < 16; bi = bi + 1)
                c2pool_rd_r[bi*8 +: 8] <= c2pool_mem[{c2pool_rd_addr, 4'b0000} + bi];
        end
    end
    assign c2pool_rd_data = c2pool_rd_r;

    // poolfc behavioral capture
    reg [127:0] poolfc_mem [0:511];
    always @(posedge clk) begin
        if (poolfc_wr_en)
            poolfc_mem[poolfc_wr_addr] <= poolfc_wr_data;
    end

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    maxpool_engine dut (
        .clk             (clk), .rst(rst),
        .done            (done),
        .prior_wdone     (prior_wdone),
        .c2pool_rd_addr  (c2pool_rd_addr),
        .c2pool_rd_en    (c2pool_rd_en),
        .c2pool_rd_data  (c2pool_rd_data),
        .poolfc_wr_addr  (poolfc_wr_addr),
        .poolfc_wr_en    (poolfc_wr_en),
        .poolfc_wr_data  (poolfc_wr_data)
    );

    //--------------------------------------------------------------------------
    // TB-local data
    //--------------------------------------------------------------------------
    reg [127:0] c2pool_data [0:575];
    reg [7:0]   maxpool_ref [0:2303];

    integer cycle_cnt = 0;
    integer cycle_at_prior, cycle_at_done;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //--------------------------------------------------------------------------
    // Task: init_c2pool
    //--------------------------------------------------------------------------
    task init_c2pool;
        integer i;
        begin
            $display("[TB] @ cycle %0d : init_c2pool (576 entries)", cycle_cnt);
            for (i = 0; i < 576; i = i + 1) begin
                @(negedge clk);
                c2pool_ena_a = 1'b1;
                c2pool_wea_a = 1'b1;
                c2pool_addra = i[9:0];
                c2pool_dina  = c2pool_data[i];
            end
            @(negedge clk);
            c2pool_ena_a = 1'b0; c2pool_wea_a = 1'b0;
            $display("[TB] @ cycle %0d : init_c2pool done", cycle_cnt);
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: compare_output
    //--------------------------------------------------------------------------
    integer total_mm;
    task compare_output;
        integer pixel, ch;
        reg [7:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing maxpool output (144 pixel × 16 ch = 2304 byte) ...");
            for (pixel = 0; pixel < 144; pixel = pixel + 1) begin
                for (ch = 0; ch < 16; ch = ch + 1) begin
                    got = poolfc_mem[pixel][ch*8 +: 8];
                    exp = maxpool_ref[ch*144 + pixel];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ ch=%0d pixel=%0d : got=%h, exp=%h",
                                     ch, pixel, got, exp);
                    end
                end
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Main
    //--------------------------------------------------------------------------
    initial begin
        $display("[TB] === Maxpool single-image test (RTL_single) ===");
        $readmemh(`CONV2_HEX,   c2pool_data);
        $readmemh(`MAXPOOL_HEX, maxpool_ref);
        $display("[TB] Data loaded.");

        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        init_c2pool();
        repeat (3) @(posedge clk);

        @(negedge clk); prior_wdone = 1'b1;
        cycle_at_prior = cycle_cnt;
        @(negedge clk); prior_wdone = 1'b0;
        $display("[TB] @ cycle %0d : prior_wdone pulsed", cycle_at_prior);

        @(posedge done);
        cycle_at_done = cycle_cnt;
        $display("[TB] @ cycle %0d : done received", cycle_at_done);

        repeat (5) @(posedge clk);
        compare_output();

        $display("");
        $display("================================================");
        $display("  Maxpool single-image (RTL_single) result");
        $display("================================================");
        $display("  prior_wdone  @ cycle %0d", cycle_at_prior);
        $display("  done         @ cycle %0d", cycle_at_done);
        $display("  compute      : %0d cycles", cycle_at_done - cycle_at_prior);
        $display("  mismatches   : %0d / 2304", total_mm);
        if (total_mm == 0)
            $display("  *** PASS ***");
        else
            $display("  *** FAIL ***");
        $display("================================================");
        $finish;
    end

    initial begin
        #100000;
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule
