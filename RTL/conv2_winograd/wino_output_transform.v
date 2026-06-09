`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// wino_output_transform.v  (자동생성: scripts/weights/winograd_gen.py)
//   복소수 Winograd F(4,3) 출력변환  Y16 = Aᵀ·M·A  (per OC,tile, 곱셈기 0개)
//   M(6×6 complex, 켤레 포함 전체) → Y16(4×4 real). imag 은 수학적으로 0.
//   ★ 2-stage PIPELINE: in_valid@T → stage1 y=Aᵀ·M(reg) → stage2 Y16=y·A(reg)
//      → y16_flat/out_valid@T+2.  계수 {0,±1} add/sub/neg only.
//   out = sat(Y16>>>14)+ReLU 은 wino_truncate 에서 (= direct conv bit-exact).
////////////////////////////////////////////////////////////////////////////////
module wino_output_transform #(parameter MW=25, YW=28) (
    input  wire             clk,
    input  wire             in_valid,  // M 유효 pulse
    input  wire [36*MW-1:0] mre_flat,  // M_re[p][q] = [(p*6+q)*MW +: MW] (signed)
    input  wire [36*MW-1:0] mim_flat,  // M_im[p][q]
    output reg              out_valid, // Y16 유효 pulse (in_valid+2)
    output reg  [16*YW-1:0] y16_flat   // Y16[i][j] = [(i*4+j)*YW +: YW] (signed, real)
);
    wire signed [24:0] mre [0:5][0:5];
    wire signed [24:0] mim [0:5][0:5];
    genvar gp, gq;
    generate for (gp=0; gp<6; gp=gp+1) for (gq=0; gq<6; gq=gq+1) begin
        assign mre[gp][gq] = $signed(mre_flat[(gp*6+gq)*MW +: MW]);
        assign mim[gp][gq] = $signed(mim_flat[(gp*6+gq)*MW +: MW]);
    end endgenerate

    // stage1 (comb): y = Aᵀ·M   y[i][l] = Σ_p Aᵀ[i,p]·M[p][l]
    wire signed [27:0] yre_c [0:3][0:5];
    wire signed [27:0] yim_c [0:3][0:5];
    assign yre_c[0][0] = mre[0][0] + mre[1][0] + mre[2][0] + mre[3][0] + mre[4][0];
    assign yim_c[0][0] = mim[0][0] + mim[1][0] + mim[2][0] + mim[3][0] + mim[4][0];
    assign yre_c[0][1] = mre[0][1] + mre[1][1] + mre[2][1] + mre[3][1] + mre[4][1];
    assign yim_c[0][1] = mim[0][1] + mim[1][1] + mim[2][1] + mim[3][1] + mim[4][1];
    assign yre_c[0][2] = mre[0][2] + mre[1][2] + mre[2][2] + mre[3][2] + mre[4][2];
    assign yim_c[0][2] = mim[0][2] + mim[1][2] + mim[2][2] + mim[3][2] + mim[4][2];
    assign yre_c[0][3] = mre[0][3] + mre[1][3] + mre[2][3] + mre[3][3] + mre[4][3];
    assign yim_c[0][3] = mim[0][3] + mim[1][3] + mim[2][3] + mim[3][3] + mim[4][3];
    assign yre_c[0][4] = mre[0][4] + mre[1][4] + mre[2][4] + mre[3][4] + mre[4][4];
    assign yim_c[0][4] = mim[0][4] + mim[1][4] + mim[2][4] + mim[3][4] + mim[4][4];
    assign yre_c[0][5] = mre[0][5] + mre[1][5] + mre[2][5] + mre[3][5] + mre[4][5];
    assign yim_c[0][5] = mim[0][5] + mim[1][5] + mim[2][5] + mim[3][5] + mim[4][5];
    assign yre_c[1][0] = mre[1][0] - mre[2][0] - mim[3][0] + mim[4][0];
    assign yim_c[1][0] = mim[1][0] - mim[2][0] + mre[3][0] - mre[4][0];
    assign yre_c[1][1] = mre[1][1] - mre[2][1] - mim[3][1] + mim[4][1];
    assign yim_c[1][1] = mim[1][1] - mim[2][1] + mre[3][1] - mre[4][1];
    assign yre_c[1][2] = mre[1][2] - mre[2][2] - mim[3][2] + mim[4][2];
    assign yim_c[1][2] = mim[1][2] - mim[2][2] + mre[3][2] - mre[4][2];
    assign yre_c[1][3] = mre[1][3] - mre[2][3] - mim[3][3] + mim[4][3];
    assign yim_c[1][3] = mim[1][3] - mim[2][3] + mre[3][3] - mre[4][3];
    assign yre_c[1][4] = mre[1][4] - mre[2][4] - mim[3][4] + mim[4][4];
    assign yim_c[1][4] = mim[1][4] - mim[2][4] + mre[3][4] - mre[4][4];
    assign yre_c[1][5] = mre[1][5] - mre[2][5] - mim[3][5] + mim[4][5];
    assign yim_c[1][5] = mim[1][5] - mim[2][5] + mre[3][5] - mre[4][5];
    assign yre_c[2][0] = mre[1][0] + mre[2][0] - mre[3][0] - mre[4][0];
    assign yim_c[2][0] = mim[1][0] + mim[2][0] - mim[3][0] - mim[4][0];
    assign yre_c[2][1] = mre[1][1] + mre[2][1] - mre[3][1] - mre[4][1];
    assign yim_c[2][1] = mim[1][1] + mim[2][1] - mim[3][1] - mim[4][1];
    assign yre_c[2][2] = mre[1][2] + mre[2][2] - mre[3][2] - mre[4][2];
    assign yim_c[2][2] = mim[1][2] + mim[2][2] - mim[3][2] - mim[4][2];
    assign yre_c[2][3] = mre[1][3] + mre[2][3] - mre[3][3] - mre[4][3];
    assign yim_c[2][3] = mim[1][3] + mim[2][3] - mim[3][3] - mim[4][3];
    assign yre_c[2][4] = mre[1][4] + mre[2][4] - mre[3][4] - mre[4][4];
    assign yim_c[2][4] = mim[1][4] + mim[2][4] - mim[3][4] - mim[4][4];
    assign yre_c[2][5] = mre[1][5] + mre[2][5] - mre[3][5] - mre[4][5];
    assign yim_c[2][5] = mim[1][5] + mim[2][5] - mim[3][5] - mim[4][5];
    assign yre_c[3][0] = mre[1][0] - mre[2][0] + mim[3][0] - mim[4][0] + mre[5][0];
    assign yim_c[3][0] = mim[1][0] - mim[2][0] - mre[3][0] + mre[4][0] + mim[5][0];
    assign yre_c[3][1] = mre[1][1] - mre[2][1] + mim[3][1] - mim[4][1] + mre[5][1];
    assign yim_c[3][1] = mim[1][1] - mim[2][1] - mre[3][1] + mre[4][1] + mim[5][1];
    assign yre_c[3][2] = mre[1][2] - mre[2][2] + mim[3][2] - mim[4][2] + mre[5][2];
    assign yim_c[3][2] = mim[1][2] - mim[2][2] - mre[3][2] + mre[4][2] + mim[5][2];
    assign yre_c[3][3] = mre[1][3] - mre[2][3] + mim[3][3] - mim[4][3] + mre[5][3];
    assign yim_c[3][3] = mim[1][3] - mim[2][3] - mre[3][3] + mre[4][3] + mim[5][3];
    assign yre_c[3][4] = mre[1][4] - mre[2][4] + mim[3][4] - mim[4][4] + mre[5][4];
    assign yim_c[3][4] = mim[1][4] - mim[2][4] - mre[3][4] + mre[4][4] + mim[5][4];
    assign yre_c[3][5] = mre[1][5] - mre[2][5] + mim[3][5] - mim[4][5] + mre[5][5];
    assign yim_c[3][5] = mim[1][5] - mim[2][5] - mre[3][5] + mre[4][5] + mim[5][5];

    // stage1→2 register (y) + valid stage1
    reg signed [27:0] yre [0:3][0:5];
    reg signed [27:0] yim [0:3][0:5];
    reg v1;
    integer ri, rl;
    always @(posedge clk) begin
        v1 <= in_valid;
        for (ri=0; ri<4; ri=ri+1) for (rl=0; rl<6; rl=rl+1) begin
            yre[ri][rl] <= yre_c[ri][rl];
            yim[ri][rl] <= yim_c[ri][rl];
        end
    end

    // stage2 (comb): Y16 = y·A   Y16[i][j] = Σ_l y[i][l]·Aᵀ[j,l]  (real part, imag=0)
    wire signed [27:0] y16_c [0:3][0:3];
    assign y16_c[0][0] = yre[0][0] + yre[0][1] + yre[0][2] + yre[0][3] + yre[0][4];
    assign y16_c[0][1] = yre[0][1] - yre[0][2] - yim[0][3] + yim[0][4];
    assign y16_c[0][2] = yre[0][1] + yre[0][2] - yre[0][3] - yre[0][4];
    assign y16_c[0][3] = yre[0][1] - yre[0][2] + yim[0][3] - yim[0][4] + yre[0][5];
    assign y16_c[1][0] = yre[1][0] + yre[1][1] + yre[1][2] + yre[1][3] + yre[1][4];
    assign y16_c[1][1] = yre[1][1] - yre[1][2] - yim[1][3] + yim[1][4];
    assign y16_c[1][2] = yre[1][1] + yre[1][2] - yre[1][3] - yre[1][4];
    assign y16_c[1][3] = yre[1][1] - yre[1][2] + yim[1][3] - yim[1][4] + yre[1][5];
    assign y16_c[2][0] = yre[2][0] + yre[2][1] + yre[2][2] + yre[2][3] + yre[2][4];
    assign y16_c[2][1] = yre[2][1] - yre[2][2] - yim[2][3] + yim[2][4];
    assign y16_c[2][2] = yre[2][1] + yre[2][2] - yre[2][3] - yre[2][4];
    assign y16_c[2][3] = yre[2][1] - yre[2][2] + yim[2][3] - yim[2][4] + yre[2][5];
    assign y16_c[3][0] = yre[3][0] + yre[3][1] + yre[3][2] + yre[3][3] + yre[3][4];
    assign y16_c[3][1] = yre[3][1] - yre[3][2] - yim[3][3] + yim[3][4];
    assign y16_c[3][2] = yre[3][1] + yre[3][2] - yre[3][3] - yre[3][4];
    assign y16_c[3][3] = yre[3][1] - yre[3][2] + yim[3][3] - yim[3][4] + yre[3][5];

    // stage2 register (Y16) + out_valid
    integer oi, oj;
    always @(posedge clk) begin
        out_valid <= v1;
        for (oi=0; oi<4; oi=oi+1) for (oj=0; oj<4; oj=oj+1)
            y16_flat[(oi*4+oj)*YW +: YW] <= y16_c[oi][oj];
    end
endmodule
