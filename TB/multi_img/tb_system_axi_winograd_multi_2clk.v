`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_system_axi_winograd_multi_2clk.v
// ★ WINOGRAD 빌드 듀얼클럭 CDC 검증 TB (보드 없이 "시스템이 돌았을 것"의 최강 증거).
//   tb_system_axi_multi_2clk.v(baseline, 3:1 300MHz)의 winograd 변형:
//     - top = cnn_accelerator (RTL/cnn_accelerator_winograd.v — baseline top 제외 필수!)
//     - conv2 weight = pre-transformed U (winograd_u.hex, 5888 word, c2w_addra 13-bit)
//     - 클럭비 2:1 : clk100 half 5.0ns / clk200 half 2.5ns, 둘 다 t=0 출발
//       → 매 5ns 엣지 동시(coincident) = 같은 MMCM 위상정렬의 CDC worst-case.
//
//   검증 목표 (단일클럭 TB 로는 못 잡는 것):
//     - start/img_ready (100→200) 2배 카운트 안 함 → image 당 정확 1회 (logit bit-exact)
//     - img_done (200→100) 손실 안 함            → img_cnt 가 image 당 정확히 +1
//     - input_consumed (200→100) 손실 안 함      → can_load backpressure 정상 (데드락 없음)
//     - weight Port A @100 write → @200 read (wino_weight_bram 포함), bram_output 200w/100r
//
//   iverilog (cwd=프로젝트 루트):
//     iverilog -g2012 -o wino2clk.vvp \
//       -y RTL/conv1_2x -y RTL/conv1 -y RTL/conv2_winograd -y RTL/maxpool -y RTL/fc \
//       -y RTL/core -y RTL/control_status_register RTL/cnn_accelerator_winograd.v \
//       TB/models/bmg_sim_models.v TB/models/dsp48e1_model.v \
//       TB/multi_img/tb_system_axi_winograd_multi_2clk.v && vvp wino2clk.vvp
//////////////////////////////////////////////////////////////////////////////////

`ifdef __ICARUS__
  `define ALL_INPUT_HEX    "data/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "data/weights_simd/conv1_weights_simd.hex"
  `define WINO_W_HEX       "data/winograd/winograd_u.hex"
  `define FCW_HEX          "data/weights_simd/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "data/multi_img/all_fc_logit.hex"
`else
  `define ALL_INPUT_HEX    "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_input.hex"
  `define CONV1_WEIGHT_HEX "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/conv1_weights_simd.hex"
  `define WINO_W_HEX       "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/winograd/winograd_u.hex"
  `define FCW_HEX          "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/fc_weights_simd.hex"
  `define FC_LOGIT_HEX     "C:/Users/gimdohyeon/CNN_Accelerator_Core/CNN_Accelerator_Core_data/image_by_image/multi_img/all_fc_logit.hex"
`endif

