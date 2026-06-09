`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// wino_input_transform.v  (자동생성: scripts/weights/winograd_gen.py)
//   복소수 Winograd F(4,3) 입력변환  V = Bᵀ·d·B  (per IC, 곱셈기 0개)
//   d(6×6 INT8) → 46 activation operand (B-port feed), canonical 순서:
//     [16 real pos: V_re] + [10 cmul pos: (V_re+V_im), V_re, V_im]
//   ★ 2-stage PIPELINE: stage1 t=Bᵀ·d → reg → stage2 V=t·B+assembly. a_flat=d_flat+1.
//   계수 {0,±1,±4} add/shift/neg only.
////////////////////////////////////////////////////////////////////////////////
module wino_input_transform #(parameter DW=8, VW=14) (
    input  wire             clk,
    input  wire [36*DW-1:0] d_flat,   // d[k][l] = d_flat[(k*6+l)*DW +: DW] (signed)
    output wire [46*VW-1:0] a_flat    // operand i = a_flat[i*VW +: VW] (signed, +1 cyc)
);
    wire signed [10:0] d [0:5][0:5];
    genvar gk, gl;
    generate for (gk=0; gk<6; gk=gk+1) for (gl=0; gl<6; gl=gl+1)
        assign d[gk][gl] = $signed(d_flat[(gk*6+gl)*DW +: DW]);
    endgenerate

    // stage1 (comb): t = Bᵀ·d   t[p][l] = Σ_k Bᵀ[p,k]·d[k][l]
    wire signed [10:0] tre_c [0:5][0:5];
    wire signed [10:0] tim_c [0:5][0:5];
    assign tre_c[0][0] = (d[0][0] <<< 2) - (d[4][0] <<< 2);
    assign tim_c[0][0] = 11'sd0;
    assign tre_c[0][1] = (d[0][1] <<< 2) - (d[4][1] <<< 2);
    assign tim_c[0][1] = 11'sd0;
    assign tre_c[0][2] = (d[0][2] <<< 2) - (d[4][2] <<< 2);
    assign tim_c[0][2] = 11'sd0;
    assign tre_c[0][3] = (d[0][3] <<< 2) - (d[4][3] <<< 2);
    assign tim_c[0][3] = 11'sd0;
    assign tre_c[0][4] = (d[0][4] <<< 2) - (d[4][4] <<< 2);
    assign tim_c[0][4] = 11'sd0;
    assign tre_c[0][5] = (d[0][5] <<< 2) - (d[4][5] <<< 2);
    assign tim_c[0][5] = 11'sd0;
    assign tre_c[1][0] = d[1][0] + d[2][0] + d[3][0] + d[4][0];
    assign tim_c[1][0] = 11'sd0;
    assign tre_c[1][1] = d[1][1] + d[2][1] + d[3][1] + d[4][1];
    assign tim_c[1][1] = 11'sd0;
    assign tre_c[1][2] = d[1][2] + d[2][2] + d[3][2] + d[4][2];
    assign tim_c[1][2] = 11'sd0;
    assign tre_c[1][3] = d[1][3] + d[2][3] + d[3][3] + d[4][3];
    assign tim_c[1][3] = 11'sd0;
    assign tre_c[1][4] = d[1][4] + d[2][4] + d[3][4] + d[4][4];
    assign tim_c[1][4] = 11'sd0;
    assign tre_c[1][5] = d[1][5] + d[2][5] + d[3][5] + d[4][5];
    assign tim_c[1][5] = 11'sd0;
    assign tre_c[2][0] = -d[1][0] + d[2][0] - d[3][0] + d[4][0];
    assign tim_c[2][0] = 11'sd0;
    assign tre_c[2][1] = -d[1][1] + d[2][1] - d[3][1] + d[4][1];
    assign tim_c[2][1] = 11'sd0;
    assign tre_c[2][2] = -d[1][2] + d[2][2] - d[3][2] + d[4][2];
    assign tim_c[2][2] = 11'sd0;
    assign tre_c[2][3] = -d[1][3] + d[2][3] - d[3][3] + d[4][3];
    assign tim_c[2][3] = 11'sd0;
    assign tre_c[2][4] = -d[1][4] + d[2][4] - d[3][4] + d[4][4];
    assign tim_c[2][4] = 11'sd0;
    assign tre_c[2][5] = -d[1][5] + d[2][5] - d[3][5] + d[4][5];
    assign tim_c[2][5] = 11'sd0;
    assign tre_c[3][0] = -d[2][0] + d[4][0];
    assign tim_c[3][0] = -d[1][0] + d[3][0];
    assign tre_c[3][1] = -d[2][1] + d[4][1];
    assign tim_c[3][1] = -d[1][1] + d[3][1];
    assign tre_c[3][2] = -d[2][2] + d[4][2];
    assign tim_c[3][2] = -d[1][2] + d[3][2];
    assign tre_c[3][3] = -d[2][3] + d[4][3];
    assign tim_c[3][3] = -d[1][3] + d[3][3];
    assign tre_c[3][4] = -d[2][4] + d[4][4];
    assign tim_c[3][4] = -d[1][4] + d[3][4];
    assign tre_c[3][5] = -d[2][5] + d[4][5];
    assign tim_c[3][5] = -d[1][5] + d[3][5];
    assign tre_c[4][0] = -d[2][0] + d[4][0];
    assign tim_c[4][0] = d[1][0] - d[3][0];
    assign tre_c[4][1] = -d[2][1] + d[4][1];
    assign tim_c[4][1] = d[1][1] - d[3][1];
    assign tre_c[4][2] = -d[2][2] + d[4][2];
    assign tim_c[4][2] = d[1][2] - d[3][2];
    assign tre_c[4][3] = -d[2][3] + d[4][3];
    assign tim_c[4][3] = d[1][3] - d[3][3];
    assign tre_c[4][4] = -d[2][4] + d[4][4];
    assign tim_c[4][4] = d[1][4] - d[3][4];
    assign tre_c[4][5] = -d[2][5] + d[4][5];
    assign tim_c[4][5] = d[1][5] - d[3][5];
    assign tre_c[5][0] = -(d[1][0] <<< 2) + (d[5][0] <<< 2);
    assign tim_c[5][0] = 11'sd0;
    assign tre_c[5][1] = -(d[1][1] <<< 2) + (d[5][1] <<< 2);
    assign tim_c[5][1] = 11'sd0;
    assign tre_c[5][2] = -(d[1][2] <<< 2) + (d[5][2] <<< 2);
    assign tim_c[5][2] = 11'sd0;
    assign tre_c[5][3] = -(d[1][3] <<< 2) + (d[5][3] <<< 2);
    assign tim_c[5][3] = 11'sd0;
    assign tre_c[5][4] = -(d[1][4] <<< 2) + (d[5][4] <<< 2);
    assign tim_c[5][4] = 11'sd0;
    assign tre_c[5][5] = -(d[1][5] <<< 2) + (d[5][5] <<< 2);
    assign tim_c[5][5] = 11'sd0;

    // stage1→2 register (t)
    reg signed [10:0] tre [0:5][0:5];
    reg signed [10:0] tim [0:5][0:5];
    integer rp, rl;
    always @(posedge clk) for (rp=0; rp<6; rp=rp+1) for (rl=0; rl<6; rl=rl+1) begin
        tre[rp][rl] <= tre_c[rp][rl];
        tim[rp][rl] <= tim_c[rp][rl];
    end

    // stage2: V = t·B   V[p][q] = Σ_l t[p][l]·Bᵀ[q,l]   (B[l][q]=Bᵀ[q,l])
    wire signed [13:0] vre_0_0 = (tre[0][0] <<< 2) - (tre[0][4] <<< 2);
    wire signed [13:0] vre_0_1 = tre[0][1] + tre[0][2] + tre[0][3] + tre[0][4];
    wire signed [13:0] vre_0_2 = -tre[0][1] + tre[0][2] - tre[0][3] + tre[0][4];
    wire signed [13:0] vre_0_3 = tim[0][1] - tre[0][2] - tim[0][3] + tre[0][4];
    wire signed [13:0] vre_0_5 = -(tre[0][1] <<< 2) + (tre[0][5] <<< 2);
    wire signed [13:0] vre_1_0 = (tre[1][0] <<< 2) - (tre[1][4] <<< 2);
    wire signed [13:0] vre_1_1 = tre[1][1] + tre[1][2] + tre[1][3] + tre[1][4];
    wire signed [13:0] vre_1_2 = -tre[1][1] + tre[1][2] - tre[1][3] + tre[1][4];
    wire signed [13:0] vre_1_3 = tim[1][1] - tre[1][2] - tim[1][3] + tre[1][4];
    wire signed [13:0] vre_1_5 = -(tre[1][1] <<< 2) + (tre[1][5] <<< 2);
    wire signed [13:0] vre_2_0 = (tre[2][0] <<< 2) - (tre[2][4] <<< 2);
    wire signed [13:0] vre_2_1 = tre[2][1] + tre[2][2] + tre[2][3] + tre[2][4];
    wire signed [13:0] vre_2_2 = -tre[2][1] + tre[2][2] - tre[2][3] + tre[2][4];
    wire signed [13:0] vre_2_3 = tim[2][1] - tre[2][2] - tim[2][3] + tre[2][4];
    wire signed [13:0] vre_2_5 = -(tre[2][1] <<< 2) + (tre[2][5] <<< 2);
    wire signed [13:0] vre_3_0 = (tre[3][0] <<< 2) - (tre[3][4] <<< 2);
    wire signed [13:0] vre_3_1 = tre[3][1] + tre[3][2] + tre[3][3] + tre[3][4];
    wire signed [13:0] vre_3_2 = -tre[3][1] + tre[3][2] - tre[3][3] + tre[3][4];
    wire signed [13:0] vre_3_3 = tim[3][1] - tre[3][2] - tim[3][3] + tre[3][4];
    wire signed [13:0] vre_3_4 = -tim[3][1] - tre[3][2] + tim[3][3] + tre[3][4];
    wire signed [13:0] vre_3_5 = -(tre[3][1] <<< 2) + (tre[3][5] <<< 2);
    wire signed [13:0] vre_5_0 = (tre[5][0] <<< 2) - (tre[5][4] <<< 2);
    wire signed [13:0] vre_5_1 = tre[5][1] + tre[5][2] + tre[5][3] + tre[5][4];
    wire signed [13:0] vre_5_2 = -tre[5][1] + tre[5][2] - tre[5][3] + tre[5][4];
    wire signed [13:0] vre_5_3 = tim[5][1] - tre[5][2] - tim[5][3] + tre[5][4];
    wire signed [13:0] vre_5_5 = -(tre[5][1] <<< 2) + (tre[5][5] <<< 2);
    wire signed [13:0] vim_0_3 = -tre[0][1] - tim[0][2] + tre[0][3] + tim[0][4];
    wire signed [13:0] vim_1_3 = -tre[1][1] - tim[1][2] + tre[1][3] + tim[1][4];
    wire signed [13:0] vim_2_3 = -tre[2][1] - tim[2][2] + tre[2][3] + tim[2][4];
    wire signed [13:0] vim_3_0 = (tim[3][0] <<< 2) - (tim[3][4] <<< 2);
    wire signed [13:0] vim_3_1 = tim[3][1] + tim[3][2] + tim[3][3] + tim[3][4];
    wire signed [13:0] vim_3_2 = -tim[3][1] + tim[3][2] - tim[3][3] + tim[3][4];
    wire signed [13:0] vim_3_3 = -tre[3][1] - tim[3][2] + tre[3][3] + tim[3][4];
    wire signed [13:0] vim_3_4 = tre[3][1] - tim[3][2] - tre[3][3] + tim[3][4];
    wire signed [13:0] vim_3_5 = -(tim[3][1] <<< 2) + (tim[3][5] <<< 2);
    wire signed [13:0] vim_5_3 = -tre[5][1] - tim[5][2] + tre[5][3] + tim[5][4];

    // 46 activation operand (canonical 순서 = weight operand 와 동일)
    assign a_flat[0*VW +: VW] = vre_0_0;  // real (0,0) V_re
    assign a_flat[1*VW +: VW] = vre_0_1;  // real (0,1) V_re
    assign a_flat[2*VW +: VW] = vre_0_2;  // real (0,2) V_re
    assign a_flat[3*VW +: VW] = vre_0_5;  // real (0,5) V_re
    assign a_flat[4*VW +: VW] = vre_1_0;  // real (1,0) V_re
    assign a_flat[5*VW +: VW] = vre_1_1;  // real (1,1) V_re
    assign a_flat[6*VW +: VW] = vre_1_2;  // real (1,2) V_re
    assign a_flat[7*VW +: VW] = vre_1_5;  // real (1,5) V_re
    assign a_flat[8*VW +: VW] = vre_2_0;  // real (2,0) V_re
    assign a_flat[9*VW +: VW] = vre_2_1;  // real (2,1) V_re
    assign a_flat[10*VW +: VW] = vre_2_2;  // real (2,2) V_re
    assign a_flat[11*VW +: VW] = vre_2_5;  // real (2,5) V_re
    assign a_flat[12*VW +: VW] = vre_5_0;  // real (5,0) V_re
    assign a_flat[13*VW +: VW] = vre_5_1;  // real (5,1) V_re
    assign a_flat[14*VW +: VW] = vre_5_2;  // real (5,2) V_re
    assign a_flat[15*VW +: VW] = vre_5_5;  // real (5,5) V_re
    assign a_flat[16*VW +: VW] = vre_0_3 + vim_0_3;  // cmul (0,3) c+d
    assign a_flat[17*VW +: VW] = vre_0_3;  // cmul (0,3) c
    assign a_flat[18*VW +: VW] = vim_0_3;  // cmul (0,3) d
    assign a_flat[19*VW +: VW] = vre_1_3 + vim_1_3;  // cmul (1,3) c+d
    assign a_flat[20*VW +: VW] = vre_1_3;  // cmul (1,3) c
    assign a_flat[21*VW +: VW] = vim_1_3;  // cmul (1,3) d
    assign a_flat[22*VW +: VW] = vre_2_3 + vim_2_3;  // cmul (2,3) c+d
    assign a_flat[23*VW +: VW] = vre_2_3;  // cmul (2,3) c
    assign a_flat[24*VW +: VW] = vim_2_3;  // cmul (2,3) d
    assign a_flat[25*VW +: VW] = vre_3_0 + vim_3_0;  // cmul (3,0) c+d
    assign a_flat[26*VW +: VW] = vre_3_0;  // cmul (3,0) c
    assign a_flat[27*VW +: VW] = vim_3_0;  // cmul (3,0) d
    assign a_flat[28*VW +: VW] = vre_3_1 + vim_3_1;  // cmul (3,1) c+d
    assign a_flat[29*VW +: VW] = vre_3_1;  // cmul (3,1) c
    assign a_flat[30*VW +: VW] = vim_3_1;  // cmul (3,1) d
    assign a_flat[31*VW +: VW] = vre_3_2 + vim_3_2;  // cmul (3,2) c+d
    assign a_flat[32*VW +: VW] = vre_3_2;  // cmul (3,2) c
    assign a_flat[33*VW +: VW] = vim_3_2;  // cmul (3,2) d
    assign a_flat[34*VW +: VW] = vre_3_3 + vim_3_3;  // cmul (3,3) c+d
    assign a_flat[35*VW +: VW] = vre_3_3;  // cmul (3,3) c
    assign a_flat[36*VW +: VW] = vim_3_3;  // cmul (3,3) d
    assign a_flat[37*VW +: VW] = vre_3_4 + vim_3_4;  // cmul (3,4) c+d
    assign a_flat[38*VW +: VW] = vre_3_4;  // cmul (3,4) c
    assign a_flat[39*VW +: VW] = vim_3_4;  // cmul (3,4) d
    assign a_flat[40*VW +: VW] = vre_3_5 + vim_3_5;  // cmul (3,5) c+d
    assign a_flat[41*VW +: VW] = vre_3_5;  // cmul (3,5) c
    assign a_flat[42*VW +: VW] = vim_3_5;  // cmul (3,5) d
    assign a_flat[43*VW +: VW] = vre_5_3 + vim_5_3;  // cmul (5,3) c+d
    assign a_flat[44*VW +: VW] = vre_5_3;  // cmul (5,3) c
    assign a_flat[45*VW +: VW] = vim_5_3;  // cmul (5,3) d
endmodule
