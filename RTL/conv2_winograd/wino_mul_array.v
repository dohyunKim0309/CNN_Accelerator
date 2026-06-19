`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: wino_mul_array
// Description:
//   복소수 Winograd element-wise mul array — 46 DSP, 1 lane(=1 IC 그룹) 단위.
//   conv2_winograd_engine 이 본 모듈을 **4개 인스턴스**(lane[0..3])하고,
//   cross-lane(4 IC) 누적·m_assemble 은 engine 쪽에서 수행한다.
//
//   "lane 에 local 인 모든 것"을 한 계층으로 묶음 (pblock/LOC 핸들):
//
//     a_flat (입력변환 stage2 comb) ──→ [a_q  ★2a lane activation register]
//                                           │ (B-port)
//     wm_* (loader, startup) ──→ [per-PE wmem 32×UW 분산RAM ×46 + w_q_op→op2→op3]
//                                           │ (A-port, a_q 와 +3 정렬)
//                                   [46 × wino_dsp_mul (DSP48E1 3-stage)]
//                                           │ prod
//                                   [wino_lane_reduce: 46 prod → 26 partial (Gauss)]
//                                           │
//                                   [pre_q/pim_q  ★G-1 lane-local register]
//
//   - 모든 fabric register 는 reset/CE-free(free-run) — 소비는 engine 의 vld_pipe 가
//     게이트 (control set 최소화, Place 30-487 교훈). DSP 내부만 en(CE) 사용.
//   - weight write: 전역 operand index wm_op(0..183) 비교로 자기 lane 분(LANE*46+i)만
//     수신 (startup-only narrow write).
//   - slot 역할(real/cmul Gauss)은 canonical 순서가 결정 — 하드웨어는 전부 동일
//     곱셈기 (docs/winograd/conv2_winograd_design.md §4).
//   - 물리 제어 핸들: lane 단위 pblock 은
//       add_cells_to_pblock pb_laneN [get_cells {.../conv2/lane[N].u_mul}]
//////////////////////////////////////////////////////////////////////////////////

module wino_mul_array #(
    parameter integer LANE = 0,    // 0..3 (grp0: IC=LANE, grp1: IC=LANE+4)
    parameter integer UW   = 12,   // weight operand (A-port)
    parameter integer VW   = 14,   // activation operand (B-port)
    parameter integer PW   = 24,   // DSP product
    parameter integer MW   = 25    // lane partial / M
)(
    input  wire               clk,
    input  wire               rst,        // DSP 내부 reg 용 (fabric reg 는 reset-free)
    input  wire               en,         // DSP CE (mul_en_q3 정렬)

    // weight load (startup, narrow — wino_weight_loader 직결)
    input  wire               wm_we,
    input  wire [4:0]         wm_addr,    // entry(sel) 0..31
    input  wire [7:0]         wm_op,      // 전역 operand 0..183
    input  wire [UW-1:0]      wm_data,

    // weight read addr (engine 의 lockstep 4-copy 중 자기 lane 분, issue+0 정렬)
    input  wire [4:0]         rd_sel,

    // activation: 입력변환 stage2 comb 출력 (이 lane 의 46 operand)
    input  wire [46*VW-1:0]   a_flat,

    // lane partial (Gauss reduce 후 lane-local register 출력)
    output wire [26*MW-1:0]   pre_q_flat,
    output wire [26*MW-1:0]   pim_q_flat
);

    //--------------------------------------------------------------------------
    // ★2a lane activation register: [stage2→a_q] | [a_q→46 DSP BREG] 분할.
    //--------------------------------------------------------------------------
    reg [46*VW-1:0] a_q;
    always @(posedge clk) a_q <= a_flat;

    //--------------------------------------------------------------------------
    // loader write +1 재타이밍 (lane-local): 중앙 loader → 4 lane×46 RAM 의
    //   die-spanning write 버스(WADR/I/WE)가 routed 에서 −1.40 (~1.2K EP).
    //   startup-only 지만 STA 는 모름 → lane 입구에서 1단 register.
    //   ★ keep 필수: 4 lane 이 같은 신호를 등가 register → keep 없으면 합성이
    //     1벌로 merge 해 die-spanning 버스가 부활 (routed 실측 −0.417 worst,
    //     lane[0] reg → lane[1] RAM/WE). compute_cnt_l 4-copy 와 동일 함정.
    //--------------------------------------------------------------------------
    // mf 16→4 (routed run5: lane 내 wm_op_q→RAM WE 가 route 84% −0.13 잔존 —
    //   startup-only 라 복제 비용 무관, lane 의 46 RAM 군집별 출발점 증설)
    (* keep = "true", max_fanout = 4 *) reg          wm_we_q;
    (* keep = "true", max_fanout = 4 *) reg [4:0]    wm_addr_q;
    (* keep = "true", max_fanout = 4 *) reg [7:0]    wm_op_q;
    (* keep = "true", max_fanout = 4 *) reg [UW-1:0] wm_data_q;
    always @(posedge clk) begin
        if (rst) wm_we_q <= 1'b0;
        else     wm_we_q <= wm_we;
        wm_addr_q <= wm_addr;
        wm_op_q   <= wm_op;
        wm_data_q <= wm_data;
    end

    //--------------------------------------------------------------------------
    // per-PE weight: 32×UW 분산 RAM + L=1 read + 정렬 3단 (w_q_op4 = a_q 와 동일
    //   +4 → DSP A/B 동시 capture).  write 는 wm_op 비교 demux (startup-only).
    //   ★ shreg_extract="no": op→op2→op3→op4 가 SRL16 로 합쳐지면(routed 실측
    //     w_q_op2_srl2, −1.42) 물리적 재배치 자유도가 사라짐 — FF 로 강제해
    //     placer 가 [RAM→DSP] 경로를 따라 단을 펼치게 함.
    //--------------------------------------------------------------------------
    wire [46*UW-1:0] w_q;
    genvar gi;
    generate for (gi = 0; gi < 46; gi = gi + 1) begin : g_wpe
        (* ram_style = "distributed" *)
        reg [UW-1:0] wmem_op [0:31];
        (* shreg_extract = "no" *) reg [UW-1:0] w_q_op, w_q_op2, w_q_op3, w_q_op4;
        always @(posedge clk) begin
            if (wm_we_q && (wm_op_q == LANE*46 + gi)) wmem_op[wm_addr_q] <= wm_data_q;
            w_q_op  <= wmem_op[rd_sel];
            w_q_op2 <= w_q_op;
            w_q_op3 <= w_q_op2;
            w_q_op4 <= w_q_op3;     // +1 (입력변환 3-stage 화 — a_q 와 동일 +4 정렬)
        end
        assign w_q[gi*UW +: UW] = w_q_op4;
    end endgenerate

    //--------------------------------------------------------------------------
    // 46 DSP
    //--------------------------------------------------------------------------
    wire [46*PW-1:0] pflat;
    generate for (gi = 0; gi < 46; gi = gi + 1) begin : dsp
        wire signed [PW-1:0] pw;
        wino_dsp_mul #(.AW(UW), .BW(VW), .PW(PW)) u_dsp (
            .clk (clk), .rst (rst), .en (en),
            .a   ($signed(w_q[gi*UW +: UW])),
            .b   ($signed(a_q[gi*VW +: VW])),
            .p   (pw)
        );
        assign pflat[gi*PW +: PW] = pw;
    end endgenerate

    //--------------------------------------------------------------------------
    // lane reduce (Gauss k1±k2/k3, 고정 배선) + ★G-1 lane-local register
    //--------------------------------------------------------------------------
    wire [26*MW-1:0] lpre, lpim;
    wino_lane_reduce #(.PW(PW), .MW(MW)) u_lr (
        .prod_flat (pflat),
        .pre_flat  (lpre),
        .pim_flat  (lpim)
    );

    reg [26*MW-1:0] pre_q, pim_q;
    always @(posedge clk) begin
        pre_q <= lpre;
        pim_q <= lpim;
    end
    assign pre_q_flat = pre_q;
    assign pim_q_flat = pim_q;

endmodule
