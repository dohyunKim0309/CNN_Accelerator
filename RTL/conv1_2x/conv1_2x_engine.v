`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv1_2x_engine
// Description:
//   - Conv1 2× (DSP 18→36, single-round). conv1_engine 의 drop-in 대체 (포트 동일).
//
//   ★ 1-round 화 (DSP 2배):
//     conv1 = 1 IC → 8 OC, 3×3, 28×28 → 26×26. PE = DSP48E1 SIMD INT8×2 (1 PE → 2 OC).
//     현재 conv1 : 2 group × 9 PE (DEPTH=2, sel round) = 4 OC × 2 round (RUN1/RUN2).
//     conv1_2x  : 4 group × 9 PE (DEPTH=1)           = 8 OC × 1 pass  (단일 RUN).
//       → RUN2 / FLUSH2 / LBRST / sel 전부 제거. scan 을 한 번만 → ~837 cyc.
//
//   ★ 채널 매핑 (group g 의 mul0=OC(2g), mul1=OC(2g+1)):
//       group1(PE 0~8)→ch0/1(OC0/1), group2(PE 9~17)→ch2/3, group3(PE 18~26)→ch4/5,
//       group4(PE 27~35)→ch6/7. weight BRAM(conv1_weights_simd[36]) 내용은 conv1 과
//       byte-identical, loader 목적지만 word k → PE k (flat 1:1).
//
//   ★★ 200MHz fanout 리팩토링 (conv2 overclock 선례 — RTL/conv2/conv2_engine.v §5.5/§7.5):
//     DSP 18→36 으로 broadcast net 의 fanout/route span 이 커짐 → intra-clock 병목 우려.
//     conv2 와 동일하게 2단계 register-staging + max_fanout 복제로 선제 대응:
//
//     · Step1b (가중치 로드 broadcast +1 register): packed_w/load_idx(fo=36) 를 1 register
//       복제(max_fanout). weight-load 는 image 당 1회·첫 valid compute 보다 수십 cycle 앞서
//       끝나므로 +1 cycle 무해. load_en 은 PE 별 fo=1 (복제 불필요, 정렬 위해 같이 +1).
//     · Step2 (연산 broadcast pipeline, depth=PE_BC_DELAY): en/activation(x) 을 36 PE 입력
//       직전에 N register 복제(max_fanout). ★정렬 불변식: en 과 x 를 *동일* N 지연 → PE 가
//       보는 {weight, x} tuple 이 N cycle 전과 동일 → 곱셈 시퀀스 bit-exact (latency 만 +N).
//       downstream(adder/trunc en, write pipe)도 같은 delayed en 기준 → 전체 +N 균일 시프트.
//
//     ★ FSM 무변경: write 주소는 engine 내부 addr_pipe(=2+N stage) 로 전달(FSM 카운터
//       reset race 없음). drain 은 pe_en_bc(=pipe_en 지연 N) 가 자동 +N 연장 → FLUSH_LEN
//       불변(pipe_en=1@S+12 → pe_en_bc=1@S+12+N). 자세한 분석: docs/winograd/conv1_2x_design.md §8.
//
//   - 4-way handshake + internal ping-pong bank. bank_sel 은 addr_pipe 와 같은 (2+N)-stage
//     shift(bank_sel_pipe) 통과 → 마지막 write 가 새 bank 로 새는 race 봉쇄.
//   - 원본 RTL/conv1 무변경. conv1_adder_tree 는 RTL/conv1/conv1_adder_tree.v 공유.
//////////////////////////////////////////////////////////////////////////////////

module conv1_2x_engine #(
    // ★200MHz Step2: PE broadcast(en/x) 입력단 register 단수(N). conv2 PE_BC_DELAY 와 동일 철학.
    //   0 = 원래 타이밍 (Step2 off). 1,2,... = en/x 를 +N register 복제(max_fanout).
    //   결과는 N 무관 bit-exact (latency 만 +N/image). write pipe = 2+N stage 로 자동 정렬.
    parameter PE_BC_DELAY = 1
)(
    input  wire        clk,
    input  wire        rst,                  // active-high synchronous (시스템 통일)
    input  wire        start,                // legacy system init (사용 X)
    output wire        done,                 // legacy (debug)

    // 4-way handshake (conv2/maxpool 패턴, race-free) — conv1_engine 과 동일
    input  wire        prior_wdone,
    input  wire        succ_rdone,
    output wire        rdone,
    output wire        wdone,

    // 입력 BRAM (Read, Port B of bram_input, depth 2048 = 2 bank × 1024)
    output wire [10:0]       in_bram_addr,    // {input_bank_sel, in_addr[9:0]}
    output wire              in_bram_en,
    input  wire signed [7:0] in_bram_dout,

    // Conv1 weight BRAM Port A (PS write via AXI BRAM Ctrl)
    input  wire        c1w_ena,
    input  wire [3:0]  c1w_wea,             // byte-write (AXI WSTRB[3:0])
    input  wire [5:0]  c1w_addra,
    input  wire [31:0] c1w_dina,

    // c1c2 BMG Port A (Write, byte-write enable, 64-bit)
    //   ★ 1-round: 8 OC 한 번에 → wea = 8'hFF, din = {ch7..ch0}.
    output wire        c1c2_we,         // ENA
    output wire [7:0]  c1c2_wea,        // 8'hFF (full word)
    output wire [10:0] c1c2_addr,       // {bank_sel, h[4:0], w[4:0]}
    output wire [63:0] c1c2_din         // {ch7, ch6, ch5, ch4, ch3, ch2, ch1, ch0}
);

    // write pipe 깊이 = (ch_final 제거 후) 2 + Step2 broadcast 지연.
    localparam integer WR_PIPE = 2 + PE_BC_DELAY;

    //==========================================================================
    // 1. conv1_2x_fsm  (5-state, sel/lb_rst 없음. ★PE_BC_DELAY 무관 — FSM 무변경)
    //==========================================================================
    wire        load_start, load_done;
    wire        pipe_en;
    wire [4:0]  out_row, out_col;
    wire        out_valid;

    conv1_2x_fsm fsm (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .prior_wdone  (prior_wdone),
        .succ_rdone   (succ_rdone),
        .rdone        (rdone),
        .wdone        (wdone),
        .load_start   (load_start),
        .load_done    (load_done),
        .pipe_en      (pipe_en),
        .out_row      (out_row),
        .out_col      (out_col),
        .out_valid    (out_valid),
        .done         (done)
    );

    //==========================================================================
    // 1.5. Ping-pong bank toggle FF (internal, race-free) — conv1_engine 동일
    //==========================================================================
    reg input_bank_sel;
    reg bank_sel;

    always @(posedge clk) begin
        if (rst)        input_bank_sel <= 1'b0;
        else if (rdone) input_bank_sel <= ~input_bank_sel;
    end

    always @(posedge clk) begin
        if (rst)        bank_sel <= 1'b0;
        else if (wdone) bank_sel <= ~bank_sel;
    end

    //==========================================================================
    // 2. 입력 BRAM 주소 카운터 (undelayed timeline — Step2 지연 영향 없음)
    //   reset: rst / bank_change (rdone 직후) / load_start (다음 image 시작점).
    //==========================================================================
    reg [9:0] in_addr;
    reg       input_bank_sel_d;

    wire bank_change = (input_bank_sel != input_bank_sel_d);

    always @(posedge clk) begin
        if (rst) input_bank_sel_d <= 1'b0;
        else     input_bank_sel_d <= input_bank_sel;
    end

    always @(posedge clk) begin
        if (rst || bank_change || load_start)
            in_addr <= 10'd0;
        else if (pipe_en) begin
            if (in_addr == 10'd783)
                in_addr <= 10'd0;
            else
                in_addr <= in_addr + 1'b1;
        end
    end

    assign in_bram_addr = {input_bank_sel, in_addr};
    assign in_bram_en   = pipe_en;

    //==========================================================================
    // 3. weight BRAM (engine 내부 인스턴스) + conv1_2x_weight_loader (36 PE)
    //==========================================================================
    wire [24:0]  pe_packed_w;
    wire [35:0]  pe_load_en;        // 36 PE
    wire         pe_load_idx;       // DEPTH=1 → 항상 0

    wire [5:0]  w_bram_addr;
    wire        w_bram_en;
    wire [31:0] w_bram_dout;

    conv1_weight_bram c1w_bmg_inst (
        .clka  (clk),
        .ena   (c1w_ena),
        .wea   (c1w_wea),
        .addra (c1w_addra),
        .dina  (c1w_dina),

        .clkb  (clk),
        .enb   (w_bram_en),
        .addrb (w_bram_addr),
        .doutb (w_bram_dout),
        .regceb(1'b1)
    );

    conv1_2x_weight_loader #(.NUM_PE(36), .ADDR_W(6)) wloader (
        .clk         (clk),
        .rst         (rst),
        .load_start  (load_start),
        .load_done   (load_done),
        .bram_addr   (w_bram_addr),
        .bram_en     (w_bram_en),
        .bram_dout   (w_bram_dout),
        .pe_packed_w (pe_packed_w),
        .pe_load_en  (pe_load_en),
        .pe_load_idx (pe_load_idx)
    );

    //==========================================================================
    // 3.5 ★200MHz Step1b: weight-load broadcast +1 register (max_fanout 복제)
    //   packed_w/load_idx 가 36 PE(die 전역 DSP 컬럼)로 fanout → load route 분할.
    //   weight-load 는 image 당 1회, 첫 valid compute(~RUN+58cyc) 보다 수십 cycle
    //   앞서 끝나므로 +1 cycle 무해. load_en 은 PE 별 fo=1 (정렬 위해 동일 +1 지연).
    //==========================================================================
    (* max_fanout = 16 *) reg [24:0] pe_packed_w_r;   // fo=36 → 복제
    (* max_fanout = 16 *) reg        pe_load_idx_r;    // fo=36 → 복제
    reg [35:0]                       pe_load_en_r;     // 각 bit = 1 PE 전용 (저fanout)

    always @(posedge clk) begin
        if (rst) begin
            pe_packed_w_r <= 25'd0;
            pe_load_idx_r <= 1'b0;
            pe_load_en_r  <= 36'd0;
        end else begin
            pe_packed_w_r <= pe_packed_w;
            pe_load_idx_r <= pe_load_idx;
            pe_load_en_r  <= pe_load_en;
        end
    end

    //==========================================================================
    // 4. line_buffer x 2 + window_register (undelayed pipe_en, lb_rst 없음 → rst 만)
    //   ※ 입력/윈도우 측은 원래 timeline. fanout(2 lb + 1 win)은 conv1 과 동일 → 추가
    //     복제 불필요(conv2 의 8-IC shift_en 과 달리 소규모). 활성화는 §5 Step2 에서 지연.
    //==========================================================================
    wire signed [7:0] lb1_out, lb2_out;

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb1 (
        .clk(clk), .rst(rst), .en(pipe_en),
        .din(in_bram_dout), .dout(lb1_out)
    );

    line_buffer #(.WIDTH(8), .DEPTH(27)) lb2 (
        .clk(clk), .rst(rst), .en(pipe_en),
        .din(lb1_out), .dout(lb2_out)
    );

    wire signed [7:0] k0,k1,k2,k3,k4,k5,k6,k7,k8;

    window_register #(.WIDTH(8)) win (
        .clk(clk), .rst(rst), .en(pipe_en),
        .row2_in(in_bram_dout), .row1_in(lb1_out), .row0_in(lb2_out),
        .k0(k0),.k1(k1),.k2(k2),
        .k3(k3),.k4(k4),.k5(k5),
        .k6(k6),.k7(k7),.k8(k8)
    );

    wire signed [7:0] kx [0:8];
    assign kx[0]=k0; assign kx[1]=k1; assign kx[2]=k2;
    assign kx[3]=k3; assign kx[4]=k4; assign kx[5]=k5;
    assign kx[6]=k6; assign kx[7]=k7; assign kx[8]=k8;

    //==========================================================================
    // 5. ★200MHz Step2: PE 연산 broadcast(en/x) pipeline (depth = PE_BC_DELAY)
    //   en(=pipe_en) 과 activation(kx) 을 36 PE 입력 직전에 N register 복제.
    //   ★정렬 불변식: en/x 동일 N 지연 → PE {weight, x} tuple bit-exact (latency +N).
    //   window/line_buffer/카운터/c1c2 read 는 원래 timeline 유지(kx 출력만 지연).
    //==========================================================================
    wire [71:0] kx_flat;
    genvar pk;
    generate
        for (pk = 0; pk < 9; pk = pk + 1) begin : gen_kx_pack
            assign kx_flat[pk*8 +: 8] = kx[pk];
        end
    endgenerate

    wire [71:0] kx_flat_bc;     // 지연된 activation (packed)
    wire        pe_en_bc;       // 36 PE 가 보는 clock enable (= pipe_en 지연 N)

    generate
        if (PE_BC_DELAY == 0) begin : gen_bc_passthru
            assign kx_flat_bc = kx_flat;
            assign pe_en_bc   = pipe_en;
        end else begin : gen_bc_delay
            (* max_fanout = 16 *) reg pe_en_sr [1:PE_BC_DELAY];   // fo=36+ → 복제
            reg [71:0]                kx_sr    [1:PE_BC_DELAY];   // 각 8b slice fo=4 (복제 불필요)
            integer d;
            always @(posedge clk) begin
                if (rst) begin
                    for (d = 1; d <= PE_BC_DELAY; d = d + 1) begin
                        pe_en_sr[d] <= 1'b0;
                        kx_sr[d]    <= 72'd0;
                    end
                end else begin
                    pe_en_sr[1] <= pipe_en;
                    kx_sr[1]    <= kx_flat;
                    for (d = 2; d <= PE_BC_DELAY; d = d + 1) begin
                        pe_en_sr[d] <= pe_en_sr[d-1];
                        kx_sr[d]    <= kx_sr[d-1];
                    end
                end
            end
            assign pe_en_bc   = pe_en_sr[PE_BC_DELAY];
            assign kx_flat_bc = kx_sr[PE_BC_DELAY];
        end
    endgenerate

    wire signed [7:0] kx_d [0:8];   // 지연된 window (PE 입력)
    generate
        for (pk = 0; pk < 9; pk = pk + 1) begin : gen_kx_unpack
            assign kx_d[pk] = kx_flat_bc[pk*8 +: 8];
        end
    endgenerate

    //==========================================================================
    // 6. pe_cell x 36  (4 group × 9, DEPTH=1) — Step1b weight_r / Step2 en/x_d 사용
    //   DEPTH=1 → sel 무시(active_reg=w_regs[0]). sel=1'b0 tie.
    //   load_en: group1=[0..8], g2=[9..17], g3=[18..26], g4=[27..35].
    //==========================================================================
    wire signed [16:0] mul0_g1 [0:8], mul1_g1 [0:8];
    wire signed [16:0] mul0_g2 [0:8], mul1_g2 [0:8];
    wire signed [16:0] mul0_g3 [0:8], mul1_g3 [0:8];
    wire signed [16:0] mul0_g4 [0:8], mul1_g4 [0:8];

    genvar gi;
    generate
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g1
            pe_cell #(.DEPTH(1)) pe (
                .clk(clk), .rst(rst),
                .packed_w(pe_packed_w_r), .load_idx(pe_load_idx_r),
                .load_en(pe_load_en_r[gi]),
                .sel(1'b0), .en(pe_en_bc), .x(kx_d[gi]),
                .mul0(mul0_g1[gi]), .mul1(mul1_g1[gi])
            );
        end
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g2
            pe_cell #(.DEPTH(1)) pe (
                .clk(clk), .rst(rst),
                .packed_w(pe_packed_w_r), .load_idx(pe_load_idx_r),
                .load_en(pe_load_en_r[gi+9]),
                .sel(1'b0), .en(pe_en_bc), .x(kx_d[gi]),
                .mul0(mul0_g2[gi]), .mul1(mul1_g2[gi])
            );
        end
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g3
            pe_cell #(.DEPTH(1)) pe (
                .clk(clk), .rst(rst),
                .packed_w(pe_packed_w_r), .load_idx(pe_load_idx_r),
                .load_en(pe_load_en_r[gi+18]),
                .sel(1'b0), .en(pe_en_bc), .x(kx_d[gi]),
                .mul0(mul0_g3[gi]), .mul1(mul1_g3[gi])
            );
        end
        for (gi = 0; gi < 9; gi = gi + 1) begin : gen_g4
            pe_cell #(.DEPTH(1)) pe (
                .clk(clk), .rst(rst),
                .packed_w(pe_packed_w_r), .load_idx(pe_load_idx_r),
                .load_en(pe_load_en_r[gi+27]),
                .sel(1'b0), .en(pe_en_bc), .x(kx_d[gi]),
                .mul0(mul0_g4[gi]), .mul1(mul1_g4[gi])
            );
        end
    endgenerate

    //==========================================================================
    // 7. conv1_adder_tree x 4  (★ RTL/conv1/conv1_adder_tree.v 공유)
    //   en = pe_en_bc (Step2 지연된 timeline — PE 출력과 정합, drain 자동 +N 연장).
    //==========================================================================
    wire signed [23:0] sum0_g1, sum1_g1, sum0_g2, sum1_g2;
    wire signed [23:0] sum0_g3, sum1_g3, sum0_g4, sum1_g4;

    conv1_adder_tree at_g1 (
        .clk(clk), .rst(rst), .en(pe_en_bc),
        .mul0_0(mul0_g1[0]),.mul0_1(mul0_g1[1]),.mul0_2(mul0_g1[2]),
        .mul0_3(mul0_g1[3]),.mul0_4(mul0_g1[4]),.mul0_5(mul0_g1[5]),
        .mul0_6(mul0_g1[6]),.mul0_7(mul0_g1[7]),.mul0_8(mul0_g1[8]),
        .mul1_0(mul1_g1[0]),.mul1_1(mul1_g1[1]),.mul1_2(mul1_g1[2]),
        .mul1_3(mul1_g1[3]),.mul1_4(mul1_g1[4]),.mul1_5(mul1_g1[5]),
        .mul1_6(mul1_g1[6]),.mul1_7(mul1_g1[7]),.mul1_8(mul1_g1[8]),
        .sum0(sum0_g1), .sum1(sum1_g1)
    );

    conv1_adder_tree at_g2 (
        .clk(clk), .rst(rst), .en(pe_en_bc),
        .mul0_0(mul0_g2[0]),.mul0_1(mul0_g2[1]),.mul0_2(mul0_g2[2]),
        .mul0_3(mul0_g2[3]),.mul0_4(mul0_g2[4]),.mul0_5(mul0_g2[5]),
        .mul0_6(mul0_g2[6]),.mul0_7(mul0_g2[7]),.mul0_8(mul0_g2[8]),
        .mul1_0(mul1_g2[0]),.mul1_1(mul1_g2[1]),.mul1_2(mul1_g2[2]),
        .mul1_3(mul1_g2[3]),.mul1_4(mul1_g2[4]),.mul1_5(mul1_g2[5]),
        .mul1_6(mul1_g2[6]),.mul1_7(mul1_g2[7]),.mul1_8(mul1_g2[8]),
        .sum0(sum0_g2), .sum1(sum1_g2)
    );

    conv1_adder_tree at_g3 (
        .clk(clk), .rst(rst), .en(pe_en_bc),
        .mul0_0(mul0_g3[0]),.mul0_1(mul0_g3[1]),.mul0_2(mul0_g3[2]),
        .mul0_3(mul0_g3[3]),.mul0_4(mul0_g3[4]),.mul0_5(mul0_g3[5]),
        .mul0_6(mul0_g3[6]),.mul0_7(mul0_g3[7]),.mul0_8(mul0_g3[8]),
        .mul1_0(mul1_g3[0]),.mul1_1(mul1_g3[1]),.mul1_2(mul1_g3[2]),
        .mul1_3(mul1_g3[3]),.mul1_4(mul1_g3[4]),.mul1_5(mul1_g3[5]),
        .mul1_6(mul1_g3[6]),.mul1_7(mul1_g3[7]),.mul1_8(mul1_g3[8]),
        .sum0(sum0_g3), .sum1(sum1_g3)
    );

    conv1_adder_tree at_g4 (
        .clk(clk), .rst(rst), .en(pe_en_bc),
        .mul0_0(mul0_g4[0]),.mul0_1(mul0_g4[1]),.mul0_2(mul0_g4[2]),
        .mul0_3(mul0_g4[3]),.mul0_4(mul0_g4[4]),.mul0_5(mul0_g4[5]),
        .mul0_6(mul0_g4[6]),.mul0_7(mul0_g4[7]),.mul0_8(mul0_g4[8]),
        .mul1_0(mul1_g4[0]),.mul1_1(mul1_g4[1]),.mul1_2(mul1_g4[2]),
        .mul1_3(mul1_g4[3]),.mul1_4(mul1_g4[4]),.mul1_5(mul1_g4[5]),
        .mul1_6(mul1_g4[6]),.mul1_7(mul1_g4[7]),.mul1_8(mul1_g4[8]),
        .sum0(sum0_g4), .sum1(sum1_g4)
    );

    //==========================================================================
    // 8. truncate_relu (공용 모듈, N=8) — en = pe_en_bc
    //   채널 i = OC i :  ch0=sum0_g1 ... ch7=sum1_g4 (LSB=ch0).
    //==========================================================================
    wire [191:0] tr_sum_flat = {sum1_g4, sum0_g4, sum1_g3, sum0_g3,
                                sum1_g2, sum0_g2, sum1_g1, sum0_g1};
    wire [63:0]  tr_out_flat;

    truncate_relu #(.N(8)) tr (
        .clk      (clk),
        .rst      (rst),
        .en       (pe_en_bc),
        .sum_flat (tr_sum_flat),
        .out_flat (tr_out_flat)
    );

    //==========================================================================
    // 9. 제어 신호 파이프라인 (WR_PIPE = 2 + PE_BC_DELAY stage)
    //   ch_final 제거 → 기본 2 stage. Step2 가 PE 출력을 +N 늦추므로 write 도 +N →
    //   we/addr/bank 를 (2+N) stage 로 정렬. tr_out_flat 가 we_pipe[WR_PIPE-1] 과 같은
    //   cycle 에 result(V) 보유 → tr_out 직접 사용. 상세: conv1_2x_design.md §5/§8.
    //==========================================================================
    reg [WR_PIPE-1:0] we_pipe;
    reg [9:0]         addr_pipe [0:WR_PIPE-1];   // padded h*32+w
    reg [WR_PIPE-1:0] bank_sel_pipe;             // addr_pipe 와 동일 단수 → bank-race 봉쇄

    integer wp;
    always @(posedge clk) begin
        if (rst) begin
            we_pipe       <= {WR_PIPE{1'b0}};
            bank_sel_pipe <= {WR_PIPE{1'b0}};
            for (wp = 0; wp < WR_PIPE; wp = wp + 1)
                addr_pipe[wp] <= 10'd0;
        end else begin
            we_pipe       <= {we_pipe[WR_PIPE-2:0], out_valid};
            bank_sel_pipe <= {bank_sel_pipe[WR_PIPE-2:0], bank_sel};
            addr_pipe[0]  <= {out_row[4:0], out_col[4:0]};
            for (wp = 1; wp < WR_PIPE; wp = wp + 1)
                addr_pipe[wp] <= addr_pipe[wp-1];
        end
    end

    //==========================================================================
    // 10. c1c2 BMG Port A 결선 — 8 OC 64b 단일 write
    //==========================================================================
    assign c1c2_we   = we_pipe[WR_PIPE-1];
    assign c1c2_wea  = 8'hFF;                                          // full-word (8 OC 동시)
    assign c1c2_addr = {bank_sel_pipe[WR_PIPE-1], addr_pipe[WR_PIPE-1]};
    assign c1c2_din  = tr_out_flat;                                   // {ch7..ch0} = {OC7..OC0}

endmodule
