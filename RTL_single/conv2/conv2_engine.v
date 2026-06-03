`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv2_engine (single image)
// Description:
//   Conv2 top-level — single image 전용 (ping-pong bank / 4-way handshake 제거)
//
//   원본(conv2_engine.v) 대비 변경점:
//     - rdone / succ_rdone 포트 제거
//     - c1c2_addr: 10-bit (bank bit 제거, {row_cnt, col_cnt})
//     - c2pool_addr: 10-bit (bank bit 제거, c2pool_write_addr)
//     - wdone: 마지막 c2pool write cycle (write_addr==575 && we=1) 다음 1-cycle pulse
//     - 고정 bank 0 (input_bank_sel / output_bank_sel 제거)
//
//   인터페이스:
//     start       : 1-cycle pulse → weight 적재 시작
//     prior_wdone : 1-cycle pulse → 이미지 처리 시작
//     wdone       : 1-cycle pulse → 이미지 처리 완료
//////////////////////////////////////////////////////////////////////////////////

module conv2_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    // Conv2 weight BRAM Port A (PS write)
    input  wire         c2w_ena,
    input  wire [3:0]   c2w_wea,
    input  wire [9:0]   c2w_addra,
    input  wire [31:0]  c2w_dina,

    // c1c2 BRAM Port B (read, L=2, 11-bit addr — bank=0 고정)
    output wire         c1c2_re,
    output wire [10:0]  c1c2_addr,
    input  wire [63:0]  c1c2_dout,

    // c2pool BRAM Port A (write, 11-bit addr — bank=0 고정)
    output wire         c2pool_we,
    output wire [10:0]  c2pool_addr,
    output wire [127:0] c2pool_din,

    // Handshake (simplified)
    input  wire         prior_wdone,
    output wire         wdone
);

    //==========================================================================
    // FSM 신호
    //==========================================================================
    wire [1:0]  fsm_sel;
    wire [1:0]  fsm_col_sel;
    wire        fsm_shift_en;
    wire        fsm_pe_en;
    wire [4:0]  fsm_row_cnt;
    wire [4:0]  fsm_col_cnt;
    wire [9:0]  fsm_output_pixel_cnt;
    wire        loader_start;
    wire        loader_done;

    // weight loader → PE
    wire        c2w_enb;
    wire [9:0]  c2w_addrb;
    wire [31:0] c2w_doutb;
    wire [7:0]  wl_pe_id;
    wire [1:0]  wl_slot_id;
    wire [24:0] wl_packed_w;
    wire        wl_pe_load_en;

    //==========================================================================
    // 1. FSM
    //==========================================================================
    conv2_fsm fsm_inst (
        .clk              (clk),
        .rst              (rst),
        .start            (start),

        .loader_start     (loader_start),
        .loader_done      (loader_done),

        .prior_wdone      (prior_wdone),

        .sel              (fsm_sel),
        .col_sel          (fsm_col_sel),
        .shift_en         (fsm_shift_en),
        .pe_en            (fsm_pe_en),

        .row_cnt          (fsm_row_cnt),
        .col_cnt          (fsm_col_cnt),
        .output_pixel_cnt (fsm_output_pixel_cnt)
    );

    //==========================================================================
    // 2. Weight loader
    //==========================================================================
    weight_loader_conv2 wl_inst (
        .clk          (clk),
        .rst          (rst),
        .loader_start (loader_start),
        .loader_done  (loader_done),
        .c2w_enb      (c2w_enb),
        .c2w_addrb    (c2w_addrb),
        .c2w_doutb    (c2w_doutb),
        .pe_id        (wl_pe_id),
        .slot_id      (wl_slot_id),
        .packed_w     (wl_packed_w),
        .pe_load_en   (wl_pe_load_en)
    );

    //==========================================================================
    // 3. Conv2 weight BRAM
    //==========================================================================
    conv2_weight_bram c2w_bmg_inst (
        .clka  (clk), .ena (c2w_ena), .wea (c2w_wea),
        .addra (c2w_addra), .dina (c2w_dina),

        .clkb  (clk), .enb (c2w_enb),
        .addrb (c2w_addrb), .doutb (c2w_doutb),
        .regceb(1'b1)
    );

    //==========================================================================
    // 4. c1c2 BRAM read (10-bit addr: {row_cnt, col_cnt})
    //==========================================================================
    assign c1c2_re   = fsm_shift_en;
    assign c1c2_addr = {1'b0, fsm_row_cnt, fsm_col_cnt};  // bank=0 고정

    //==========================================================================
    // 5. PE load enable decoder
    //==========================================================================
    reg [191:0] pe_load_en_dec;
    always @(*) begin
        pe_load_en_dec = 192'd0;
        if (wl_pe_load_en) pe_load_en_dec[wl_pe_id] = 1'b1;
    end

    //==========================================================================
    // 6. Line buffer + window register (per IC, 8 instance)
    //==========================================================================
    wire signed [7:0] win_k [0:7][0:8];

    genvar ic_g, kh_g, op_g, oc_g;
    generate
        for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_per_ic
            wire [7:0] bram_byte = c1c2_dout[ic_g*8 +: 8];
            wire [7:0] lb1_out;
            wire [7:0] lb2_out;

            line_buffer #(.WIDTH(8), .DEPTH(25)) lb1_inst (
                .clk(clk), .rst(rst), .en(fsm_shift_en),
                .din(bram_byte), .dout(lb1_out)
            );
            line_buffer #(.WIDTH(8), .DEPTH(25)) lb2_inst (
                .clk(clk), .rst(rst), .en(fsm_shift_en),
                .din(lb1_out), .dout(lb2_out)
            );
            window_register #(.WIDTH(8)) win_inst (
                .clk(clk), .rst(rst), .en(fsm_shift_en),
                .row2_in(bram_byte), .row1_in(lb1_out), .row0_in(lb2_out),
                .k0(win_k[ic_g][0]), .k1(win_k[ic_g][1]), .k2(win_k[ic_g][2]),
                .k3(win_k[ic_g][3]), .k4(win_k[ic_g][4]), .k5(win_k[ic_g][5]),
                .k6(win_k[ic_g][6]), .k7(win_k[ic_g][7]), .k8(win_k[ic_g][8])
            );
        end
    endgenerate

    //==========================================================================
    // 7. col_sel mux
    //==========================================================================
    wire signed [7:0] pe_x [0:2][0:7];
    generate
        for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_mux_kh
            for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_mux_ic
                assign pe_x[kh_g][ic_g] =
                    (fsm_col_sel == 2'd0) ? win_k[ic_g][kh_g*3 + 0] :
                    (fsm_col_sel == 2'd1) ? win_k[ic_g][kh_g*3 + 1] :
                                            win_k[ic_g][kh_g*3 + 2];
            end
        end
    endgenerate

    //==========================================================================
    // 8. PE array (192)
    //==========================================================================
    wire signed [16:0] pe_mul0 [0:7][0:7][0:2];
    wire signed [16:0] pe_mul1 [0:7][0:7][0:2];

    generate
        for (op_g = 0; op_g < 8; op_g = op_g + 1) begin : gen_pe_op
            for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_pe_ic
                for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_pe_kh
                    pe_cell #(.DEPTH(3)) pe_inst (
                        .clk(clk), .rst(rst),
                        .packed_w(wl_packed_w),
                        .load_idx(wl_slot_id),
                        .load_en(pe_load_en_dec[(op_g*8 + ic_g)*3 + kh_g]),
                        .sel(fsm_sel),
                        .en(fsm_pe_en),
                        .x(pe_x[kh_g][ic_g]),
                        .mul0(pe_mul0[op_g][ic_g][kh_g]),
                        .mul1(pe_mul1[op_g][ic_g][kh_g])
                    );
                end
            end
        end
    endgenerate

    //==========================================================================
    // 9. Delay pipeline
    //==========================================================================
    reg [1:0] sel_pipe   [0:8];
    reg       pe_en_pipe [0:8];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 9; i = i + 1) begin
                sel_pipe[i]   <= 2'd0;
                pe_en_pipe[i] <= 1'b0;
            end
        end else begin
            sel_pipe[0]   <= fsm_sel;
            pe_en_pipe[0] <= fsm_pe_en;
            for (i = 1; i < 9; i = i + 1) begin
                sel_pipe[i]   <= sel_pipe[i-1];
                pe_en_pipe[i] <= pe_en_pipe[i-1];
            end
        end
    end

    wire adder_en     = pe_en_pipe[3] | pe_en_pipe[4] | pe_en_pipe[5]
                      | pe_en_pipe[6] | pe_en_pipe[7];
    wire kcol_en      = pe_en_pipe[8];
    wire [1:0] kcol_kw_phase = sel_pipe[8];

    //==========================================================================
    // 10. krow_ic_adder_tree (16 instance)
    //==========================================================================
    wire signed [21:0] adder_out [0:15];

    generate
        for (oc_g = 0; oc_g < 16; oc_g = oc_g + 1) begin : gen_adder
            wire [24*17-1:0] adder_in_flat;
            for (kh_g = 0; kh_g < 3; kh_g = kh_g + 1) begin : gen_adder_kh
                for (ic_g = 0; ic_g < 8; ic_g = ic_g + 1) begin : gen_adder_ic
                    if (oc_g < 8) begin : gen_low
                        assign adder_in_flat[(kh_g*8 + ic_g)*17 +: 17] =
                            pe_mul0[oc_g][ic_g][kh_g];
                    end else begin : gen_high
                        assign adder_in_flat[(kh_g*8 + ic_g)*17 +: 17] =
                            pe_mul1[oc_g - 8][ic_g][kh_g];
                    end
                end
            end
            krow_ic_adder_tree adder_inst (
                .clk(clk), .rst(rst), .en(adder_en),
                .in_flat(adder_in_flat), .sum(adder_out[oc_g])
            );
        end
    endgenerate

    //==========================================================================
    // 11. kcol_accumulator (16 instance)
    //==========================================================================
    wire signed [23:0] kcol_out       [0:15];
    wire               kcol_out_valid [0:15];

    generate
        for (oc_g = 0; oc_g < 16; oc_g = oc_g + 1) begin : gen_kcol
            kcol_accumulator kacc_inst (
                .clk(clk), .rst(rst), .en(kcol_en),
                .in(adder_out[oc_g]),
                .kw_phase(kcol_kw_phase),
                .out(kcol_out[oc_g]),
                .out_valid(kcol_out_valid[oc_g])
            );
        end
    endgenerate

    //==========================================================================
    // 12. truncate_relu (N=16)
    //==========================================================================
    wire [16*24-1:0] tr_sum_flat;
    wire [16*8-1:0]  tr_out_flat;

    generate
        for (oc_g = 0; oc_g < 16; oc_g = oc_g + 1) begin : gen_tr_pack
            assign tr_sum_flat[oc_g*24 +: 24] = kcol_out[oc_g];
        end
    endgenerate

    truncate_relu #(.N(16)) tr_inst (
        .clk(clk), .rst(rst),
        .en(kcol_out_valid[0]),
        .sum_flat(tr_sum_flat),
        .out_flat(tr_out_flat)
    );

    //==========================================================================
    // 13. c2pool write (10-bit addr, no bank)
    //==========================================================================
    reg        c2pool_we_reg;
    reg [9:0]  c2pool_write_addr;
    reg [9:0]  opc_d1;

    always @(posedge clk) begin
        if (rst) c2pool_we_reg <= 1'b0;
        else     c2pool_we_reg <= kcol_out_valid[0];
    end

    always @(posedge clk) begin
        if (rst) opc_d1 <= 10'd0;
        else     opc_d1 <= fsm_output_pixel_cnt;
    end

    wire opc_reset_event = (opc_d1 != 10'd0) && (fsm_output_pixel_cnt == 10'd0);

    always @(posedge clk) begin
        if (rst)                  c2pool_write_addr <= 10'd0;
        else if (opc_reset_event) c2pool_write_addr <= 10'd0;
        else if (c2pool_we_reg)   c2pool_write_addr <= c2pool_write_addr + 10'd1;
    end

    assign c2pool_we   = c2pool_we_reg;
    assign c2pool_addr = {1'b0, c2pool_write_addr};  // bank=0 고정
    assign c2pool_din  = tr_out_flat;

    //==========================================================================
    // 14. wdone pulse (마지막 c2pool write 다음 cycle)
    //==========================================================================
    wire wdone_event = c2pool_we_reg && (c2pool_write_addr == 10'd575);

    reg wdone_reg;
    always @(posedge clk) begin
        if (rst) wdone_reg <= 1'b0;
        else     wdone_reg <= wdone_event;
    end

    assign wdone = wdone_reg;

endmodule
