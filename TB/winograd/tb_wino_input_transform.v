`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_wino_input_transform.v
//   wino_input_transform (자동생성) 단위검증.
//   data/winograd/it_d.hex (NT×36 INT8)  → DUT → 46 activation operand
//   == data/winograd/it_a.hex (NT×46 INT16, hw_model=golden 산출).
//   순수 조합 → clock 없이 drive + #1 settle + compare.
//////////////////////////////////////////////////////////////////////////////////
module tb_wino_input_transform;

    localparam integer NT = 2000;
    localparam integer DW = 8;
    localparam integer VW = 14;

    reg  [DW-1:0] d_mem [0:NT*36-1];
    reg  [VW-1:0] a_exp [0:NT*46-1];

    reg  [36*DW-1:0] d_flat;
    wire [46*VW-1:0] a_flat;

    wino_input_transform #(.DW(DW), .VW(VW)) dut (
        .d_flat (d_flat),
        .a_flat (a_flat)
    );

    integer t, kk, mm, total_mm;
    reg signed [VW-1:0] got, exp;

    initial begin
        $readmemh("data/winograd/it_d.hex", d_mem);
        $readmemh("data/winograd/it_a.hex", a_exp);
        total_mm = 0;

        for (t = 0; t < NT; t = t + 1) begin
            // pack d_flat : d[k][l] = d_mem[t*36 + (k*6+l)]
            for (kk = 0; kk < 36; kk = kk + 1)
                d_flat[kk*DW +: DW] = d_mem[t*36 + kk];
            #1;  // settle combinational
            mm = 0;
            for (kk = 0; kk < 46; kk = kk + 1) begin
                got = a_flat[kk*VW +: VW];
                exp = a_exp[t*46 + kk];
                if (got !== exp) begin
                    mm = mm + 1;
                    if (total_mm + mm <= 8)
                        $display("  MM t=%0d op=%0d : got=%0d exp=%0d", t, kk, got, exp);
                end
            end
            total_mm = total_mm + mm;
        end

        $display("\n==== wino_input_transform : %0d vectors, %0d mismatches ====",
                 NT, total_mm);
        if (total_mm == 0) $display("  *** PASS *** (bit-exact vs hw_model/golden)");
        else               $display("  *** FAIL ***");
        $finish;
    end

endmodule