module tb_system_axi_winograd_multi_2clk;

    parameter N_IMAGES = 10;     // AXI sequential 이라 작게
    parameter N_WWORD  = 5888;   // pre-transformed U operand word

    // Register offsets (byte addr)
    localparam [3:0] CTRL = 4'h0, STAT = 4'h4, TLO = 4'h8, THI = 4'hC;

    //==========================================================================
    // ★ 듀얼클럭: 같은 MMCM 위상정렬(2:1) 모사
    //   clk100 half = 5.0ns, clk200 half = 2.5ns, 2×2.5 = 5.0 → 정확 2:1, 무드리프트.
    //   둘 다 0 출발 → 5ns 마다 엣지 동시(coincident) — CDC worst-case.
    //==========================================================================
    reg clk100 = 1'b0;  always #5.0 clk100 = ~clk100;   // 100MHz (CSR / AXI / Port A)
    reg clk200 = 1'b0;  always #2.5 clk200 = ~clk200;   // 200MHz (datapath)

    reg ARESETN = 1'b0;

    //==========================================================================
    // AXI4-Lite master signals (clk100 도메인)
    //==========================================================================
    reg  [3:0]  AWADDR = 4'd0;  reg AWVALID = 1'b0;  wire AWREADY;
    reg  [31:0] WDATA  = 32'd0; reg WVALID = 1'b0;   wire WREADY;  reg [3:0] WSTRB = 4'hF;
    wire [1:0]  BRESP;          wire BVALID;         reg BREADY = 1'b0;
    reg  [3:0]  ARADDR = 4'd0;  reg ARVALID = 1'b0;  wire ARREADY;
    wire [31:0] RDATA;          wire [1:0] RRESP;    wire RVALID;  reg RREADY = 1'b0;

    //==========================================================================
    // CSR ↔ PL nets (제어 pulse — 이게 CDC 를 건넘)
    //==========================================================================
    wire        enable, start, img_ready;
    wire        img_done, input_consumed;
    // Output result BRAM Port B (PS read @100) — bram_output readback
    reg         res_rd_en   = 1'b0;
    reg  [11:0] res_rd_addr = 12'd0;
    wire [31:0] res_rd_data;

    //==========================================================================
    // PS-write BMG Port A (clk100 도메인 → 가속기 BMG Port A @200 로 횡단)
    //   ★ winograd: c2w_addra 13-bit (wino_weight_bram 32b×8192, 5888 used)
    //==========================================================================
    reg         in_ena=0;   reg [3:0] in_wea=0;   reg [8:0]  in_addra=0;   reg [31:0]  in_dina=0;
    reg         c1w_ena=0;            reg [5:0]  c1w_addra=0;   reg [31:0]  c1w_dina=0;
    reg         c2w_ena=0;            reg [12:0] c2w_addra=0;   reg [31:0]  c2w_dina=0;
    reg         fcw_ena=0;            reg [9:0]  fcw_addra=0;   reg [511:0] fcw_dina=0;

    //==========================================================================
    // DUTs : CSR(@clk100) + cnn_accelerator winograd(.clk=clk200 / .aclk=clk100)
    //==========================================================================
    csr_axi_slave_lite_v1_0_csr csr (
        .enable(enable), .start(start), .img_ready(img_ready),
        .img_done(img_done), .input_consumed(input_consumed),

        .S_AXI_ACLK(clk100), .S_AXI_ARESETN(ARESETN),
        .S_AXI_AWADDR(AWADDR), .S_AXI_AWPROT(3'd0), .S_AXI_AWVALID(AWVALID), .S_AXI_AWREADY(AWREADY),
        .S_AXI_WDATA(WDATA), .S_AXI_WSTRB(WSTRB), .S_AXI_WVALID(WVALID), .S_AXI_WREADY(WREADY),
        .S_AXI_BRESP(BRESP), .S_AXI_BVALID(BVALID), .S_AXI_BREADY(BREADY),
        .S_AXI_ARADDR(ARADDR), .S_AXI_ARPROT(3'd0), .S_AXI_ARVALID(ARVALID), .S_AXI_ARREADY(ARREADY),
        .S_AXI_RDATA(RDATA), .S_AXI_RRESP(RRESP), .S_AXI_RVALID(RVALID), .S_AXI_RREADY(RREADY)
    );

    cnn_accelerator_winograd cnn (
        .clk(clk200), .aclk(clk100), .resetn(ARESETN),    // ★ 가속기만 200, CSR/AXI 측은 100
        .enable(enable), .start(start), .img_ready(img_ready),
        .img_done(img_done), .input_consumed(input_consumed),
        .in_ena(in_ena), .in_wea(in_wea), .in_addra(in_addra), .in_dina(in_dina),
        .c1w_ena(c1w_ena), .c1w_wea({4{c1w_ena}}), .c1w_addra(c1w_addra), .c1w_dina(c1w_dina),
        .c2w_ena(c2w_ena), .c2w_wea({4{c2w_ena}}), .c2w_addra(c2w_addra), .c2w_dina(c2w_dina),
        .fcw_ena(fcw_ena), .fcw_wea({64{fcw_ena}}), .fcw_addra(fcw_addra), .fcw_dina(fcw_dina),
        .res_rd_en(res_rd_en), .res_rd_addr(res_rd_addr), .res_rd_data(res_rd_data)
    );

    //==========================================================================
    // TB memory
    //==========================================================================
    reg [7:0]   input_data     [0:N_IMAGES*784-1];
    reg [31:0]  weight1_mem    [0:35];
    reg [31:0]  wino_w         [0:N_WWORD-1];
    reg [31:0]  fc_weight_simd [0:11519];
    reg signed [23:0] exp_logit [0:N_IMAGES*10-1];

    integer images_pass = 0;
    reg [31:0] rdata;

    //==========================================================================
    // AXI4-Lite write / read tasks (clk100)
    //==========================================================================
    task axi_write;
        input [3:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk100);
            AWADDR = addr; AWVALID = 1'b1;
            WDATA  = data; WVALID  = 1'b1; WSTRB = 4'hF;
            BREADY = 1'b1;
            while (!BVALID) @(negedge clk100);
            AWVALID = 1'b0; WVALID = 1'b0;
            @(negedge clk100);
            BREADY = 1'b0;
        end
    endtask

    task axi_read;
        input [3:0] addr;
        begin
            @(negedge clk100);
            ARADDR = addr; ARVALID = 1'b1; RREADY = 1'b1;
            @(posedge clk100);
            @(negedge clk100); ARVALID = 1'b0;
            @(posedge clk100);
            rdata = RDATA;
            @(negedge clk100); RREADY = 1'b0;
        end
    endtask

    //==========================================================================
    // Port A weight/input write tasks (clk100 — 가속기 Port A @200 로 횡단됨)
    //==========================================================================
    task load_w1; integer wi; begin
        for (wi=0; wi<36; wi=wi+1) begin
            @(negedge clk100); c1w_ena=1; c1w_addra=wi[5:0]; c1w_dina=weight1_mem[wi];
        end
        @(negedge clk100); c1w_ena=0;
    end endtask

    // ★ winograd: pre-transformed U 5888 word (engine 의 LOAD_WEIGHTS 가 start 후 조립)
    task load_w2; integer wi; begin
        for (wi=0; wi<N_WWORD; wi=wi+1) begin
            @(negedge clk100); c2w_ena=1; c2w_addra=wi[12:0]; c2w_dina=wino_w[wi];
        end
        @(negedge clk100); c2w_ena=0;
    end endtask

    task load_fcw;
        integer pair, s, c, line_idx;
        reg [511:0] word;
    begin
        for (pair=0; pair<5; pair=pair+1)
          for (s=0; s<144; s=s+1) begin
            word = 512'd0;
            for (c=0; c<16; c=c+1) begin
                line_idx = pair*144*16 + s*16 + c;
                word[c*32 +: 32] = fc_weight_simd[line_idx];
            end
            @(negedge clk100); fcw_ena=1; fcw_addra=pair*144+s; fcw_dina=word;
          end
        @(negedge clk100); fcw_ena=0;
    end endtask

    task write_input; input integer img; integer k; reg bank; begin
        bank = img[0];
        for (k=0; k<196; k=k+1) begin
            @(negedge clk100); in_ena=1; in_wea=4'hF; in_addra={bank,k[7:0]};
            in_dina = {input_data[img*784+k*4+3], input_data[img*784+k*4+2],
                       input_data[img*784+k*4+1], input_data[img*784+k*4+0]};
        end
        @(negedge clk100); in_ena=0; in_wea=0;
    end endtask

    function [3:0] exp_argmax; input integer base; integer j;
        reg signed [23:0] best; reg [3:0] bi; begin
        best=exp_logit[base]; bi=0;
        for (j=1;j<10;j=j+1) if (exp_logit[base+j]>best) begin best=exp_logit[base+j]; bi=j[3:0]; end
        exp_argmax=bi;
    end endfunction

    //==========================================================================
    // Main sequence
    //==========================================================================
    integer i, j, logit_mm, prev_cnt, cur_cnt;
    integer rb_word, rb_i, rb_base, rb_pass;
    reg [31:0] rb_data;
    reg [3:0]  rb_res, rb_exp;
    initial begin
        $display("\n==================================================");
        $display("  WINOGRAD DUAL-CLOCK CDC TB : CSR/AXI@100MHz <-> datapath@200MHz (2:1, N=%0d)", N_IMAGES);
        $display("==================================================");

        $readmemh(`ALL_INPUT_HEX,    input_data);
        $readmemh(`CONV1_WEIGHT_HEX, weight1_mem);
        $readmemh(`WINO_W_HEX,       wino_w);
        $readmemh(`FCW_HEX,          fc_weight_simd);
        $readmemh(`FC_LOGIT_HEX,     exp_logit);

        // Reset (clk100 기준 충분히 길게 — clk200 도메인 reset 재동기화 여유)
        ARESETN = 1'b0;
        repeat (10) @(posedge clk100);
        @(negedge clk100); ARESETN = 1'b1;
        repeat (4) @(posedge clk100);

        // PS: weight 적재 (Port A, 100→200 횡단). winograd U 는 start 후 engine loader 가 조립.
        load_w1(); load_w2(); load_fcw();
        $display("[TB] weights loaded (Port A @100 -> BMG @200, wino U %0d words)", N_WWORD);

        // PS: enable=1, start pulse (CTRL write) — 100→200 pulse CDC
        axi_write(CTRL, 32'h1);          // enable=1
        axi_write(CTRL, 32'h3);          // enable + start(pulse) → LOAD_WEIGHTS + timer
        $display("[TB] CTRL: enable=1, start pulsed (engine LOAD_WEIGHTS ~%0d cyc @200)", N_WWORD);

        prev_cnt = 0;
        for (i = 0; i < N_IMAGES; i = i + 1) begin
            // backpressure: STATUS.can_load(bit1) — input_consumed(200->100) 가 살아야 풀림
            rdata = 0;
            while (!rdata[1]) axi_read(STAT);

            write_input(i);
            axi_write(CTRL, 32'h5);      // enable + img_ready(pulse, bit2) — 100->200 pulse CDC

            // img_cnt(STATUS[15:2]) +1 polling — img_done(200->100) 가 살아야 진행
            cur_cnt = prev_cnt;
            while (cur_cnt == prev_cnt) begin
                axi_read(STAT);
                cur_cnt = rdata[15:2];
            end
            // ★ image 당 정확히 +1 인지(2배 카운트/손실 없음) 확인
            if (cur_cnt != prev_cnt + 1)
                $display("[TB] ★ img %3d : img_cnt JUMP %0d -> %0d (expected +1) — CDC 카운트 오류!", i, prev_cnt, cur_cnt);
            prev_cnt = cur_cnt;

            // logit bit-exact (datapath 200 도메인이 image 당 1회만 처리했는지 검증)
            logit_mm = 0;
            for (j = 0; j < 10; j = j + 1)
                if (cnn.fc.logit_reg[j][23:0] !== exp_logit[i*10 + j]) logit_mm = logit_mm + 1;

            if (logit_mm == 0) begin
                images_pass = images_pass + 1;
                $display("[TB] img %3d : logit PASS  img_cnt=%0d", i, cur_cnt);
            end else begin
                $display("[TB] img %3d : logit FAIL  logit_mm=%0d  img_cnt=%0d", i, logit_mm, cur_cnt);
            end
        end

        // ---- bram_output readback (clka=200 write / clkb=100 read) ----
        rb_pass = 0;
        for (rb_word = 0; rb_word < (N_IMAGES + 3) / 4; rb_word = rb_word + 1) begin
            @(negedge clk100); res_rd_en = 1'b1; res_rd_addr = rb_word[11:0];
            @(posedge clk100);
            @(negedge clk100); rb_data = res_rd_data;
            for (rb_i = 0; rb_i < 4; rb_i = rb_i + 1) begin
                rb_base = rb_word*4 + rb_i;
                if (rb_base < N_IMAGES) begin
                    rb_res = rb_data[rb_i*8 +: 4];
                    rb_exp = exp_argmax(rb_base*10);
                    if (rb_res === rb_exp) rb_pass = rb_pass + 1;
                    else $display("[TB] readback img %0d : FAIL  bram=%0d exp=%0d", rb_base, rb_res, rb_exp);
                end
            end
        end
        @(negedge clk100); res_rd_en = 1'b0;

        // timer read (100MHz cycle 수)
        axi_read(TLO);
        $display("[TB] timer_lo = %0d (100MHz cycles)", rdata);

        $display("\n==================================================");
        $display("  WINOGRAD DUAL-CLOCK CDC : images PASS(logit) = %0d / %0d", images_pass, N_IMAGES);
        $display("  bram_output readback                        = %0d / %0d", rb_pass, N_IMAGES);
        if (images_pass == N_IMAGES && rb_pass == N_IMAGES && prev_cnt == N_IMAGES)
            $display("  *** PASS *** (100<->200 CDC: 2배카운트/펄스손실/데드락 없음, logit bit-exact)");
        else
            $display("  *** FAIL ***  (img_cnt=%0d)", prev_cnt);
        $display("==================================================");
        $finish;
    end

    initial begin
        #20000000;
        $display("\n[TB] !!! TIMEOUT !!! (images_pass=%0d/%0d, img_cnt=%0d) — CDC 데드락 의심", images_pass, N_IMAGES, prev_cnt);
        $finish;
    end

endmodule
