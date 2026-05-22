`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: pe_cell
// Description:
//   - DSP48E1 1개 + weight 레지스터 2개
//   - reg1: 라운드1용 (oc0,oc1 or oc2,oc3 packing)
//   - reg2: 라운드2용 (oc4,oc5 or oc6,oc7 packing)
//   - sel=0: reg1 → DSP, sel=1: reg2 → DSP
//
//   Packing 식:
//     A_port = W1 × 2^17 + W0  (25bit, Python 오프라인 계산)
//     B_port = X               (18bit signed)
//     P      = A × B = W1×X×2^17 + W0×X
//
//   결과 추출 (-128 없으므로 carry 보정만):
//     psum0 = P[16:0]                          (W0×X)
//     psum1 = sint16(P[32:17]) + [P0<0]        (W1×X, carry 보정만)
//
//   -128 없으므로 overflow 검출 및 -256×X 보정 불필요
//
//   파이프라인: DSP 3사이클 + 출력 레지스터 1사이클 = 총 4사이클
//////////////////////////////////////////////////////////////////////////////////

module pe_cell (
    input  wire        clk,
    input  wire        rst,

    // weight 적재
    input  wire [24:0] packed_a,       // weight_loader에서 공급
    input  wire        weight_load1,   // 1: reg1 갱신
    input  wire        weight_load2,   // 1: reg2 갱신

    // 라운드 선택
    input  wire        sel,            // 0: reg1, 1: reg2

    // pipeline
    input  wire        en,

    // 입력 픽셀
    input  wire signed [7:0] x,

    // 출력
    output reg signed [16:0] psum0,    // W0 × X
    output reg signed [16:0] psum1     // W1 × X
);

    //==========================================================================
    // 1. Weight 레지스터 2개
    //==========================================================================
    reg [24:0] reg1;
    reg [24:0] reg2;

    always @(posedge clk) begin
        if (rst) begin
            reg1 <= 25'd0;
            reg2 <= 25'd0;
        end else begin
            if (weight_load1) reg1 <= packed_a;
            if (weight_load2) reg2 <= packed_a;
        end
    end

    //==========================================================================
    // 2. MUX
    //==========================================================================
    wire [24:0] active_reg = sel ? reg2 : reg1;

    //==========================================================================
    // 3. DSP48E1
    //==========================================================================
    wire [47:0] P;

    DSP48E1 #(
        .USE_MULT           ("MULTIPLY"),
        .USE_SIMD           ("ONE48"),
        .USE_DPORT          ("FALSE"),
        .AREG               (1),
        .BREG               (1),
        .MREG               (1),
        .PREG               (1),
        .ADREG              (0),
        .DREG               (1),
        .CREG               (0),
        .AUTORESET_PATDET   ("NO_RESET"),
        .MASK               (48'h3fffffffffff),
        .PATTERN            (48'h000000000000),
        .SEL_MASK           ("MASK"),
        .SEL_PATTERN        ("PATTERN"),
        .USE_PATTERN_DETECT ("NO_PATDET")
    ) dsp_inst (
        .CLK            (clk),
        .RSTA           (rst),
        .RSTB           (rst),
        .RSTM           (rst),
        .RSTP           (rst),
        .RSTAD          (1'b0),
        .RSTC           (1'b0),
        .RSTD           (1'b0),
        .RSTINMODE      (1'b0),
        .RSTALLCARRYIN  (1'b0),
        .RSTALUMODE     (1'b0),
        .RSTCTRL        (1'b0),

        .CEA1           (1'b0),
        .CEA2           (en),
        .CEB1           (1'b0),
        .CEB2           (en),
        .CEM            (en),
        .CEP            (en),
        .CEAD           (1'b0),
        .CEC            (1'b0),
        .CED            (1'b0),
        .CEINMODE       (1'b0),
        .CEALUMODE      (1'b0),
        .CECARRYIN      (1'b0),
        .CECTRL         (en),

        .A              ({{5{active_reg[24]}}, active_reg}),
        .B              ({{10{x[7]}}, x}),
        .D              (25'b0),
        .C              (48'b0),
        .CARRYIN        (1'b0),
        .OPMODE         (7'b0000101),
        .ALUMODE        (4'b0000),
        .INMODE         (5'b00000),

        .P              (P),
        .CARRYOUT       (),
        .OVERFLOW       (),
        .UNDERFLOW      (),
        .PATTERNDETECT  (),
        .PATTERNBDETECT ()
    );

    //==========================================================================
    // 4. 결과 추출
    //
    // W ∈ [-127, 127] → -128 없음 → overflow 없음
    //
    // psum0 = P[16:0]           → W0×X 단순 슬라이싱
    // psum1 = P[32:17] + [P0<0] → W1×X + carry 보정
    //
    // carry 보정 이유:
    //   P = W1×X×2^17 + W0×X
    //   P[32:17] = W1×X + floor(W0×X / 2^17)
    //   W0×X가 음수면 floor = -1 → +1 보정 필요
    //   → [P0<0] = psum0의 MSB(부호비트)
    //
    // DSP 3사이클 레이턴시 → P와 같은 타이밍에 바로 추출 가능
    // (x 지연 레지스터 불필요, ovf 제거로 단순화)
    //==========================================================================

    wire signed [16:0] p0_raw     = P[16:0];
    wire signed [16:0] p1_slot    = {{1{P[32]}}, P[32:17]};
    wire signed [16:0] carry_corr = {16'd0, p0_raw[16]};  // [P0<0]

    wire signed [16:0] p1_raw = p1_slot + carry_corr;

    // 출력 레지스터
    always @(posedge clk) begin
        if (rst) begin
            psum0 <= 17'sd0;
            psum1 <= 17'sd0;
        end else if (en) begin
            psum0 <= p0_raw;
            psum1 <= p1_raw;
        end
    end

endmodule
