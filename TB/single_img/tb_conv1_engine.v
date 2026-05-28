`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_conv1_engine
// - conv1_weight.mem / input_image.mem 을 $readmemh 로 로드
// - weight BRAM 모델: latency=2 (Primitive Output Register ON)
// - input  BRAM 모델: latency=1 (Primitive Output Register OFF)
// - 출력(8채널 26x26)을 conv1_out.hex 로 저장 → Python 검증에 사용
//////////////////////////////////////////////////////////////////////////////////

module tb_conv1_engine;

    //==========================================================================
    // 1. 클럭 / 리셋
    //==========================================================================
    reg clk = 0;
    reg rst_n = 0;   // active-low: 0=리셋, 1=정상동작
    reg start = 0;

    always #5 clk = ~clk;   // 10ns = 100MHz

    //==========================================================================
    // 2. DUT 포트 연결
    //==========================================================================
    wire        done;

    wire [9:0]        in_bram_addr;
    wire              in_bram_en;
    wire signed [7:0] in_bram_dout;

    wire [5:0]  w_bram_addr;
    wire        w_bram_en;
    wire [31:0] w_bram_dout;

    wire [9:0]        out_addr;
    wire              out_we;
    wire signed [7:0] out_din_ch0, out_din_ch1, out_din_ch2, out_din_ch3;
    wire signed [7:0] out_din_ch4, out_din_ch5, out_din_ch6, out_din_ch7;
    wire              out_sel_r;

    conv1_engine dut (
        .clk          (clk),          .rst_n        (rst_n),
        .start        (start),        .done         (done),
        .in_bram_addr (in_bram_addr), .in_bram_en   (in_bram_en),
        .in_bram_dout (in_bram_dout),
        .w_bram_addr  (w_bram_addr),  .w_bram_en    (w_bram_en),
        .w_bram_dout  (w_bram_dout),
        .out_addr     (out_addr),     .out_we       (out_we),
        .out_din_ch0  (out_din_ch0),  .out_din_ch1  (out_din_ch1),
        .out_din_ch2  (out_din_ch2),  .out_din_ch3  (out_din_ch3),
        .out_din_ch4  (out_din_ch4),  .out_din_ch5  (out_din_ch5),
        .out_din_ch6  (out_din_ch6),  .out_din_ch7  (out_din_ch7),
        .out_sel_r    (out_sel_r)
    );

    //==========================================================================
    // 3. BRAM 모델 — weight BRAM (latency=2)
    //==========================================================================
    reg [31:0] w_mem [0:63];
    initial $readmemh("conv1_weight.mem", w_mem);

    reg [31:0] w_pipe1, w_pipe2;
    always @(posedge clk) begin
        w_pipe1 <= w_mem[w_bram_addr];
        w_pipe2 <= w_pipe1;
    end
    assign w_bram_dout = w_pipe2;

    //==========================================================================
    // 4. BRAM 모델 — input image BRAM (latency=1)
    //==========================================================================
    reg [7:0] in_mem [0:783];
    initial $readmemh("input_image.mem", in_mem);

    reg [7:0] in_pipe;
    always @(posedge clk)
        in_pipe <= in_mem[in_bram_addr];
    assign in_bram_dout = $signed(in_pipe);

    //==========================================================================
    // 5. 출력 캡처 — [channel 0~7][pixel addr 0~675]
    //==========================================================================
    reg signed [7:0] out_buf [0:7][0:675];

    integer init_ch, init_px;
    initial begin
        for (init_ch = 0; init_ch < 8; init_ch = init_ch + 1)
            for (init_px = 0; init_px < 676; init_px = init_px + 1)
                out_buf[init_ch][init_px] = 8'sd0;
    end

    always @(posedge clk) begin
        if (out_we) begin
            if (!out_sel_r) begin   // sel=0 라운드: oc0~3
                out_buf[0][out_addr] <= out_din_ch0;
                out_buf[1][out_addr] <= out_din_ch1;
                out_buf[2][out_addr] <= out_din_ch2;
                out_buf[3][out_addr] <= out_din_ch3;
            end else begin           // sel=1 라운드: oc4~7
                out_buf[4][out_addr] <= out_din_ch4;
                out_buf[5][out_addr] <= out_din_ch5;
                out_buf[6][out_addr] <= out_din_ch6;
                out_buf[7][out_addr] <= out_din_ch7;
            end
        end
    end

    //==========================================================================
    // 6. done 시 파일 저장
    //    형식: 채널 순서대로 676개씩 → 총 8*676=5408 줄
    //==========================================================================
    integer fd, save_ch, save_px;
    always @(posedge clk) begin
        if (done) begin
            fd = $fopen("conv1_out.hex", "w");
            for (save_ch = 0; save_ch < 8; save_ch = save_ch + 1)
                for (save_px = 0; save_px < 676; save_px = save_px + 1)
                    $fwrite(fd, "%02x\n", out_buf[save_ch][save_px] & 8'hFF);
            $fclose(fd);
            $display("[TB] done at %0t ns. conv1_out.hex saved.", $time);
            #20 $finish;
        end
    end

    //==========================================================================
    // 7. 자극 시퀀스
    //==========================================================================
    initial begin
        repeat(5)  @(posedge clk);
        rst_n = 1;   // 리셋 해제
        repeat(2)  @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // 타임아웃: 가중치 로드(~40) + RUN1(784) + RUN2(784) + flush + 여유
        repeat(5000) @(posedge clk);
        $display("[TB] TIMEOUT");
        $finish;
    end

endmodule
