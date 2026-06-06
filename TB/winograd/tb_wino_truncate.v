`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_wino_truncate.v
//   wino_truncate 단위검증 (N=1). data/winograd/tr_y16.hex → out == tr_out.hex
//   (= clip(Y16>>>14, 0, 127), relu+sat). 1-cycle 등록 latency 정렬.
//////////////////////////////////////////////////////////////////////////////////
module tb_wino_truncate;
    localparam integer NT = 4000;
    localparam integer YW = 28;

    reg [YW-1:0] y16_mem [0:NT-1];
    reg [7:0]    out_mem [0:NT-1];

    reg          clk = 0, rst = 1, en = 0;
    reg  [YW-1:0] y16;
    wire [7:0]    outp;

    always #5 clk = ~clk;

    wino_truncate #(.N(1), .YW(YW), .SHIFT(14)) dut (
        .clk(clk), .rst(rst), .en(en), .y16_flat(y16), .out_flat(outp)
    );

    integer t, total_mm;
    reg [7:0] got, exp;

    initial begin
        $readmemh("data/winograd/tr_y16.hex", y16_mem);
        $readmemh("data/winograd/tr_out.hex", out_mem);
        total_mm = 0;
        y16 = 0; en = 0;
        repeat (4) @(negedge clk);
        rst = 0; en = 1;

        for (t = 0; t < NT; t = t + 1) begin
            y16 = y16_mem[t];
            @(negedge clk);             // 사이 posedge 에서 out<=f(y16) → 이 시점 outp=f(Y[t])
            got = outp;
            exp = out_mem[t];
            if (got !== exp) begin
                total_mm = total_mm + 1;
                if (total_mm <= 8)
                    $display("  MM t=%0d : y16=%0d got=%0d exp=%0d",
                             t, $signed(y16_mem[t]), got, exp);
            end
        end

        $display("\n==== wino_truncate : %0d vectors, %0d mismatches ====", NT, total_mm);
        if (total_mm == 0) $display("  *** PASS ***");
        else               $display("  *** FAIL ***");
        $finish;
    end
endmodule
