`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_conv1_engine.v  (single image — RTL_single 용)
//
//   RTL_single/conv1/conv1_engine.v 검증
//   ping-pong / 4-way handshake 없음 → start / done 인터페이스
//
//   BRAM: 동작 모델 내장 (Vivado BMG 불필요)
//     - bram_input_s_sim  : 8-bit × 1024 Port B read / 32-bit × 256 Port A write
//     - bram_c1c2_s_sim   : 64-bit × 1024, byte-write
//     - conv1_weight_bram : DUT 내부 인스턴스
//
//   자극 순서:
//     reset → init_input → init_weight → start → wait done → compare
//////////////////////////////////////////////////////////////////////////////////

`define DATA_DIR   "data_single"
`define INPUT_HEX  `DATA_DIR "/conv1_input.hex"
`define WEIGHT_HEX `DATA_DIR "/conv1_weights_simd.hex"
`define EXPECT_HEX `DATA_DIR "/conv1_output_c1c2.hex"

module tb_conv1_engine;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // DUT 포트
    reg        start    = 1'b0;
    wire       done;

    // bram_input Port A (TB write, 32-bit)
    reg        in_ena   = 1'b0;
    reg [3:0]  in_wea   = 4'd0;
    reg [7:0]  in_addra = 8'd0;
    reg [31:0] in_dina  = 32'd0;

    // bram_input Port B (DUT read, 8-bit)
    wire [9:0]        in_addrb;
    wire              in_enb;
    wire signed [7:0] in_doutb;

    // conv1_weight_bram Port A (TB write)
    reg        c1w_ena   = 1'b0;
    reg [3:0]  c1w_wea   = 4'd0;
    reg [5:0]  c1w_addra = 6'd0;
    reg [31:0] c1w_dina  = 32'd0;

    // bram_c1c2 Port A (DUT write)
    wire        c1c2_we;
    wire [7:0]  c1c2_wea;
    wire [9:0]  c1c2_addr;
    wire [63:0] c1c2_din;

    // bram_c1c2 Port B (TB read)
    reg         c1c2_enb   = 1'b0;
    reg  [9:0]  c1c2_addrb = 10'd0;
    wire [63:0] c1c2_doutb;

    //--------------------------------------------------------------------------
    // 내장 BRAM 모델
    //--------------------------------------------------------------------------
    // bram_input: 비대칭 (Port A 32b × 256, Port B 8b × 1024)
    reg [7:0] input_mem_arr [0:1023];

    always @(posedge clk) begin : input_bram_portA
        integer wi;
        if (in_ena && (|in_wea)) begin
            for (wi = 0; wi < 4; wi = wi + 1) begin
                if (in_wea[wi])
                    input_mem_arr[{in_addra, 2'b00} + wi] <= in_dina[wi*8 +: 8];
            end
        end
    end

    reg [7:0] in_doutb_r;
    always @(posedge clk) begin
        if (in_enb)
            in_doutb_r <= input_mem_arr[in_addrb];
    end
    assign in_doutb = $signed(in_doutb_r);

    // bram_c1c2: 64-bit × 1024, byte-write
    reg [7:0] c1c2_mem [0:8191];   // 1024 × 8 bytes

    always @(posedge clk) begin : c1c2_portA
        integer bi;
        if (c1c2_we) begin
            for (bi = 0; bi < 8; bi = bi + 1) begin
                if (c1c2_wea[bi])
                    c1c2_mem[{c1c2_addr, 3'b000} + bi] <= c1c2_din[bi*8 +: 8];
            end
        end
    end

    reg [63:0] c1c2_doutb_r;
    always @(posedge clk) begin : c1c2_portB
        integer bi;
        if (c1c2_enb) begin
            for (bi = 0; bi < 8; bi = bi + 1)
                c1c2_doutb_r[bi*8 +: 8] <= c1c2_mem[{c1c2_addrb, 3'b000} + bi];
        end
    end
    assign c1c2_doutb = c1c2_doutb_r;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    conv1_engine dut (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .done         (done),

        .in_bram_addr (in_addrb),
        .in_bram_en   (in_enb),
        .in_bram_dout (in_doutb),

        .c1w_ena      (c1w_ena),
        .c1w_wea      (c1w_wea),
        .c1w_addra    (c1w_addra),
        .c1w_dina     (c1w_dina),

        .c1c2_we      (c1c2_we),
        .c1c2_wea     (c1c2_wea),
        .c1c2_addr    (c1c2_addr),
        .c1c2_din     (c1c2_din)
    );

    //--------------------------------------------------------------------------
    // TB-local memory
    //--------------------------------------------------------------------------
    reg [7:0]  input_raw [0:783];
    reg [31:0] weight_mem [0:35];
    reg [63:0] expected   [0:1023];

    integer cycle_cnt = 0;
    integer cycle_at_start, cycle_at_done;
    always @(posedge clk) if (!rst) cycle_cnt <= cycle_cnt + 1;

    //--------------------------------------------------------------------------
    // Task: init_input
    //--------------------------------------------------------------------------
    task init_input;
        integer k;
        begin
            $display("[TB] @ cycle %0d : init_input (196 words)", cycle_cnt);
            for (k = 0; k < 196; k = k + 1) begin
                @(negedge clk);
                in_ena   = 1'b1;
                in_wea   = 4'hF;
                in_addra = k[7:0];
                in_dina  = {input_raw[k*4+3], input_raw[k*4+2],
                            input_raw[k*4+1], input_raw[k*4+0]};
            end
            @(negedge clk);
            in_ena = 1'b0; in_wea = 4'd0;
            $display("[TB] @ cycle %0d : init_input done", cycle_cnt);
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: init_weight
    //--------------------------------------------------------------------------
    task init_weight;
        integer wi;
        begin
            $display("[TB] @ cycle %0d : init_weight (36 words)", cycle_cnt);
            for (wi = 0; wi < 36; wi = wi + 1) begin
                @(negedge clk);
                c1w_ena   = 1'b1;
                c1w_wea   = 4'hF;
                c1w_addra = wi[5:0];
                c1w_dina  = weight_mem[wi];
            end
            @(negedge clk);
            c1w_ena = 1'b0; c1w_wea = 4'd0;
            $display("[TB] @ cycle %0d : init_weight done", cycle_cnt);
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: compare_c1c2
    //--------------------------------------------------------------------------
    integer total_mm;
    task compare_c1c2;
        integer i;
        reg [63:0] got, exp;
        begin
            total_mm = 0;
            $display("[TB] Comparing c1c2 (1024 entries) vs expected ...");
            for (i = 0; i < 1024 + 1; i = i + 1) begin
                @(negedge clk);
                if (i < 1024) begin
                    c1c2_enb   = 1'b1;
                    c1c2_addrb = i[9:0];
                end else
                    c1c2_enb = 1'b0;
                if (i > 0) begin
                    got = c1c2_doutb;
                    exp = expected[i-1];
                    if (got !== exp) begin
                        total_mm = total_mm + 1;
                        if (total_mm <= 10)
                            $display("  MM @ addr %0d : got=%h, exp=%h", i-1, got, exp);
                    end
                end
            end
            @(negedge clk); c1c2_enb = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main
    //--------------------------------------------------------------------------
    initial begin
        $display("[TB] === Conv1 single-image test (RTL_single) ===");
        $readmemh(`INPUT_HEX,  input_raw);
        $readmemh(`WEIGHT_HEX, weight_mem);
        $readmemh(`EXPECT_HEX, expected);
        $display("[TB] Data loaded.");

        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        $display("[TB] @ cycle %0d : reset released", cycle_cnt);

        init_input();
        init_weight();

        @(negedge clk); start = 1'b1;
        cycle_at_start = cycle_cnt;
        @(negedge clk); start = 1'b0;
        $display("[TB] @ cycle %0d : start pulsed", cycle_at_start);

        @(posedge done);
        cycle_at_done = cycle_cnt;
        $display("[TB] @ cycle %0d : done received", cycle_at_done);

        repeat (5) @(posedge clk);
        compare_c1c2();

        $display("");
        $display("================================================");
        $display("  Conv1 single-image (RTL_single) result");
        $display("================================================");
        $display("  start      @ cycle %0d", cycle_at_start);
        $display("  done       @ cycle %0d", cycle_at_done);
        $display("  compute    : %0d cycles", cycle_at_done - cycle_at_start);
        $display("  mismatches : %0d / 1024", total_mm);
        if (total_mm == 0)
            $display("  *** PASS ***");
        else
            $display("  *** FAIL ***");
        $display("================================================");
        $finish;
    end

    initial begin
        #200000;
        $display("[TB] !!! TIMEOUT @ cycle %0d !!!", cycle_cnt);
        $finish;
    end

endmodule


//==============================================================================
// conv1_weight_bram behavioral model
//   Simple Dual-Port, 32-bit × 64, L=2 (Primitive Output Register)
//==============================================================================
module conv1_weight_bram (
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,
    input  wire [5:0]  addra,
    input  wire [31:0] dina,

    input  wire        clkb,
    input  wire        enb,
    input  wire [5:0]  addrb,
    output reg  [31:0] doutb,
    input  wire        regceb
);
    reg [31:0] mem [0:63];
    reg [31:0] doutb_pipe;

    integer mi;
    initial begin
        for (mi = 0; mi < 64; mi = mi + 1) mem[mi] = 32'd0;
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
        if (enb)   doutb_pipe <= mem[addrb];
        if (regceb) doutb     <= doutb_pipe;
    end
endmodule
