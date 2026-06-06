`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// wino_lane_reduce.v  (자동생성: scripts/weights/winograd_gen.py)
//   1 lane(=1 IC) 의 46 DSP product → 26 position partial (re/im).
//   operand 0..15  = real pos: pre=prod, pim=0.
//   operand 16..   = cmul pos (10×3, Gauss): k1=prod[+0],k2=prod[+1],k3=prod[+2]
//                    pre = k1-k3,  pim = k1+k2.
////////////////////////////////////////////////////////////////////////////////
module wino_lane_reduce #(parameter PW=24, MW=25) (
    input  wire [46*PW-1:0] prod_flat,  // prod i = [i*PW +: PW] (signed)
    output wire [26*MW-1:0] pre_flat,   // partial re, pos k = [k*MW +: MW]
    output wire [26*MW-1:0] pim_flat    // partial im
);
    wire signed [PW-1:0] prod [0:45];
    genvar gi;
    generate for (gi=0; gi<46; gi=gi+1)
        assign prod[gi] = $signed(prod_flat[gi*PW +: PW]);
    endgenerate

    // real positions (operand 0..15)
    assign pre_flat[0*MW +: MW] = prod[0];
    assign pim_flat[0*MW +: MW] = 25'sd0;
    assign pre_flat[1*MW +: MW] = prod[1];
    assign pim_flat[1*MW +: MW] = 25'sd0;
    assign pre_flat[2*MW +: MW] = prod[2];
    assign pim_flat[2*MW +: MW] = 25'sd0;
    assign pre_flat[3*MW +: MW] = prod[3];
    assign pim_flat[3*MW +: MW] = 25'sd0;
    assign pre_flat[4*MW +: MW] = prod[4];
    assign pim_flat[4*MW +: MW] = 25'sd0;
    assign pre_flat[5*MW +: MW] = prod[5];
    assign pim_flat[5*MW +: MW] = 25'sd0;
    assign pre_flat[6*MW +: MW] = prod[6];
    assign pim_flat[6*MW +: MW] = 25'sd0;
    assign pre_flat[7*MW +: MW] = prod[7];
    assign pim_flat[7*MW +: MW] = 25'sd0;
    assign pre_flat[8*MW +: MW] = prod[8];
    assign pim_flat[8*MW +: MW] = 25'sd0;
    assign pre_flat[9*MW +: MW] = prod[9];
    assign pim_flat[9*MW +: MW] = 25'sd0;
    assign pre_flat[10*MW +: MW] = prod[10];
    assign pim_flat[10*MW +: MW] = 25'sd0;
    assign pre_flat[11*MW +: MW] = prod[11];
    assign pim_flat[11*MW +: MW] = 25'sd0;
    assign pre_flat[12*MW +: MW] = prod[12];
    assign pim_flat[12*MW +: MW] = 25'sd0;
    assign pre_flat[13*MW +: MW] = prod[13];
    assign pim_flat[13*MW +: MW] = 25'sd0;
    assign pre_flat[14*MW +: MW] = prod[14];
    assign pim_flat[14*MW +: MW] = 25'sd0;
    assign pre_flat[15*MW +: MW] = prod[15];
    assign pim_flat[15*MW +: MW] = 25'sd0;
    // cmul positions (operand 16.., Gauss)
    assign pre_flat[16*MW +: MW] = prod[16] - prod[18];  // k1-k3  cmul (0, 3)
    assign pim_flat[16*MW +: MW] = prod[16] + prod[17];  // k1+k2
    assign pre_flat[17*MW +: MW] = prod[19] - prod[21];  // k1-k3  cmul (1, 3)
    assign pim_flat[17*MW +: MW] = prod[19] + prod[20];  // k1+k2
    assign pre_flat[18*MW +: MW] = prod[22] - prod[24];  // k1-k3  cmul (2, 3)
    assign pim_flat[18*MW +: MW] = prod[22] + prod[23];  // k1+k2
    assign pre_flat[19*MW +: MW] = prod[25] - prod[27];  // k1-k3  cmul (3, 0)
    assign pim_flat[19*MW +: MW] = prod[25] + prod[26];  // k1+k2
    assign pre_flat[20*MW +: MW] = prod[28] - prod[30];  // k1-k3  cmul (3, 1)
    assign pim_flat[20*MW +: MW] = prod[28] + prod[29];  // k1+k2
    assign pre_flat[21*MW +: MW] = prod[31] - prod[33];  // k1-k3  cmul (3, 2)
    assign pim_flat[21*MW +: MW] = prod[31] + prod[32];  // k1+k2
    assign pre_flat[22*MW +: MW] = prod[34] - prod[36];  // k1-k3  cmul (3, 3)
    assign pim_flat[22*MW +: MW] = prod[34] + prod[35];  // k1+k2
    assign pre_flat[23*MW +: MW] = prod[37] - prod[39];  // k1-k3  cmul (3, 4)
    assign pim_flat[23*MW +: MW] = prod[37] + prod[38];  // k1+k2
    assign pre_flat[24*MW +: MW] = prod[40] - prod[42];  // k1-k3  cmul (3, 5)
    assign pim_flat[24*MW +: MW] = prod[40] + prod[41];  // k1+k2
    assign pre_flat[25*MW +: MW] = prod[43] - prod[45];  // k1-k3  cmul (5, 3)
    assign pim_flat[25*MW +: MW] = prod[43] + prod[44];  // k1+k2
endmodule
