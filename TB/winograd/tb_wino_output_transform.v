`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_wino_output_transform.v
//   wino_output_transform (자동생성) 단위검증.
//   data/winograd/ot_{mre,mim}.hex (NT×36 INT32 complex M) → DUT → 16 Y16(real)
//   == data/winograd/ot_y16.hex (NT×16 INT36, hw_model=golden 산출).
//   순수 조합 → clock 없이 drive + #1 settle + compare.
//////////////////////////////////////////////////////////////////////////////////
module tb_wino_output_transform;

    localparam integer NT = 2000;
    localparam integer MW = 25;
    localparam integer YW = 28;

    reg  [MW-1:0] mre_mem [0:NT*36-1];
    reg  [MW-1:0] mim_mem [0:NT*36-1];
    reg  [YW-1:0] y_exp   [0:NT*16-1];

    reg  [36*MW-1:0] mre_flat;
    reg  [36*MW-1:0] mim_flat;
    wire [16*YW-1:0] y16_flat;

    wino_output_transform #(.MW(MW), .YW(YW)) dut (
        .mre_flat (mre_flat),
        .mim_flat (mim_flat),
        .y16_flat (y16_flat)
    );

    integer t, kk, mm, total_mm;
    reg signed [YW-1:0] got, exp;

    initial begin
        $readmemh("data/winograd/ot_mre.hex", mre_mem);
        $readmemh("data/winograd/ot_mim.hex", mim_mem);
        $readmemh("data/winograd/ot_y16.hex", y_exp);
        total_mm = 0;

        for (t = 0; t < NT; t = t + 1) begin
            for (kk = 0; kk < 36; kk = kk + 1) begin
                mre_flat[kk*MW +: MW] = mre_mem[t*36 + kk];
                mim_flat[kk*MW +: MW] = mim_mem[t*36 + kk];
            end
            #1;
            mm = 0;
            for (kk = 0; kk < 16; kk = kk + 1) begin
                got = y16_flat[kk*YW +: YW];
                exp = y_exp[t*16 + kk];
                if (got !== exp) begin
                    mm = mm + 1;
                    if (total_mm + mm <= 8)
                        $display("  MM t=%0d y=%0d : got=%0d exp=%0d", t, kk, got, exp);
                end
            end
            total_mm = total_mm + mm;
        end

        $display("\n==== wino_output_transform : %0d vectors, %0d mismatches ====",
                 NT, total_mm);
        if (total_mm == 0) $display("  *** PASS *** (bit-exact vs hw_model/golden)");
        else               $display("  *** FAIL ***");
        $finish;
    end

endmodule
