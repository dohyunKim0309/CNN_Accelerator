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
    reg [2:0] tile_cnt;      // tx 0..5
    reg [2:0] trow_cnt;      // ty 0..5
    reg       compute_active;
    wire last_issue = compute_active && (trow_cnt==3'd5) && (tile_cnt==3'd5) && (compute_cnt==5'd31);
    wire grp = compute_cnt[0];

    //==========================================================================
    // Producer (row load) + set_ready
    //==========================================================================
    localparam [1:0] PIDLE=2'd0, PLOAD=2'd1, PDRAIN=2'd2;
    reg [1:0] pstate;
    reg       pdrain_cnt;   // 0,1 : L=2 read drain (enb 유지하여 마지막 read 전파)
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
                        if (pld_last)            begin pstate<=PDRAIN; pdrain_cnt<=1'b0; end
                        else if (pld_col==5'd25) begin pld_col<=0; pld_row<=pld_row+3'd1; end
                        else                     pld_col<=pld_col+5'd1;
                    end
                    // ★ L=2 read drain: c1c2_re(enb) 유지 2 cycle → 마지막 read(row5,col25)가
                    //   doutb 까지 전파 (안 그러면 마지막 cell stale → tx=5 pixel(3,3) 오류).
                    PDRAIN: begin
                        if (pdrain_cnt==1'b1) begin
                            pstate<=PIDLE; set_ready[pld_trow[0]]<=1'b1; pld_trow<=pld_trow+3'd1;
                        end else pdrain_cnt<=1'b1;
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
    // 8 input transforms + grp mux → a_flat (4 lane × 46)
    //==========================================================================
    wire [46*VW-1:0] a_ic [0:7];
    genvar ic, pp;
    generate
        for (ic=0; ic<8; ic=ic+1) begin : gic
            wire [36*8-1:0] d_flat_ic;
            for (pp=0; pp<36; pp=pp+1) begin : gp
                assign d_flat_ic[pp*8 +: 8] = tile6[pp*64 + ic*8 +: 8];
            end
            wino_input_transform #(.DW(8), .VW(VW)) u_it (.d_flat(d_flat_ic), .a_flat(a_ic[ic]));
        end
    endgenerate
    wire [4*46*VW-1:0] a_flat;
    generate
        for (pp=0; pp<4; pp=pp+1) begin : glane
            assign a_flat[pp*46*VW +: 46*VW] = grp ? a_ic[4+pp] : a_ic[pp];
        end
    endgenerate

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
    (* keep = "true" *) reg [4:0] compute_cnt_l [0:3];
    integer lc;
    always @(posedge clk) begin
        if (rst) for (lc=0; lc<4; lc=lc+1) compute_cnt_l[lc] <= 5'd0;
        else     for (lc=0; lc<4; lc=lc+1) compute_cnt_l[lc] <= compute_cnt_nxt;
    end

    //==========================================================================
    // ★ per-PE local weight memory: operand(=DSP)별 32×12 distributed RAM 184개.
    //   기존 "32 entry × 2208-bit 단일 배열" 을 operand 축으로 물리 분할 →
    //   각 작은 RAM 이 자기 DSP 근처(SLICEM, DSP column 옆)에 배치되어
    //   read 가 구조적으로 local (2208-bit 단일 broadcast 버스 소멸 — 이게 congestion 원인).
    //   die 전체로 도는 신호는 compute_cnt(5-bit read addr)뿐.
    //   write = loader 가 operand 1개씩 narrow(12-bit), wm_op 로 해당 RAM 만 enable
    //           (startup-only, broadcast 도 12-bit 로 축소).
    //   불변성: wmem_op[gop][sel] == 옛 wmem[sel][gop*UW +: UW] == 옛 ROM[sel] →
    //           mul array 가 보는 weight 값·L=1 타이밍 모두 동일 → 동작 bit-exact 보존.
    //==========================================================================
    wire [4*46*UW-1:0] w_q;      // per-PE 출력 concat (= 옛 w_flat_q 와 동일 레이아웃)
    genvar gop;
    generate for (gop = 0; gop < 4*46; gop = gop+1) begin : g_wpe
        (* ram_style = "distributed" *)
        reg [UW-1:0] wmem_op [0:31];
        reg [UW-1:0] w_q_op;
        always @(posedge clk) begin
            if (wm_we && (wm_op == gop[7:0])) wmem_op[wm_addr] <= wm_data;     // local write
            w_q_op <= wmem_op[compute_cnt_l[gop/46]];                         // local read (L=1, lane copy)
        end
        assign w_q[gop*UW +: UW] = w_q_op;
    end endgenerate

    reg [2:0] mdrain_cnt;
    wire mul_en  = compute_active || (state==DRAIN && mdrain_cnt < 3'd6);  // +1 (issue register stage)
    wire mul_grp = compute_active ? grp : 1'b0;

    //==========================================================================
    // ★ 200MHz #1: DSP 입력 직전 1-cyc register stage.
    //   최장 조합경로 = rb 36-way comb read → 8× input_transform(adder) → grp-mux → DSP B-port.
    //   activation/en/grp 를 register 로 끊는다. weight 는 wmem L=1 read 가 같은 +1 정렬을
    //   제공(DSP A-port). ⇒ mul array 내부 타이밍 불변, 전체 issue→M 가 +1 cyc 시프트.
    //     보정: tag pipeline 4→5, DRAIN mul_en window +1. collector/writer/wdone 는 m_valid
    //     를 따라가므로 자동 +1 (per-image latency +1 cyc, throughput 불변).
    //==========================================================================
    reg [4*46*VW-1:0] a_flat_q;
    reg               mul_en_q, mul_grp_q;
    always @(posedge clk) begin
        if (rst) begin a_flat_q<={4*46*VW{1'b0}}; mul_en_q<=1'b0; mul_grp_q<=1'b0; end
        else     begin a_flat_q<=a_flat; mul_en_q<=mul_en; mul_grp_q<=mul_grp; end
    end

    wire [36*MW-1:0] m_re_flat, m_im_flat;
    wire             m_valid;
    wino_mul_array #(.UW(UW), .VW(VW), .PW(PW), .MW(MW)) u_mul (
        .clk(clk), .rst(rst), .en(mul_en_q), .grp_in(mul_grp_q),
        .w_flat(w_q), .a_flat(a_flat_q),
        .m_re_flat(m_re_flat), .m_im_flat(m_im_flat), .m_valid(m_valid)
    );

    //==========================================================================
    // tag pipeline (oc/trow/tcol) — issue register stage(+1) 포함 → m_valid 5-cyc 정렬
    //   m_valid = (등록된 grp1 issue)+4 = (compute context)+1+4 = +5. 따라서 tag delay 4→5.
    //==========================================================================
    wire [3:0] issue_oc   = compute_cnt[4:1];
    reg  [3:0] tg_oc   [1:5];
    reg  [2:0] tg_trow [1:5];
    reg  [2:0] tg_tcol [1:5];
    integer ti;
    always @(posedge clk) begin
        if (rst) for (ti=1; ti<=5; ti=ti+1) begin tg_oc[ti]<=0; tg_trow[ti]<=0; tg_tcol[ti]<=0; end
        else begin
            tg_oc[1]<=issue_oc; tg_trow[1]<=trow_cnt; tg_tcol[1]<=tile_cnt;
            for (ti=2; ti<=5; ti=ti+1) begin
                tg_oc[ti]<=tg_oc[ti-1]; tg_trow[ti]<=tg_trow[ti-1]; tg_tcol[ti]<=tg_tcol[ti-1];
            end
        end
    end

    //==========================================================================
    // output transform + truncate (per-OC, 16 pixel)
    //==========================================================================
    wire [16*YW-1:0] y16_flat;
    wino_output_transform #(.MW(MW), .YW(YW)) u_ot (.mre_flat(m_re_flat), .mim_flat(m_im_flat), .y16_flat(y16_flat));
    wire [16*8-1:0] trunc_out;
    wino_truncate #(.N(16), .YW(YW), .SHIFT(14)) u_tr (
        .clk(clk), .rst(rst), .en(m_valid), .y16_flat(y16_flat), .out_flat(trunc_out)
    );

    //==========================================================================
    // collector → tile_out[bank=tcol[0]][pixel][oc]  (trunc_out 는 m_valid+1)
    //   cwe = m_valid 1-cyc 지연 → 이 cycle 에 trunc_out/coc 유효, posedge 에서 tile_out 기록.
    //==========================================================================
    reg [7:0] tile_out [0:1][0:15][0:15];
    reg       cwe;
    reg [3:0] coc;
    reg [2:0] coc_trow, coc_tcol;
    reg       tile_done;
    reg [2:0] done_trow, done_tcol;
    integer pidx;
    always @(posedge clk) begin
        if (rst) begin cwe<=0; coc<=0; coc_trow<=0; coc_tcol<=0; tile_done<=0; done_trow<=0; done_tcol<=0; end
        else begin
            cwe<=m_valid; coc<=tg_oc[5]; coc_trow<=tg_trow[5]; coc_tcol<=tg_tcol[5];
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
                        mdrain_cnt<=mdrain_cnt+3'd1;
                        if (wdone_r) state<=WAIT_IMG;
                     end
                default: state<=IDLE;
            endcase
            // rdone: 마지막 c1c2 read (ty5 load) 완료 = PDRAIN 종료(pld_trow==5)
            if (pstate==PDRAIN && pdrain_cnt==1'b1 && pld_trow==3'd5) rdone_r<=1'b1;
        end
    end

endmodule
