`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: wino_dsp_mul
// Description:
//   복소수 Winograd element-wise mul 용 단일 DSP48E1 곱셈기 (SIMD packing 없음).
//   p = a * b  (signed), 3-stage pipeline (AREG=BREG=MREG=PREG=1, P=M).
//
//   - a : weight operand (A-port). UW=14-bit signed → 30-bit A 로 sign-extend.
//   - b : activation operand (B-port). VW=16-bit signed → 18-bit B 로 sign-extend.
//   - p : product = a*b (PW-bit slice, P[PW-1:0]). |p| ≤ ~8e6(24b) → PW=32 여유.
//   - en : CEA2/CEB2/CEM/CEP (data-path clock enable). rst : active-high.
//
//   pe_cell.v 의 DSP48E1 attribute/OPMODE(7'b0000101: P=M, Z=0) 를 그대로 사용하되
//   weight reg / SIMD carry 보정 없이 순수 1-곱. iverilog: TB/models/dsp48e1_model.v.
//   ★ Vivado 합성/시뮬에서는 dsp48e1_model.v 제외 (실제 DSP48E1 primitive 사용).
//////////////////////////////////////////////////////////////////////////////////

module wino_dsp_mul #(
    parameter integer AW = 14,    // weight 폭
    parameter integer BW = 16,    // activation 폭
    parameter integer PW = 32     // product 출력 폭 (P 하위 slice)
)(
    input  wire              clk,
    input  wire              rst,    // active-high synchronous
    input  wire              en,     // data-path clock enable
    input  wire signed [AW-1:0] a,   // weight  (A-port)
    input  wire signed [BW-1:0] b,   // activation (B-port)
    output wire signed [PW-1:0] p    // a*b, 3-cycle latency
);

    wire [47:0] P;

    DSP48E1 #(
        .A_INPUT            ("DIRECT"),
        .B_INPUT            ("DIRECT"),
        .USE_DPORT          ("FALSE"),
        .USE_MULT           ("MULTIPLY"),
        .USE_SIMD           ("ONE48"),
        .AUTORESET_PATDET   ("NO_RESET"),
        .MASK               (48'h3fffffffffff),
        .PATTERN            (48'h000000000000),
        .SEL_MASK           ("MASK"),
        .SEL_PATTERN        ("PATTERN"),
        .USE_PATTERN_DETECT ("NO_PATDET"),
        .ACASCREG           (1),
        .ADREG              (0),
        .ALUMODEREG         (1),
        .AREG               (1),
        .BCASCREG           (1),
        .BREG               (1),
        .CARRYINREG         (1),
        .CARRYINSELREG      (1),
        .CREG               (1),
        .DREG               (0),
        .INMODEREG          (1),
        .MREG               (1),
        .OPMODEREG          (1),
        .PREG               (1)
    ) dsp_inst (
        .ACOUT (), .BCOUT (), .CARRYCASCOUT (), .MULTSIGNOUT (), .PCOUT (),
        .OVERFLOW (), .PATTERNBDETECT (), .PATTERNDETECT (), .UNDERFLOW (),
        .CARRYOUT (), .P (P),

        .ACIN (30'b0), .BCIN (18'b0), .CARRYCASCIN (1'b0),
        .MULTSIGNIN (1'b0), .PCIN (48'b0),

        .ALUMODE   (4'b0000),       // Z + (X + Y + CIN)
        .CARRYINSEL(3'b000),
        .CLK       (clk),
        .INMODE    (5'b00000),
        .OPMODE    (7'b0000101),    // X=M[31:0], Y=M[47:32], Z=0 → P = A*B

        .A         ({{(30-AW){a[AW-1]}}, a}),   // sign-extend weight → 30-bit
        .B         ({{(18-BW){b[BW-1]}}, b}),   // sign-extend activation → 18-bit
        .C         (48'b0),
        .CARRYIN   (1'b0),
        .D         (25'b0),

        .CEA1 (1'b0), .CEA2 (en), .CEB1 (1'b0), .CEB2 (en),
        .CEM  (en),   .CEP  (en),
        .CEAD (1'b0), .CEC  (1'b0), .CED (1'b0),
        .CEALUMODE (1'b1), .CECARRYIN (1'b1), .CECTRL (1'b1), .CEINMODE (1'b1),

        .RSTA (rst), .RSTB (rst), .RSTM (rst), .RSTP (rst),
        .RSTCTRL (rst), .RSTALUMODE (rst), .RSTINMODE (rst), .RSTALLCARRYIN (rst),
        .RSTC (1'b0), .RSTD (1'b0)
    );

    assign p = P[PW-1:0];

endmodule
