`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: wino_mul_array
// Description:
//   복소수 Winograd element-wise mul array — 184 DSP (4 lane × 46), 한 (OC,tile) 의
//   M = Σ_IC U⊙V 를 2-cycle(4 IC + 4 IC) 로 계산. drop-in 핵심 compute.
//
//   lane L (= IC) : 46 DSP. operand i 의 weight=w_flat[(L*46+i)], act=a_flat[(L*46+i)].
//     real pos(0..15): prod 그대로. cmul pos(16..): Gauss(k1,k2,k3) → wino_lane_reduce.
//   cross-lane: 4 lane partial 합 = 한 group(4 IC) partial.
//   accumulate: grp0 cycle load → grp1 cycle add (= 8 IC) → wino_m_assemble(켤레유도)
//               → full 6×6 M (m_re_flat/m_im_flat) + m_valid.
//
//   파이프라인 (en 연속 가정, image 경계서 en=0 → 자동 refill):
//     issue T : w/a/grp_in 제시 (DSP CE=en)
//     T+3     : prod valid → lane_reduce → cross-lane → gpre/gpim (조합)
//               grp_pipe[2]/vld_pipe[2] 가 issue@T 의 grp/valid 와 정렬
//               grp0 → acc<=gp ;  grp1 → M<=assemble(acc+gp), m_valid<=1
//     ⇒ (OC,tile) 하나당 m_valid 1회 (grp1 stage3). 연속 issue 시 2-cycle 간격.
//
//   ★ en 이 0→1 (새 image burst) 시 vld_pipe/grp_pipe 를 0 으로 두어, DSP 파이프의
//     직전 image 잔여(stale) 3-cycle 을 invalid 로 마스킹 (accumulator 무시) 후 refill.
//   ★ Vivado: dsp48e1_model.v 제외 (실제 DSP48E1). wino_lane_reduce/m_assemble 는 자동생성.
//////////////////////////////////////////////////////////////////////////////////

module wino_mul_array #(
    parameter integer UW = 14,    // weight operand (A-port)
    parameter integer VW = 16,    // activation operand (B-port)
    parameter integer PW = 32,    // DSP product
    parameter integer MW = 32     // M accumulator
)(
    input  wire                clk,
    input  wire                rst,        // active-high synchronous
    input  wire                en,         // compute burst active (DSP CE)
    input  wire                grp_in,     // 0/1 : 이번 cycle issue 하는 IC-group

    input  wire [4*46*UW-1:0]  w_flat,     // lane L op i = [(L*46+i)*UW +: UW] (signed)
    input  wire [4*46*VW-1:0]  a_flat,     // lane L op i = [(L*46+i)*VW +: VW] (signed)

    output reg  [36*MW-1:0]    m_re_flat,  // M[p][q] = [(p*6+q)*MW +: MW] (signed)
    output reg  [36*MW-1:0]    m_im_flat,
    output reg                 m_valid     // M(한 OC,tile) 완성 pulse
);

    //==========================================================================
    // 1. 184 DSP (4 lane × 46) + lane_reduce
    //==========================================================================
    wire signed [MW-1:0] gpre [0:25];   // cross-lane(4 IC) partial re
    wire signed [MW-1:0] gpim [0:25];   //                          im

    genvar L, i, k;
    generate
        for (L = 0; L < 4; L = L + 1) begin : lane
            wire [46*PW-1:0] pflat;
            for (i = 0; i < 46; i = i + 1) begin : dsp
                wire signed [PW-1:0] pw;
                wino_dsp_mul #(.AW(UW), .BW(VW), .PW(PW)) u_dsp (
                    .clk (clk), .rst (rst), .en (en),
                    .a   ($signed(w_flat[(L*46+i)*UW +: UW])),
                    .b   ($signed(a_flat[(L*46+i)*VW +: VW])),
                    .p   (pw)
                );
                assign pflat[i*PW +: PW] = pw;
            end
            wire [26*MW-1:0] lpre, lpim;
            wino_lane_reduce #(.PW(PW), .MW(MW)) u_lr (
                .prod_flat (pflat),
                .pre_flat  (lpre),
                .pim_flat  (lpim)
            );
        end
    endgenerate

    //==========================================================================
    // 2. cross-lane 합 (4 IC) — 조합
    //==========================================================================
    generate
        for (k = 0; k < 26; k = k + 1) begin : xlane
            assign gpre[k] = $signed(lane[0].lpre[k*MW +: MW])
                           + $signed(lane[1].lpre[k*MW +: MW])
                           + $signed(lane[2].lpre[k*MW +: MW])
                           + $signed(lane[3].lpre[k*MW +: MW]);
            assign gpim[k] = $signed(lane[0].lpim[k*MW +: MW])
                           + $signed(lane[1].lpim[k*MW +: MW])
                           + $signed(lane[2].lpim[k*MW +: MW])
                           + $signed(lane[3].lpim[k*MW +: MW]);
        end
    endgenerate

    //==========================================================================
    // 3. IC accumulator (grp0 load / grp1 add) + 켤레유도 (wino_m_assemble)
    //==========================================================================
    reg signed [MW-1:0] acc_re [0:25];
    reg signed [MW-1:0] acc_im [0:25];
    // ★ C-1: cross-lane 합을 register(gp_reg) → reduce chain(prod→lane_reduce→cross-lane→
    //   msum→m_assemble ~14단)을 분할 (+1 latency).  msum/acc 는 gp_reg 사용.
    reg signed [MW-1:0] gpre_q [0:25];
    reg signed [MW-1:0] gpim_q [0:25];

    // msum = acc + gp_reg  (grp1 cycle 에 8-IC 합 = 완성 M)
    wire [26*MW-1:0] msum_re_flat;
    wire [26*MW-1:0] msum_im_flat;
    generate
        for (k = 0; k < 26; k = k + 1) begin : msum
            assign msum_re_flat[k*MW +: MW] = acc_re[k] + gpre_q[k];
            assign msum_im_flat[k*MW +: MW] = acc_im[k] + gpim_q[k];
        end
    endgenerate

    wire [36*MW-1:0] asm_re_flat;
    wire [36*MW-1:0] asm_im_flat;
    wino_m_assemble #(.MW(MW)) u_asm (
        .sre_flat (msum_re_flat),
        .sim_flat (msum_im_flat),
        .mre_flat (asm_re_flat),
        .mim_flat (asm_im_flat)
    );

    // grp/valid 를 (DSP 3 + cross-lane reg 1 = 4) 만큼 지연 → stage4 정렬 (C-1)
    reg [3:0] grp_pipe;
    reg [3:0] vld_pipe;

    integer kk;
    always @(posedge clk) begin
        if (rst) begin
            grp_pipe  <= 4'b0;
            vld_pipe  <= 4'b0;
            m_valid   <= 1'b0;
            m_re_flat <= {36*MW{1'b0}};
            m_im_flat <= {36*MW{1'b0}};
            for (kk = 0; kk < 26; kk = kk + 1) begin
                acc_re[kk] <= {MW{1'b0}};
                acc_im[kk] <= {MW{1'b0}};
                gpre_q[kk] <= {MW{1'b0}};
                gpim_q[kk] <= {MW{1'b0}};
            end
        end else if (en) begin
            grp_pipe <= {grp_pipe[2:0], grp_in};
            vld_pipe <= {vld_pipe[2:0], 1'b1};
            for (kk = 0; kk < 26; kk = kk + 1) begin   // ★ C-1: cross-lane 합 register
                gpre_q[kk] <= gpre[kk];
                gpim_q[kk] <= gpim[kk];
            end

            if (vld_pipe[3]) begin
                if (grp_pipe[3] == 1'b0) begin
                    // grp0 : 첫 4 IC partial 적재 (registered gp)
                    for (kk = 0; kk < 26; kk = kk + 1) begin
                        acc_re[kk] <= gpre_q[kk];
                        acc_im[kk] <= gpim_q[kk];
                    end
                    m_valid <= 1'b0;
                end else begin
                    // grp1 : 나머지 4 IC 합산 → 완성 M latch
                    m_re_flat <= asm_re_flat;
                    m_im_flat <= asm_im_flat;
                    m_valid   <= 1'b1;
                end
            end else begin
                m_valid <= 1'b0;
            end
        end else begin
            // en=0 (image 경계 등) : 파이프 clear → 다음 burst 가 stale DSP 잔여 마스킹 후 refill
            grp_pipe <= 4'b0;
            vld_pipe <= 4'b0;
            m_valid  <= 1'b0;
        end
    end

endmodule
