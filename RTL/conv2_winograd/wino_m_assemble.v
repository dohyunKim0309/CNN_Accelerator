`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// wino_m_assemble.v  (자동생성: scripts/weights/winograd_gen.py)
//   26 계산 position(Msum) → 36 full M(6×6). 켤레유도: M[der]=conj(M[rep]).
//   Msum index: 0..15 = REAL_POS, 16..25 = CMUL_POS.
////////////////////////////////////////////////////////////////////////////////
module wino_m_assemble #(parameter MW=25) (
    input  wire [26*MW-1:0] sre_flat,  // Msum re, idx k = [k*MW +: MW]
    input  wire [26*MW-1:0] sim_flat,  // Msum im
    output wire [36*MW-1:0] mre_flat,  // M[p][q] = [(p*6+q)*MW +: MW]
    output wire [36*MW-1:0] mim_flat
);
    wire signed [MW-1:0] sre [0:25];
    wire signed [MW-1:0] sim [0:25];
    genvar gk;
    generate for (gk=0; gk<26; gk=gk+1) begin
        assign sre[gk] = $signed(sre_flat[gk*MW +: MW]);
        assign sim[gk] = $signed(sim_flat[gk*MW +: MW]);
    end endgenerate

    assign mre_flat[0*MW +: MW] = sre[0];   // (0,0) real
    assign mim_flat[0*MW +: MW] = 25'sd0;
    assign mre_flat[1*MW +: MW] = sre[1];   // (0,1) real
    assign mim_flat[1*MW +: MW] = 25'sd0;
    assign mre_flat[2*MW +: MW] = sre[2];   // (0,2) real
    assign mim_flat[2*MW +: MW] = 25'sd0;
    assign mre_flat[3*MW +: MW] = sre[16];   // (0,3) cmul
    assign mim_flat[3*MW +: MW] = sim[16];
    assign mre_flat[4*MW +: MW] =  sre[16];  // (0,4) conj of (0, 3)
    assign mim_flat[4*MW +: MW] = -sim[16];
    assign mre_flat[5*MW +: MW] = sre[3];   // (0,5) real
    assign mim_flat[5*MW +: MW] = 25'sd0;
    assign mre_flat[6*MW +: MW] = sre[4];   // (1,0) real
    assign mim_flat[6*MW +: MW] = 25'sd0;
    assign mre_flat[7*MW +: MW] = sre[5];   // (1,1) real
    assign mim_flat[7*MW +: MW] = 25'sd0;
    assign mre_flat[8*MW +: MW] = sre[6];   // (1,2) real
    assign mim_flat[8*MW +: MW] = 25'sd0;
    assign mre_flat[9*MW +: MW] = sre[17];   // (1,3) cmul
    assign mim_flat[9*MW +: MW] = sim[17];
    assign mre_flat[10*MW +: MW] =  sre[17];  // (1,4) conj of (1, 3)
    assign mim_flat[10*MW +: MW] = -sim[17];
    assign mre_flat[11*MW +: MW] = sre[7];   // (1,5) real
    assign mim_flat[11*MW +: MW] = 25'sd0;
    assign mre_flat[12*MW +: MW] = sre[8];   // (2,0) real
    assign mim_flat[12*MW +: MW] = 25'sd0;
    assign mre_flat[13*MW +: MW] = sre[9];   // (2,1) real
    assign mim_flat[13*MW +: MW] = 25'sd0;
    assign mre_flat[14*MW +: MW] = sre[10];   // (2,2) real
    assign mim_flat[14*MW +: MW] = 25'sd0;
    assign mre_flat[15*MW +: MW] = sre[18];   // (2,3) cmul
    assign mim_flat[15*MW +: MW] = sim[18];
    assign mre_flat[16*MW +: MW] =  sre[18];  // (2,4) conj of (2, 3)
    assign mim_flat[16*MW +: MW] = -sim[18];
    assign mre_flat[17*MW +: MW] = sre[11];   // (2,5) real
    assign mim_flat[17*MW +: MW] = 25'sd0;
    assign mre_flat[18*MW +: MW] = sre[19];   // (3,0) cmul
    assign mim_flat[18*MW +: MW] = sim[19];
    assign mre_flat[19*MW +: MW] = sre[20];   // (3,1) cmul
    assign mim_flat[19*MW +: MW] = sim[20];
    assign mre_flat[20*MW +: MW] = sre[21];   // (3,2) cmul
    assign mim_flat[20*MW +: MW] = sim[21];
    assign mre_flat[21*MW +: MW] = sre[22];   // (3,3) cmul
    assign mim_flat[21*MW +: MW] = sim[22];
    assign mre_flat[22*MW +: MW] = sre[23];   // (3,4) cmul
    assign mim_flat[22*MW +: MW] = sim[23];
    assign mre_flat[23*MW +: MW] = sre[24];   // (3,5) cmul
    assign mim_flat[23*MW +: MW] = sim[24];
    assign mre_flat[24*MW +: MW] =  sre[19];  // (4,0) conj of (3, 0)
    assign mim_flat[24*MW +: MW] = -sim[19];
    assign mre_flat[25*MW +: MW] =  sre[20];  // (4,1) conj of (3, 1)
    assign mim_flat[25*MW +: MW] = -sim[20];
    assign mre_flat[26*MW +: MW] =  sre[21];  // (4,2) conj of (3, 2)
    assign mim_flat[26*MW +: MW] = -sim[21];
    assign mre_flat[27*MW +: MW] =  sre[23];  // (4,3) conj of (3, 4)
    assign mim_flat[27*MW +: MW] = -sim[23];
    assign mre_flat[28*MW +: MW] =  sre[22];  // (4,4) conj of (3, 3)
    assign mim_flat[28*MW +: MW] = -sim[22];
    assign mre_flat[29*MW +: MW] =  sre[24];  // (4,5) conj of (3, 5)
    assign mim_flat[29*MW +: MW] = -sim[24];
    assign mre_flat[30*MW +: MW] = sre[12];   // (5,0) real
    assign mim_flat[30*MW +: MW] = 25'sd0;
    assign mre_flat[31*MW +: MW] = sre[13];   // (5,1) real
    assign mim_flat[31*MW +: MW] = 25'sd0;
    assign mre_flat[32*MW +: MW] = sre[14];   // (5,2) real
    assign mim_flat[32*MW +: MW] = 25'sd0;
    assign mre_flat[33*MW +: MW] = sre[25];   // (5,3) cmul
    assign mim_flat[33*MW +: MW] = sim[25];
    assign mre_flat[34*MW +: MW] =  sre[25];  // (5,4) conj of (5, 3)
    assign mim_flat[34*MW +: MW] = -sim[25];
    assign mre_flat[35*MW +: MW] = sre[15];   // (5,5) real
    assign mim_flat[35*MW +: MW] = 25'sd0;
endmodule
