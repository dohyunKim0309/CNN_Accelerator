`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv2_winograd_engine
// Description:
//   복소수 Winograd F(4,3) conv2 — conv2_engine 의 drop-in 대체.
//   8 IC×26×26 INT8 → 16 OC×24×24 INT8.
//   weight = PS-writable narrow BMG(wino_weight_bram 32b×8192) + loader → wide
//   wmem(32 entry×184 operand).  기존 conv2 처럼 PS 가 pre-transformed U(=G·g·Gᵀ)를
//   write.  wmem[sel] == 옛 baked ROM[sel] (bit-identical) → mul array 동작 불변.
//   (LUT-heavy 상수 ROM 을 BRAM 으로 이전 → LUT 절감, BRAM 여유분 활용.)
//
//   포트 = conv2_engine 미러 (c1c2 read / c2pool write / handshake) + weight Port A
//   (c2w_*, PS write).  cnn_accelerator 에서 conv2 자리에 instance swap, c2w_* 결선.
//
//   cycle 설계 = docs/winograd/conv2_winograd_timing.md.  leaf 모듈 전부 iverilog 검증완료.
//   producer(row load) ∥ consumer(compute) ∥ writer(c2pool), 2-set row-buffer ping-pong.
//   첫 start → LOAD_WEIGHTS(~5888 cyc loader) → 이후 image loop.
//   ★ Vivado: TB/models(dsp48e1_model/bmg_sim_models) 제외, 실 BMG IP(wino_weight_bram).
//
//   ★★ 200MHz scatter/gather 분할 (WINOGRAD_200MHZ_CLOSURE_PLAN.md §2):
//     근본원인 = per-cycle die-spanning distinct-data 버스 (a_flat 2576b scatter +
//     184-DSP product gather)가 변환 logic 과 한 cycle 에 직렬. max_fanout 복제가
//     무효한 부류(fanout-1 광폭 버스).  해법:
//     - ★2a per-lane activation register (wino_mul_array 내 a_q): [IT 3-stage →
//       lane reg] | [lane reg → 46 DSP BREG] 분할 — die 횡단 net 이 전용 cycle.
//       B-port 정렬 +4 (IT 3-stage(+2) + a_q(+1) + BREG / w_q_op4 / mul_*_q4).
//     - ★G-1 lane-local pre_q + 2+2 트리(gpab/gpcd) + C-1 gpre_q: gather 4-cycle 분할.
//     - OT 4-stage (iter6: 30 worst 중 29개가 OT → sub-stage 분할, stage당 add ≤2단).
//     - rb 분산 LUTRAM (iter6 이전 worst: write broadcast fo=312 소멸).
//     - 합계 latency-only (throughput 불변, cyc/img 1341→1348). tag 15단.
//     ※ 1차안(per-PE V 더블버퍼 + prefetch "V-stationary")은 iverilog 100/100 까지
//       갔으나 Vivado Place 30-487 (FF 87.7K / LUT 69K / control set 2272, slice 부족)
//       으로 100T 에서 면적 불가 판정 → 본 2a 안으로 전환 (plan §2 개정 참조).
//////////////////////////////////////////////////////////////////////////////////

module conv2_winograd_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,                // PS 1-cyc pulse

    // Conv2 winograd weight BMG Port A (PS write, pre-transformed U operand 1/word)
    input  wire         c2w_ena,
    input  wire [3:0]   c2w_wea,              // byte-write (AXI WSTRB[3:0])
    input  wire [12:0]  c2w_addra,            // 0..5887 (depth 8192)
    input  wire [31:0]  c2w_dina,

    output wire         c1c2_re,
    output wire [10:0]  c1c2_addr,            // {input_bank_sel, row[4:0], col[4:0]}
    input  wire [63:0]  c1c2_dout,            // 8 IC × 8b

    output wire         c2pool_we,
    output wire [10:0]  c2pool_addr,          // {output_bank_sel, pix_raster[9:0]}
    output wire [127:0] c2pool_din,           // 16 OC × 8b

    input  wire         prior_wdone,
    output wire         rdone,
    input  wire         succ_rdone,
    output wire         wdone
);
    localparam VW = 14, UW = 12, PW = 24, MW = 25, YW = 28;  // relu-range 폭 (A)

    // FSM
    localparam [2:0] IDLE=3'd0, WAIT_IMG=3'd1, LOAD_INIT=3'd2, RUN=3'd3, DRAIN=3'd4,
                     LOAD_WEIGHTS=3'd5;       // 첫 start 1회 (weight loader)
    reg [2:0] state;

    //==========================================================================
    // Handshake (conv2_fsm 미러)
    //==========================================================================
    reg  signed [2:0] prior_diff, after_diff, prior_diff_next, after_diff_next;
    reg               rdone_r, wdone_r, input_bank_sel, output_bank_sel;
    always @(*) begin
        case ({rdone_r, prior_wdone})
            2'b10: prior_diff_next = prior_diff + 3'sd1;
            2'b01: prior_diff_next = prior_diff - 3'sd1;
            default: prior_diff_next = prior_diff;
        endcase
        case ({wdone_r, succ_rdone})
            2'b10: after_diff_next = after_diff + 3'sd1;
            2'b01: after_diff_next = after_diff - 3'sd1;
            default: after_diff_next = after_diff;
        endcase
    end
    wire ready_to_compute = (prior_diff_next < 3'sd0) && (after_diff_next < 3'sd2);
    always @(posedge clk) begin
        if (rst) begin prior_diff<=0; after_diff<=0; end
        else     begin prior_diff<=prior_diff_next; after_diff<=after_diff_next; end
    end
    always @(posedge clk) if (rst) input_bank_sel<=0;  else if (rdone_r) input_bank_sel<=~input_bank_sel;
    always @(posedge clk) if (rst) output_bank_sel<=0; else if (wdone_r) output_bank_sel<=~output_bank_sel;
    assign rdone = rdone_r;
    assign wdone = wdone_r;

    // 새 image 진입 pulse (WAIT_IMG → LOAD_INIT)
    wire img_go = (state==WAIT_IMG) && ready_to_compute;

    //==========================================================================
    // Consumer counters (RUN compute issue)
    //==========================================================================
    reg [4:0] compute_cnt;   // 0..31 (=ROM sel, [0]=grp)
    // max_fanout: tile_cnt/trow_cnt 가 row buffer 36-way read mux(2304b) select 구동 → 복제
    (* max_fanout = 40 *) reg [2:0] tile_cnt;      // tx 0..5
    (* max_fanout = 40 *) reg [2:0] trow_cnt;      // ty 0..5
    reg       compute_active;
    wire last_issue = compute_active && (trow_cnt==3'd5) && (tile_cnt==3'd5) && (compute_cnt==5'd31);
    wire grp = compute_cnt[0];

    //==========================================================================
    // Producer (row load) + set_ready
    //==========================================================================
    localparam [1:0] PIDLE=2'd0, PLOAD=2'd1, PDRAIN=2'd2;
    reg [1:0] pstate;
    reg [1:0] pdrain_cnt;   // 0..2 : L=2 read drain + rb 내부 write reg(+1) landing 대기
                            //   (wino_row_buffers wr_data_q 단 추가로 2→3 cycle 연장)
    reg [2:0] pld_trow;  // 0..6
    reg [2:0] pld_row;   // 0..5
    reg [4:0] pld_col;   // 0..25
    reg [1:0] set_ready;
    wire pld_last  = (pld_row==3'd5) && (pld_col==5'd25);
    wire pld_can_start = (pld_trow<=3'd5) &&
                         ( (pld_trow==3'd0) ? (state==LOAD_INIT)
                                            : (state==RUN && ({1'b0,trow_cnt}+3'd1 >= {1'b0,pld_trow})) );
    // L=2 write pipeline
    reg       pw_v1, pw_v2, pw_set1, pw_set2;
    reg [2:0] pw_row1, pw_row2;
    reg [4:0] pw_col1, pw_col2;

    always @(posedge clk) begin
        if (rst) begin
            pstate<=PIDLE; pdrain_cnt<=0; pld_trow<=0; pld_row<=0; pld_col<=0; set_ready<=0;
            pw_v1<=0; pw_v2<=0; pw_set1<=0; pw_set2<=0; pw_row1<=0; pw_row2<=0; pw_col1<=0; pw_col2<=0;
        end else begin
            // write pipe shift (default v1=0; PLOAD 에서 1)
            pw_v2<=pw_v1; pw_set2<=pw_set1; pw_row2<=pw_row1; pw_col2<=pw_col1;
            pw_v1<=1'b0;

            if (img_go) begin
                pld_trow<=3'd0; pstate<=PIDLE; set_ready<=2'b00; pdrain_cnt<=0;
            end else begin
                case (pstate)
                    PIDLE: if (pld_can_start) begin pstate<=PLOAD; pld_row<=0; pld_col<=0; end
                    PLOAD: begin
                        pw_v1<=1'b1; pw_set1<=pld_trow[0]; pw_row1<=pld_row; pw_col1<=pld_col;
                        if (pld_last)            begin pstate<=PDRAIN; pdrain_cnt<=2'd0; end
                        else if (pld_col==5'd25) begin pld_col<=0; pld_row<=pld_row+3'd1; end
                        else                     pld_col<=pld_col+5'd1;
                    end
                    // ★ L=2 read drain + rb write reg landing: c1c2_re(enb) 유지 3 cycle →
                    //   마지막 read(row5,col25)가 doutb→wr_data_q→rb 까지 전파된 후 set_ready.
                    PDRAIN: begin
                        if (pdrain_cnt==2'd2) begin
                            pstate<=PIDLE; set_ready[pld_trow[0]]<=1'b1; pld_trow<=pld_trow+3'd1;
                        end else pdrain_cnt<=pdrain_cnt+2'd1;
                    end
                    default: pstate<=PIDLE;
                endcase
            end
        end
    end

    wire [4:0] c1c2_row = {pld_trow,2'b00} + {2'b00,pld_row};   // 4*pld_trow + pld_row (0..25)
    assign c1c2_re   = (pstate==PLOAD) || (pstate==PDRAIN);     // PDRAIN: enb 유지 (L=2 drain)
    assign c1c2_addr = {input_bank_sel, c1c2_row, pld_col};     // PDRAIN: (row5,col25) 유지

    //==========================================================================
    // row_buffers (write=producer L2, read=consumer 조합)
    //==========================================================================
    wire [6*6*64-1:0] tile6;
    wino_row_buffers u_rb (
        .clk(clk), .rst(rst),
        .wr_en(pw_v2), .wr_set(pw_set2), .wr_row(pw_row2), .wr_col(pw_col2), .wr_data(c1c2_dout),
        .rd_set(trow_cnt[0]), .rd_tx(tile_cnt), .tile6_flat(tile6)
    );

    //==========================================================================
    // ★ register 를 transform 앞(tile6_q)으로 이동. [rb_read → tile6_q] 가 자기 cycle.
    //   grp_q = ★IT-share 입력측 d-mux select.
    //   max_fanout: tile6_q→4 IT d-mux/stage1.  grp_q replica 동일 경로.
    //   ※ 2026-06-16: per-IT 분할(class B v2)은 routed regression(−0.094→−0.150,
    //     IT stage1 tre 22 EP 노출)이라 revert — journey Iter 13.
    //==========================================================================
    (* max_fanout = 8 *) reg [6*6*64-1:0] tile6_q;
    (* max_fanout = 8 *) reg grp_q;
    always @(posedge clk) begin tile6_q <= tile6; grp_q <= grp; end

    //==========================================================================
    // ★IT-share: 입력변환 4개 (8→4, grp 로 d 입력 time-share — LUT 절반).
    //   grp-mux 가 변환 "출력"(46×VW)에서 "입력"(36×8b)으로 이동: 어차피 매 cycle
    //   4 lane 분만 소비하므로 변환기 8개 중 4개는 항상 낭비였음.  값·정렬 불변:
    //   d-mux@(T+1)=grp_q → treg@(T+2) → stage2 → a_q@(T+3).
    //==========================================================================
    wire [46*VW-1:0] a_l [0:3];
    genvar ic, pp;
    generate
        for (ic=0; ic<4; ic=ic+1) begin : gic
            wire [36*8-1:0] d_flat_ic;
            for (pp=0; pp<36; pp=pp+1) begin : gp
                assign d_flat_ic[pp*8 +: 8] = grp_q ? tile6_q[pp*64 + (ic+4)*8 +: 8]
                                                    : tile6_q[pp*64 +  ic   *8 +: 8];
            end
            wino_input_transform #(.DW(8), .VW(VW)) u_it (.clk(clk), .d_flat(d_flat_ic), .a_flat(a_l[ic]));
        end
    endgenerate
    // a_l[0:3] = lane 별 입력변환 stage2 comb 출력 → 각 wino_mul_array(.a_flat) 직결.
    //   ★2a activation register(a_q)·per-PE weight RAM·lane_reduce·pre_q 는
    //   전부 wino_mul_array(=lane) 내부 (lane pblock 핸들: conv2/lane[N].u_mul).

    //==========================================================================
    // weight: PS narrow BMG(wino_weight_bram) → loader → wide wmem (ROM 대체).
    //   wmem[sel] == 옛 ROM[sel] (loader 가 동일 operand 순서로 조립) → mul array 값·
    //   타이밍 불변.  read = L=1 registered → 옛 w_flat_q 자리(a_flat_q 와 정렬).
    //==========================================================================
    wire        loader_start, loader_done;
    wire        wb_enb, wm_we;
    wire [12:0] wb_addrb;
    wire [31:0] wb_doutb;
    wire [4:0]  wm_addr;          // entry(sel) 0..31 = per-PE RAM 공통 write addr
    wire [7:0]  wm_op;            // operand 0..183  = 어느 PE RAM 에 write (enable demux)
    wire [UW-1:0] wm_data;        // narrow weight (operand 1개) — wide write broadcast 제거

    // loader_start: IDLE→LOAD_WEIGHTS 진입 1-cyc pulse (첫 start 후)
    reg loader_start_r;
    always @(posedge clk) begin
        if (rst) loader_start_r <= 1'b0;
        else     loader_start_r <= (state==IDLE) && start;
    end
    assign loader_start = loader_start_r;

    wino_weight_bram u_wbram (
        .clka(clk), .ena(c2w_ena), .wea(c2w_wea), .addra(c2w_addra), .dina(c2w_dina),
        .clkb(clk), .enb(wb_enb), .addrb(wb_addrb), .doutb(wb_doutb), .regceb(1'b1)
    );
    wino_weight_loader #(.UW(UW)) u_wload (
        .clk(clk), .rst(rst), .loader_start(loader_start), .loader_done(loader_done),
        .wb_enb(wb_enb), .wb_addrb(wb_addrb), .wb_doutb(wb_doutb),
        .wm_we(wm_we), .wm_addr(wm_addr), .wm_op(wm_op), .wm_data(wm_data)
    );

    //==========================================================================
    // ★ read-addr lane 4-copy: per-PE RAM read addr(compute_cnt) fanout 184 → ~46/lane.
    //   compute_cnt 와 매 cycle 동일값(같은 next-state lockstep) → weight read 지연 0,
    //   activation alignment 불변.  keep 으로 4개 물리 레지스터 보존(equiv-merge 방지).
    //==========================================================================
    wire [4:0] compute_cnt_nxt =
        (state==LOAD_INIT && set_ready[0])            ? 5'd0 :
        (state==RUN && compute_active && !last_issue) ?
            ((compute_cnt==5'd31) ? 5'd0 : compute_cnt + 5'd1) :
        compute_cnt;
    // max_fanout: lane copy 1개가 552 RAMD32(46op×12bit) 주소 구동 → ~9 복제로 fanout↓
    (* keep = "true", max_fanout = 64 *) reg [4:0] compute_cnt_l [0:3];
    integer lc;
    always @(posedge clk) begin
        if (rst) for (lc=0; lc<4; lc=lc+1) compute_cnt_l[lc] <= 5'd0;
        else     for (lc=0; lc<4; lc=lc+1) compute_cnt_l[lc] <= compute_cnt_nxt;
    end

    // (per-PE weight RAM·w_q_op→op2→op3 정렬은 wino_mul_array 내부 —
    //  lockstep counter 4-copy 만 여기 유지, lane 인스턴스에 1개씩 전달.)

    reg [3:0] mdrain_cnt;
    // drain window: 마지막 issue T_L 후 m latch(T_L+10)까지 array en 필요 = mul_en@(T_L+6).
    //   mdrain<8 → mul_en T_L+1..T_L+8 (마진 3).
    wire mul_en  = compute_active || (state==DRAIN && mdrain_cnt < 4'd8);
    wire mul_grp = compute_active ? grp : 1'b0;

    //==========================================================================
    // ★ 200MHz #1: DSP 입력 직전 register stage (en/grp).  activation 은
    //   [IT 3-stage(+2)] → lane a_q(+1) → BREG, weight 는 w_q_op4 가 같은 +4 정렬.
    //   issue→array(en/grp) = +4 → m_valid = issue+10.
    //==========================================================================
    // ★ mul_en_q4 = DSP CE → 184 DSP × {CEA2,CEB2,CEM,CEP} = 736 fanout (baseline pe_en/shift_en 동류).
    //   max_fanout 으로 driver 복제 → DSP cluster 근처에서 출발 (floorplan 불가한 DSP 고정열 대응).
    reg               mul_en_q, mul_en_q2, mul_en_q3, mul_grp_q, mul_grp_q2, mul_grp_q3, mul_grp_q4;
    (* max_fanout = 16 *) reg mul_en_q4;
    always @(posedge clk) begin
        if (rst) begin
            mul_en_q<=1'b0; mul_en_q2<=1'b0; mul_en_q3<=1'b0; mul_en_q4<=1'b0;
            mul_grp_q<=1'b0; mul_grp_q2<=1'b0; mul_grp_q3<=1'b0; mul_grp_q4<=1'b0;
        end else begin
            mul_en_q<=mul_en;   mul_en_q2<=mul_en_q;   mul_en_q3<=mul_en_q2;   mul_en_q4<=mul_en_q3;
            mul_grp_q<=mul_grp; mul_grp_q2<=mul_grp_q; mul_grp_q3<=mul_grp_q2; mul_grp_q4<=mul_grp_q3;
        end
    end

    //==========================================================================
    // 4 × wino_mul_array (lane = 1 IC 그룹: ★2a a_q reg + per-PE weight RAM +
    //   46 DSP + lane_reduce + ★G-1 pre_q reg).
    //==========================================================================
    wire [4*26*MW-1:0] lpre_q_flat, lpim_q_flat;
    genvar gl;
    generate for (gl = 0; gl < 4; gl = gl + 1) begin : lane
        wino_mul_array #(.LANE(gl), .UW(UW), .VW(VW), .PW(PW), .MW(MW)) u_mul (
            .clk(clk), .rst(rst), .en(mul_en_q4),
            .wm_we(wm_we), .wm_addr(wm_addr), .wm_op(wm_op), .wm_data(wm_data),
            .rd_sel(compute_cnt_l[gl]),
            .a_flat(a_l[gl]),
            .pre_q_flat(lpre_q_flat[gl*26*MW +: 26*MW]),
            .pim_q_flat(lpim_q_flat[gl*26*MW +: 26*MW])
        );
    end endgenerate

    //==========================================================================
    // cross-lane 누적 (구 mul array wrapper 에서 engine 으로 이동):
    //   ★2+2 트리: lane{0,1}/{2,3} 쌍합 → gpab/gpcd reg(신규, free-run) →
    //   최종합 → gpre_q(★C-1 reg) → grp0: acc load / grp1: msum(acc+gp) →
    //   wino_m_assemble(켤레유도) → m_re/m_im_flat + m_valid.
    //   (routed: pre_q×4 → 4-add → gpre_q 가 −1.34/219EP → 단 분할 +1.)
    //   grp/vld 정렬 = mul_*_q4(+4) 기준 +6 (DSP 3 + pre_q + gp쌍 + gpre_q)
    //   → m_valid = issue+11.  en 0→1 refill 시 vld_pipe 가 stale 마스킹.
    //==========================================================================
    reg signed [MW-1:0] gpab_re [0:25];   // lane0+lane1 (free-run, reset/CE-free)
    reg signed [MW-1:0] gpab_im [0:25];
    reg signed [MW-1:0] gpcd_re [0:25];   // lane2+lane3
    reg signed [MW-1:0] gpcd_im [0:25];
    integer xk;
    always @(posedge clk) begin
        for (xk = 0; xk < 26; xk = xk + 1) begin
            gpab_re[xk] <= $signed(lpre_q_flat[0*26*MW + xk*MW +: MW])
                         + $signed(lpre_q_flat[1*26*MW + xk*MW +: MW]);
            gpab_im[xk] <= $signed(lpim_q_flat[0*26*MW + xk*MW +: MW])
                         + $signed(lpim_q_flat[1*26*MW + xk*MW +: MW]);
            gpcd_re[xk] <= $signed(lpre_q_flat[2*26*MW + xk*MW +: MW])
                         + $signed(lpre_q_flat[3*26*MW + xk*MW +: MW]);
            gpcd_im[xk] <= $signed(lpim_q_flat[2*26*MW + xk*MW +: MW])
                         + $signed(lpim_q_flat[3*26*MW + xk*MW +: MW]);
        end
    end
    wire signed [MW-1:0] gpre [0:25];
    wire signed [MW-1:0] gpim [0:25];
    genvar gk;
    generate for (gk = 0; gk < 26; gk = gk + 1) begin : xlane
        assign gpre[gk] = gpab_re[gk] + gpcd_re[gk];
        assign gpim[gk] = gpab_im[gk] + gpcd_im[gk];
    end endgenerate

    reg signed [MW-1:0] acc_re [0:25];
    reg signed [MW-1:0] acc_im [0:25];
    reg signed [MW-1:0] gpre_q [0:25];
    reg signed [MW-1:0] gpim_q [0:25];

    wire [26*MW-1:0] msum_re_flat, msum_im_flat;
    generate for (gk = 0; gk < 26; gk = gk + 1) begin : g_msum
        assign msum_re_flat[gk*MW +: MW] = acc_re[gk] + gpre_q[gk];
        assign msum_im_flat[gk*MW +: MW] = acc_im[gk] + gpim_q[gk];
    end endgenerate

    wire [36*MW-1:0] asm_re_flat, asm_im_flat;
    wino_m_assemble #(.MW(MW)) u_asm (
        .sre_flat(msum_re_flat), .sim_flat(msum_im_flat),
        .mre_flat(asm_re_flat),  .mim_flat(asm_im_flat)
    );

    reg [5:0]        grp_pipe, vld_pipe;
    reg [36*MW-1:0]  m_re_flat, m_im_flat;
    reg              m_valid;
    integer kk;
    always @(posedge clk) begin
        if (rst) begin
            grp_pipe<=6'b0; vld_pipe<=6'b0; m_valid<=1'b0;
            m_re_flat<={36*MW{1'b0}}; m_im_flat<={36*MW{1'b0}};
            for (kk=0; kk<26; kk=kk+1) begin
                acc_re[kk]<={MW{1'b0}}; acc_im[kk]<={MW{1'b0}};
                gpre_q[kk]<={MW{1'b0}}; gpim_q[kk]<={MW{1'b0}};
            end
        end else if (mul_en_q4) begin
            grp_pipe <= {grp_pipe[4:0], mul_grp_q4};
            vld_pipe <= {vld_pipe[4:0], 1'b1};
            for (kk=0; kk<26; kk=kk+1) begin   // ★ C-1: cross-lane 합 register
                gpre_q[kk] <= gpre[kk];
                gpim_q[kk] <= gpim[kk];
            end
            if (vld_pipe[5]) begin
                if (grp_pipe[5] == 1'b0) begin
                    for (kk=0; kk<26; kk=kk+1) begin   // grp0 : 첫 4 IC partial 적재
                        acc_re[kk] <= gpre_q[kk];
                        acc_im[kk] <= gpim_q[kk];
                    end
                    m_valid <= 1'b0;
                end else begin                          // grp1 : 8-IC 완성 M latch
                    m_re_flat <= asm_re_flat;
                    m_im_flat <= asm_im_flat;
                    m_valid   <= 1'b1;
                end
            end else m_valid <= 1'b0;
        end else begin
            // en=0 (image 경계) : 파이프 clear → 다음 burst 가 stale 마스킹 후 refill
            grp_pipe<=6'b0; vld_pipe<=6'b0; m_valid<=1'b0;
        end
    end

    //==========================================================================
    // tag pipeline (oc/trow/tcol) — issue→m_valid = +11 (입력측 +4 정렬(IT3+★2a)
    //   + DSP 3 + pre_q(G-1) + gp쌍(2+2트리) + gpre_q(C-1) + m latch).
    //   출력변환 4-stage(+4), trunc +1, cwe +1 → collector 가 tg_*[15] 사용.
    //==========================================================================
    wire [3:0] issue_oc   = compute_cnt[4:1];
    reg  [3:0] tg_oc   [1:15];
    reg  [2:0] tg_trow [1:15];
    reg  [2:0] tg_tcol [1:15];
    integer ti;
    always @(posedge clk) begin
        if (rst) for (ti=1; ti<=15; ti=ti+1) begin tg_oc[ti]<=0; tg_trow[ti]<=0; tg_tcol[ti]<=0; end
        else begin
            tg_oc[1]<=issue_oc; tg_trow[1]<=trow_cnt; tg_tcol[1]<=tile_cnt;
            for (ti=2; ti<=15; ti=ti+1) begin
                tg_oc[ti]<=tg_oc[ti-1]; tg_trow[ti]<=tg_trow[ti-1]; tg_tcol[ti]<=tg_tcol[ti-1];
            end
        end
    end

    //==========================================================================
    // output transform + truncate (per-OC, 16 pixel)
    //==========================================================================
    wire [16*YW-1:0] y16_flat;
    wire             ot_valid;   // 출력변환 파이프라인(+4) 후 Y16 유효 (= m_valid+4)
    wino_output_transform #(.MW(MW), .YW(YW)) u_ot (
        .clk(clk), .in_valid(m_valid), .mre_flat(m_re_flat), .mim_flat(m_im_flat),
        .out_valid(ot_valid), .y16_flat(y16_flat)
    );
    wire [16*8-1:0] trunc_out;
    wino_truncate #(.N(16), .YW(YW), .SHIFT(14)) u_tr (
        .clk(clk), .rst(rst), .en(ot_valid), .y16_flat(y16_flat), .out_flat(trunc_out)
    );

    //==========================================================================
    // collector → tile_out[bank=tcol[0]][pixel][oc]  (trunc_out 는 ot_valid+1 = m_valid+3)
    //   cwe = ot_valid 1-cyc 지연 → 이 cycle 에 trunc_out/coc 유효, posedge 에서 tile_out 기록.
    //   coc/tag 는 tg_*[15] (issue+11 M + OT+4 → cwe cycle 에 [15] = issue context).
    //==========================================================================
    reg [7:0] tile_out [0:1][0:15][0:15];
    // ★ max_fanout: cwe/coc → tile_out 4096 FF CE/decode 산포 (routed −1.38 부류)
    (* max_fanout = 16 *) reg       cwe;
    (* max_fanout = 16 *) reg [3:0] coc;
    reg [2:0] coc_trow, coc_tcol;
    reg       tile_done;
    reg [2:0] done_trow, done_tcol;
    integer pidx;
    always @(posedge clk) begin
        if (rst) begin cwe<=0; coc<=0; coc_trow<=0; coc_tcol<=0; tile_done<=0; done_trow<=0; done_tcol<=0; end
        else begin
            cwe<=ot_valid; coc<=tg_oc[15]; coc_trow<=tg_trow[15]; coc_tcol<=tg_tcol[15];
            tile_done<=1'b0;
            if (cwe) begin
                for (pidx=0; pidx<16; pidx=pidx+1)
                    tile_out[coc_tcol[0]][pidx][coc] <= trunc_out[pidx*8 +: 8];
                if (coc==4'd15) begin tile_done<=1'b1; done_trow<=coc_trow; done_tcol<=coc_tcol; end
            end
        end
    end

    //==========================================================================
    // writer (tile_out → c2pool, 16 pixel), tile_done 트리거
    //==========================================================================
    reg        wr_active;
    reg [3:0]  wr_pix;
    reg        wr_bank;
    reg [2:0]  wr_trow, wr_tcol;
    reg        c2_we_r;
    reg [9:0]  c2_addr_r;
    reg [127:0] c2_din_r;

    wire [4:0] wr_row5 = {wr_trow,2'b00} + {3'b0, wr_pix[3:2]};   // 4*trow + pix/4 (0..23)
    wire [4:0] wr_col5 = {wr_tcol,2'b00} + {3'b0, wr_pix[1:0]};   // 4*tcol + pix%4 (0..23)
    wire [9:0] pix_addr = {1'b0,wr_row5,4'b0} + {2'b0,wr_row5,3'b0} + {5'b0,wr_col5}; // row*24+col

    integer oci;
    always @(posedge clk) begin
        if (rst) begin wr_active<=0; wr_pix<=0; c2_we_r<=0; wdone_r<=0; c2_addr_r<=0; c2_din_r<=0; wr_bank<=0; wr_trow<=0; wr_tcol<=0; end
        else begin
            c2_we_r<=1'b0; wdone_r<=1'b0;
            if (!wr_active) begin
                if (tile_done) begin
                    wr_active<=1'b1; wr_pix<=4'd0;
                    wr_bank<=done_tcol[0]; wr_trow<=done_trow; wr_tcol<=done_tcol;
                end
            end else begin
                c2_we_r  <=1'b1;
                c2_addr_r<=pix_addr;
                for (oci=0; oci<16; oci=oci+1)
                    c2_din_r[oci*8 +: 8] <= tile_out[wr_bank][wr_pix][oci];
                if (wr_pix==4'd15) begin
                    wr_active<=1'b0;
                    if (wr_trow==3'd5 && wr_tcol==3'd5) wdone_r<=1'b1;
                end else wr_pix<=wr_pix+4'd1;
            end
        end
    end
    assign c2pool_we   = c2_we_r;
    assign c2pool_addr = {output_bank_sel, c2_addr_r};
    assign c2pool_din  = c2_din_r;

    //==========================================================================
    // Main FSM + consumer counter + rdone
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; compute_cnt<=0; tile_cnt<=0; trow_cnt<=0; compute_active<=0; mdrain_cnt<=0; rdone_r<=0;
        end else begin
            rdone_r<=1'b0;
            case (state)
                IDLE:         if (start) state<=LOAD_WEIGHTS;     // 첫 start → weight load
                LOAD_WEIGHTS: if (loader_done) state<=WAIT_IMG;   // 1회, 이후 image loop
                WAIT_IMG:  if (ready_to_compute) state<=LOAD_INIT;
                LOAD_INIT: if (set_ready[0]) begin
                               state<=RUN; compute_cnt<=0; tile_cnt<=0; trow_cnt<=0; compute_active<=1'b1;
                           end
                RUN: if (compute_active) begin
                        if (last_issue) begin compute_active<=1'b0; state<=DRAIN; mdrain_cnt<=0; end
                        else if (compute_cnt==5'd31) begin
                            compute_cnt<=0;
                            if (tile_cnt==3'd5) begin tile_cnt<=0; trow_cnt<=trow_cnt+3'd1; end
                            else tile_cnt<=tile_cnt+3'd1;
                        end else compute_cnt<=compute_cnt+5'd1;
                     end
                DRAIN: begin
                        mdrain_cnt<=mdrain_cnt+4'd1;
                        if (wdone_r) state<=WAIT_IMG;
                     end
                default: state<=IDLE;
            endcase
            // rdone: 마지막 c1c2 read (ty5 load) 완료 = PDRAIN 종료(pld_trow==5)
            if (pstate==PDRAIN && pdrain_cnt==2'd2 && pld_trow==3'd5) rdone_r<=1'b1;
        end
    end

endmodule
