`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_conv2_engine
//   - conv1_out.hex  : conv1 HW output → c1c2 buffer에 packed 로드
//   - conv2_weight.mem: conv2_weight_bram behavioral model이 내부에서 로드
//   - python_conv2_ref.hex: Python 레퍼런스 (post-sim 비교)
//   - conv2_out.hex  : HW 출력 저장
//////////////////////////////////////////////////////////////////////////////////

module tb_conv2_engine;

    //==========================================================================
    // 1. Clock / Reset / Control
    //==========================================================================
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg prior_wdone = 0;
    reg succ_rdone  = 0;

    always #5 clk = ~clk;   // 10ns → 100MHz

    //==========================================================================
    // 2. DUT Instantiation
    //==========================================================================
    wire        rdone;
    wire        wdone;

    // c1c2 buffer 인터페이스 (read)
    wire         c1c2_re;
    wire [10:0]  c1c2_addr;
    wire [63:0]  c1c2_dout;

    // c2pool buffer 인터페이스 (write)
    wire         c2pool_we;
    wire [10:0]  c2pool_addr;
    wire [127:0] c2pool_din;

    conv2_engine dut (
        .clk            (clk),
        .rst            (rst),
        .start          (start),
        // weight BRAM Port A: PS write 용 (시뮬에서 미사용, 0 고정)
        .c2w_ena        (1'b0),
        .c2w_addra      (10'd0),
        .c2w_dina       (32'd0),
        // c1c2 buffer
        .c1c2_re        (c1c2_re),
        .c1c2_addr      (c1c2_addr),
        .c1c2_dout      (c1c2_dout),
        // c2pool buffer
        .c2pool_we      (c2pool_we),
        .c2pool_addr    (c2pool_addr),
        .c2pool_din     (c2pool_din),
        // handshake
        .prior_wdone    (prior_wdone),
        .rdone          (rdone),
        .succ_rdone     (succ_rdone),
        .wdone          (wdone)
    );

    //==========================================================================
    // 3. c1c2 buffer behavioral model (L=2 latency)
    //    Address: {bank_sel[0], row[4:0], col[4:0]} → 11-bit (depth 2048)
    //    Data   : 64-bit, [ic*8 +: 8] = 채널 ic 값
    //    ENA = REGCE = c1c2_re → 두 파이프라인 단 모두 c1c2_re로 게이팅
    //==========================================================================
    reg [63:0] c1c2_mem  [0:2047];
    reg [63:0] c1c2_pipe1, c1c2_pipe2;

    always @(posedge clk) begin
        if (c1c2_re) begin
            c1c2_pipe1 <= c1c2_mem[c1c2_addr];
            c1c2_pipe2 <= c1c2_pipe1;
        end
    end
    assign c1c2_dout = c1c2_pipe2;

    //==========================================================================
    // 4. c2pool buffer (write capture)
    //    Address: {bank_sel[0], write_addr[9:0]} → 11-bit
    //    Data   : 128-bit, [oc*8 +: 8] = 채널 oc 값
    //==========================================================================
    reg [127:0] c2pool_mem [0:2047];

    always @(posedge clk) begin
        if (c2pool_we)
            c2pool_mem[c2pool_addr] <= c2pool_din;
    end

    //==========================================================================
    // 5. Verification 버퍼
    //    python_ref[ch][r] : 채널 ch, 주소 r = row*24 + col
    //==========================================================================
    reg [7:0] python_ref [0:15][0:575];

    integer match_count    = 0;
    integer mismatch_count = 0;

    //==========================================================================
    // 6. conv1 출력 로드 → c1c2_mem 패킹
    //    conv1_out.hex 형식: ch0[0..675], ch1[0..675], ..., ch7[0..675]
    //    r = row*26 + col  (conv1 엔진 out_addr 기준)
    //
    //    c1c2_mem 주소: row*32 + col  (5-bit col 필드)
    //    c1c2_mem[addr][ic*8 +: 8] = conv1_flat[ic*676 + row*26 + col]
    //==========================================================================
    reg [7:0] conv1_flat [0:5407];   // 8채널 × 676픽셀

    integer ic, row, col, addr_c1c2, i;
    task load_c1c2_buffer;
        begin
            for (i = 0; i < 2048; i = i + 1)
                c1c2_mem[i] = 64'd0;

            for (row = 0; row < 26; row = row + 1) begin
                for (col = 0; col < 26; col = col + 1) begin
                    addr_c1c2 = row * 32 + col;
                    for (ic = 0; ic < 8; ic = ic + 1) begin
                        c1c2_mem[addr_c1c2][ic*8 +: 8] =
                            conv1_flat[ic * 676 + row * 26 + col];
                    end
                end
            end
        end
    endtask

    //==========================================================================
    // 7. Main
    //==========================================================================
    integer fd;
    integer ch, r;
    integer hw_val, py_val;

    initial begin
        $display("\n====== [START] Conv2 Simulation Setup & File Loading ======");

        // [7-1] conv1 출력 로드 → c1c2 buffer 패킹
        conv1_flat[0] = 8'hxx;
        $readmemh("conv1_out.hex", conv1_flat);
        if (conv1_flat[0] === 8'hxx) begin
            $display("[FILE ERROR] Failed to load 'conv1_out.hex'!");
            $finish;
        end
        $display("[FILE SUCCESS] 'conv1_out.hex' loaded.");
        load_c1c2_buffer();
        $display("[INFO] c1c2 buffer packed (26x26 x 8ch -> 64-bit words).");

        // [7-2] Python 레퍼런스 로드
        python_ref[0][0] = 8'hxx;
        $readmemh("python_conv2_ref.hex", python_ref);
        if (python_ref[0][0] === 8'hxx) begin
            $display("[FILE ERROR] Failed to load 'python_conv2_ref.hex'!");
            $finish;
        end
        $display("[FILE SUCCESS] 'python_conv2_ref.hex' loaded.");
        $display("===========================================================\n");

        // [7-3] 리셋
        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // [7-4] prior_wdone: conv1 데이터가 c1c2에 준비됐음을 알림
        @(negedge clk);
        prior_wdone = 1;
        @(negedge clk);
        prior_wdone = 0;

        // [7-5] start 펄스
        @(negedge clk);
        start = 1;
        $display("[%0t ns] >> Conv2 Engine Started.", $time);
        @(negedge clk);
        start = 0;

        // [7-6] wdone 대기
        wait (wdone == 1'b1);
        repeat(3) @(posedge clk);

        // [7-7] succ_rdone: 다음 레이어가 읽었음을 알림
        @(negedge clk);
        succ_rdone = 1;
        @(negedge clk);
        succ_rdone = 0;

        repeat(5) @(posedge clk);
        $display("[%0t ns] -> wdone detected. Running verification...", $time);

        // [7-8] c2pool_mem vs python_ref 비교
        //   c2pool bank_sel=0, write_addr=r → addr=r
        //   c2pool_mem[r][ch*8 +: 8] = 채널 ch, 픽셀 r 값
        for (ch = 0; ch < 16; ch = ch + 1) begin
            for (r = 0; r < 576; r = r + 1) begin
                hw_val = c2pool_mem[r][ch*8 +: 8];
                py_val = python_ref[ch][r];

                if (hw_val === py_val) begin
                    match_count = match_count + 1;
                end else begin
                    mismatch_count = mismatch_count + 1;
                    $display("[MISMATCH] Ch:%02d Addr:%3d(row=%0d,col=%0d) | HW:%02x != PY:%02x",
                             ch, r, r/24, r%24, hw_val, py_val);
                end
            end
        end

        // [7-9] 최종 리포트
        $display("\n==================================================");
        $display("             CONV2 H/W vs Python Report           ");
        $display("==================================================");
        $display("  - MATCH COUNT    : %0d / 9216", match_count);
        $display("  - MISMATCH COUNT : %0d / 9216", mismatch_count);
        $display("--------------------------------------------------");
        if (mismatch_count == 0 && match_count == 9216) begin
            $display("  >> [PASS] H/W results match Python 100%% perfectly!");
        end else begin
            $display("  >> [FAIL] Errors detected! Please check the waveforms.");
        end
        $display("==================================================\n");

        // [7-10] HW 출력 저장
        fd = $fopen("conv2_out.hex", "w");
        for (ch = 0; ch < 16; ch = ch + 1) begin
            for (r = 0; r < 576; r = r + 1) begin
                $fwrite(fd, "%02x\n", c2pool_mem[r][ch*8 +: 8] & 8'hFF);
            end
        end
        $fclose(fd);
        $display("=== 'conv2_out.hex' saved successfully. ===");

        #50;
        $finish;
    end

    //==========================================================================
    // 8. Watchdog Timeout (conv2는 conv1보다 복잡하므로 여유 있게)
    //==========================================================================
    initial begin
        #500000;   // 500us
        $display("[TIMEOUT ERROR] wdone not asserted within 500us.");
        $finish;
    end

endmodule
