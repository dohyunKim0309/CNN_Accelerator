`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ⚠ DEPRECATED (2026-06-12): wino_mul_array 가 "46-DSP lane 단위 + weight RAM 내장"
//   으로 재구성되어 본 TB 의 옛 인터페이스(w_flat/a_flat/m_*_flat 일체형)와 불일치.
//   회귀 gate 는 engine/full/2clk TB 3종이 대체 (docs/winograd/ 참조). 컴파일 불가.
//////////////////////////////////////////////////////////////////////////////////
// tb_wino_mul_array.v
//   wino_mul_array 단위검증. data/winograd/ma_{w,a}.hex (NT×8IC×46) 를
//   연속 stream (test t: cycle 2t=grp0[IC0-3], 2t+1=grp1[IC4-7]) 으로 주입,
//   m_valid 마다 완성 M 을 data/winograd/ma_{mre,mim}.hex (hw_model) 와 비교.
//   lane L = IC(grp*4+L). en 연속(burst). DSP 3-cycle latency 후 m_valid.
//////////////////////////////////////////////////////////////////////////////////
module tb_wino_mul_array;

    localparam integer NT = 1000;
    localparam integer UW = 12;
    localparam integer VW = 14;
    localparam integer MW = 25;

    reg [UW-1:0] w_mem [0:NT*8*46-1];
    reg [VW-1:0] a_mem [0:NT*8*46-1];
    reg [MW-1:0] mre_exp [0:NT*36-1];
    reg [MW-1:0] mim_exp [0:NT*36-1];

    reg                 clk = 1'b0;
    reg                 rst = 1'b1;
    reg                 en  = 1'b0;
    reg                 grp_in = 1'b0;
    reg  [4*46*UW-1:0]  w_flat;
    reg  [4*46*VW-1:0]  a_flat;
    wire [36*MW-1:0]    m_re_flat;
    wire [36*MW-1:0]    m_im_flat;
    wire                m_valid;

    always #5 clk = ~clk;

    wino_mul_array #(.UW(UW), .VW(VW), .PW(24), .MW(MW)) dut (
        .clk (clk), .rst (rst), .en (en), .grp_in (grp_in),
        .w_flat (w_flat), .a_flat (a_flat),
        .m_re_flat (m_re_flat), .m_im_flat (m_im_flat), .m_valid (m_valid)
    );

    // ---- checker : m_valid 마다 expected[cap] 와 비교 ----
    integer cap = 0;
    integer total_mm = 0;
    integer kk2, mm;
    reg signed [MW-1:0] got_re, got_im, exp_re, exp_im;

    always @(posedge clk) begin
        if (!rst && m_valid) begin
            mm = 0;
            for (kk2 = 0; kk2 < 36; kk2 = kk2 + 1) begin
                got_re = m_re_flat[kk2*MW +: MW];
                got_im = m_im_flat[kk2*MW +: MW];
                exp_re = mre_exp[cap*36 + kk2];
                exp_im = mim_exp[cap*36 + kk2];
                if (got_re !== exp_re || got_im !== exp_im) begin
                    mm = mm + 1;
                    if (total_mm + mm <= 8)
                        $display("  MM test=%0d pos=%0d : got(%0d,%0d) exp(%0d,%0d)",
                                 cap, kk2, got_re, got_im, exp_re, exp_im);
                end
            end
            total_mm = total_mm + mm;
            cap = cap + 1;
        end
    end

    // ---- driver ----
    integer n, t, grp, L, op;
    initial begin
        $readmemh("data/winograd/ma_w.hex",   w_mem);
        $readmemh("data/winograd/ma_a.hex",   a_mem);
        $readmemh("data/winograd/ma_mre.hex", mre_exp);
        $readmemh("data/winograd/ma_mim.hex", mim_exp);

        w_flat = 0; a_flat = 0; grp_in = 0; en = 0;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        en  = 1'b1;

        for (n = 0; n < 2*NT; n = n + 1) begin
            t   = n >> 1;
            grp = n & 1;
            for (L = 0; L < 4; L = L + 1)
                for (op = 0; op < 46; op = op + 1) begin
                    w_flat[(L*46+op)*UW +: UW] = w_mem[t*368 + (grp*4+L)*46 + op];
                    a_flat[(L*46+op)*VW +: VW] = a_mem[t*368 + (grp*4+L)*46 + op];
                end
            grp_in = grp[0];
            @(negedge clk);
        end
        // drain last test's in-flight products: en high, grp_in=0 (no new grp1 → no spurious m_valid)
        grp_in = 1'b0;
        repeat (6) @(negedge clk);
        en = 1'b0;
        repeat (2) @(negedge clk);

        $display("\n==== wino_mul_array : captured %0d/%0d M, %0d mismatches ====",
                 cap, NT, total_mm);
        if (cap == NT && total_mm == 0)
            $display("  *** PASS *** (bit-exact vs hw_model/golden)");
        else
            $display("  *** FAIL ***");
        $finish;
    end

    initial begin
        #5000000;
        $display("[TB] TIMEOUT (cap=%0d)", cap);
        $finish;
    end

endmodule
