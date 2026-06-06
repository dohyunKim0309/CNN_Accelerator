`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// wino_output_transform.v  (자동생성: scripts/weights/winograd_gen.py)
//   복소수 Winograd F(4,3) 출력변환  Y16 = Aᵀ·M·A  (per OC,tile, 곱셈기 0개)
//   M(6×6 complex, 켤레 포함 전체) → Y16(4×4 real). imag 은 수학적으로 0.
//   2-stage: y=Aᵀ·M (계수 {0,±1}) → Y16=y·A (계수 {0,±1}). add/sub/neg only.
//   out = sat(Y16>>>14)+ReLU 은 wino_truncate 에서 (= direct conv bit-exact).
////////////////////////////////////////////////////////////////////////////////
module wino_output_transform #(parameter MW=25, YW=28) (
    input  wire [36*MW-1:0] mre_flat,  // M_re[p][q] = [(p*6+q)*MW +: MW] (signed)
    input  wire [36*MW-1:0] mim_flat,  // M_im[p][q]
    output wire [16*YW-1:0] y16_flat   // Y16[i][j] = [(i*4+j)*YW +: YW] (signed, real)
);
    wire signed [24:0] mre [0:5][0:5];
    wire signed [24:0] mim [0:5][0:5];
    genvar gp, gq;
    generate for (gp=0; gp<6; gp=gp+1) for (gq=0; gq<6; gq=gq+1) begin
        assign mre[gp][gq] = $signed(mre_flat[(gp*6+gq)*MW +: MW]);
        assign mim[gp][gq] = $signed(mim_flat[(gp*6+gq)*MW +: MW]);
    end endgenerate

    // stage1: y = Aᵀ·M   y[i][l] = Σ_p Aᵀ[i,p]·M[p][l]
    wire signed [27:0] yre [0:3][0:5];
    wire signed [27:0] yim [0:3][0:5];
    assign yre[0][0] = mre[0][0] + mre[1][0] + mre[2][0] + mre[3][0] + mre[4][0];
    assign yim[0][0] = mim[0][0] + mim[1][0] + mim[2][0] + mim[3][0] + mim[4][0];
    assign yre[0][1] = mre[0][1] + mre[1][1] + mre[2][1] + mre[3][1] + mre[4][1];
    assign yim[0][1] = mim[0][1] + mim[1][1] + mim[2][1] + mim[3][1] + mim[4][1];
    assign yre[0][2] = mre[0][2] + mre[1][2] + mre[2][2] + mre[3][2] + mre[4][2];
    assign yim[0][2] = mim[0][2] + mim[1][2] + mim[2][2] + mim[3][2] + mim[4][2];
    assign yre[0][3] = mre[0][3] + mre[1][3] + mre[2][3] + mre[3][3] + mre[4][3];
    assign yim[0][3] = mim[0][3] + mim[1][3] + mim[2][3] + mim[3][3] + mim[4][3];
    assign yre[0][4] = mre[0][4] + mre[1][4] + mre[2][4] + mre[3][4] + mre[4][4];
    assign yim[0][4] = mim[0][4] + mim[1][4] + mim[2][4] + mim[3][4] + mim[4][4];
    assign yre[0][5] = mre[0][5] + mre[1][5] + mre[2][5] + mre[3][5] + mre[4][5];
    assign yim[0][5] = mim[0][5] + mim[1][5] + mim[2][5] + mim[3][5] + mim[4][5];
    assign yre[1][0] = mre[1][0] - mre[2][0] - mim[3][0] + mim[4][0];
    assign yim[1][0] = mim[1][0] - mim[2][0] + mre[3][0] - mre[4][0];
    assign yre[1][1] = mre[1][1] - mre[2][1] - mim[3][1] + mim[4][1];
    assign yim[1][1] = mim[1][1] - mim[2][1] + mre[3][1] - mre[4][1];
    assign yre[1][2] = mre[1][2] - mre[2][2] - mim[3][2] + mim[4][2];
    assign yim[1][2] = mim[1][2] - mim[2][2] + mre[3][2] - mre[4][2];
    assign yre[1][3] = mre[1][3] - mre[2][3] - mim[3][3] + mim[4][3];
    assign yim[1][3] = mim[1][3] - mim[2][3] + mre[3][3] - mre[4][3];
    assign yre[1][4] = mre[1][4] - mre[2][4] - mim[3][4] + mim[4][4];
    assign yim[1][4] = mim[1][4] - mim[2][4] + mre[3][4] - mre[4][4];
    assign yre[1][5] = mre[1][5] - mre[2][5] - mim[3][5] + mim[4][5];
    assign yim[1][5] = mim[1][5] - mim[2][5] + mre[3][5] - mre[4][5];
    assign yre[2][0] = mre[1][0] + mre[2][0] - mre[3][0] - mre[4][0];
    assign yim[2][0] = mim[1][0] + mim[2][0] - mim[3][0] - mim[4][0];
    assign yre[2][1] = mre[1][1] + mre[2][1] - mre[3][1] - mre[4][1];
    assign yim[2][1] = mim[1][1] + mim[2][1] - mim[3][1] - mim[4][1];
    assign yre[2][2] = mre[1][2] + mre[2][2] - mre[3][2] - mre[4][2];
    assign yim[2][2] = mim[1][2] + mim[2][2] - mim[3][2] - mim[4][2];
    assign yre[2][3] = mre[1][3] + mre[2][3] - mre[3][3] - mre[4][3];
    assign yim[2][3] = mim[1][3] + mim[2][3] - mim[3][3] - mim[4][3];
    assign yre[2][4] = mre[1][4] + mre[2][4] - mre[3][4] - mre[4][4];
    assign yim[2][4] = mim[1][4] + mim[2][4] - mim[3][4] - mim[4][4];
    assign yre[2][5] = mre[1][5] + mre[2][5] - mre[3][5] - mre[4][5];
    assign yim[2][5] = mim[1][5] + mim[2][5] - mim[3][5] - mim[4][5];
    assign yre[3][0] = mre[1][0] - mre[2][0] + mim[3][0] - mim[4][0] + mre[5][0];
    assign yim[3][0] = mim[1][0] - mim[2][0] - mre[3][0] + mre[4][0] + mim[5][0];
    assign yre[3][1] = mre[1][1] - mre[2][1] + mim[3][1] - mim[4][1] + mre[5][1];
    assign yim[3][1] = mim[1][1] - mim[2][1] - mre[3][1] + mre[4][1] + mim[5][1];
    assign yre[3][2] = mre[1][2] - mre[2][2] + mim[3][2] - mim[4][2] + mre[5][2];
    assign yim[3][2] = mim[1][2] - mim[2][2] - mre[3][2] + mre[4][2] + mim[5][2];
    assign yre[3][3] = mre[1][3] - mre[2][3] + mim[3][3] - mim[4][3] + mre[5][3];
    assign yim[3][3] = mim[1][3] - mim[2][3] - mre[3][3] + mre[4][3] + mim[5][3];
    assign yre[3][4] = mre[1][4] - mre[2][4] + mim[3][4] - mim[4][4] + mre[5][4];
    assign yim[3][4] = mim[1][4] - mim[2][4] - mre[3][4] + mre[4][4] + mim[5][4];
    assign yre[3][5] = mre[1][5] - mre[2][5] + mim[3][5] - mim[4][5] + mre[5][5];
    assign yim[3][5] = mim[1][5] - mim[2][5] - mre[3][5] + mre[4][5] + mim[5][5];

    // stage2: Y16 = y·A   Y16[i][j] = Σ_l y[i][l]·Aᵀ[j,l]  (real part, imag=0)
    assign y16_flat[0*YW +: YW] = yre[0][0] + yre[0][1] + yre[0][2] + yre[0][3] + yre[0][4];
    assign y16_flat[1*YW +: YW] = yre[0][1] - yre[0][2] - yim[0][3] + yim[0][4];
    assign y16_flat[2*YW +: YW] = yre[0][1] + yre[0][2] - yre[0][3] - yre[0][4];
    assign y16_flat[3*YW +: YW] = yre[0][1] - yre[0][2] + yim[0][3] - yim[0][4] + yre[0][5];
    assign y16_flat[4*YW +: YW] = yre[1][0] + yre[1][1] + yre[1][2] + yre[1][3] + yre[1][4];
    assign y16_flat[5*YW +: YW] = yre[1][1] - yre[1][2] - yim[1][3] + yim[1][4];
    assign y16_flat[6*YW +: YW] = yre[1][1] + yre[1][2] - yre[1][3] - yre[1][4];
    assign y16_flat[7*YW +: YW] = yre[1][1] - yre[1][2] + yim[1][3] - yim[1][4] + yre[1][5];
    assign y16_flat[8*YW +: YW] = yre[2][0] + yre[2][1] + yre[2][2] + yre[2][3] + yre[2][4];
    assign y16_flat[9*YW +: YW] = yre[2][1] - yre[2][2] - yim[2][3] + yim[2][4];
    assign y16_flat[10*YW +: YW] = yre[2][1] + yre[2][2] - yre[2][3] - yre[2][4];
    assign y16_flat[11*YW +: YW] = yre[2][1] - yre[2][2] + yim[2][3] - yim[2][4] + yre[2][5];
    assign y16_flat[12*YW +: YW] = yre[3][0] + yre[3][1] + yre[3][2] + yre[3][3] + yre[3][4];
    assign y16_flat[13*YW +: YW] = yre[3][1] - yre[3][2] - yim[3][3] + yim[3][4];
    assign y16_flat[14*YW +: YW] = yre[3][1] + yre[3][2] - yre[3][3] - yre[3][4];
    assign y16_flat[15*YW +: YW] = yre[3][1] - yre[3][2] + yim[3][3] - yim[3][4] + yre[3][5];
endmodule
