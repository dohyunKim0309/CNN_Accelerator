`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: wino_weight_loader
// Description:
//   PS-writable narrow weight BMG (32-bit, pre-transformed Winograd U operand 1/word)
//   를 system 시작 1회 순차 read 하여 engine 의 wide weight 저장(wmem, 32 entry ×
//   184 operand)에 조립한다.  conv2 의 weight_loader_conv2 와 같은 역할.
//
//   ★ wmem[sel] == 옛 wino_weight_rom[sel] (bit-identical) 가 되도록 operand 순서를
//      맞춤 → mul array 가 보는 weight 가 값·타이밍 모두 ROM 과 동일 → 동작 불변.
//
//   narrow_addr = sel*184 + (lane*46 + i)   (sel=oc*2+grp 0..31, lane 0..3, i 0..45)
//     → 0..5887.  word[UW-1:0] = operand (UW=12 2's-comp).  상위 bit 무시.
//
//   BMG L=2 (regceb tied 1):  acnt@T → wb_addrb@T+1 → wb_doutb@T+3.
//     data-side(조립) counter = LOADING 을 3 cycle 지연(dvalid)시켜 doutb 와 정렬.
//     wb_enb 는 (state==LOADING) 등록값 → 마지막 read(acnt=5887)도 enb=1 일 때
//     addrb 제시되어 pre 에 capture → drain 손실 없음.
//
//   ★ write: per-PE 분할 메모리(engine wmem_op 184개)에 operand 1개씩 narrow write.
//     dvalid 마다 (dentry, dopidx) 의 doutb 를 등록 → engine 이 wm_op 로 해당 PE RAM
//     1개만 enable.  옛 wide assembly(2208-bit)+한방 write 제거 → write broadcast 가
//     {wm_data 12 + wm_op 8 + wm_addr 5} 로 축소 (startup-only, timing slack).
//
//   동작 1회 (loader_start = system 첫 start).  ~5888 + drain cycle.
//////////////////////////////////////////////////////////////////////////////////

module wino_weight_loader #(
    parameter integer UW    = 12,
    parameter integer NOPS  = 184,           // 4 lane × 46 operand / entry
    parameter integer NWORD = 5888           // 32 entry × 184
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             loader_start,    // 1-cyc pulse (system 첫 start)
    output reg              loader_done,      // 1-cyc pulse (조립 완료)

    // narrow weight BMG Port B (read)
    output reg              wb_enb,
    output reg  [12:0]      wb_addrb,         // 0..5887 (depth 8192)
    input  wire [31:0]      wb_doutb,

    // per-PE weight 메모리 write (narrow, operand 1개씩)
    output reg              wm_we,
    output reg  [4:0]       wm_addr,          // entry(sel) 0..31
    output reg  [7:0]       wm_op,            // operand 0..183 (어느 PE RAM)
    output reg  [UW-1:0]    wm_data           // operand 1개 (narrow)
);
    localparam [1:0] IDLE=2'd0, LOADING=2'd1, DRAIN=2'd2, FINISH=2'd3;
    reg [1:0]  state;
    reg [12:0] acnt;        // addr counter 0..5887
    reg [3:0]  drain_cnt;

    //--------------------------------------------------------------------------
    // addr-side: 0..5887 순차, 끝나면 DRAIN (마지막 doutb/write 완료 대기)
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin state<=IDLE; acnt<=13'd0; drain_cnt<=4'd0; end
        else case (state)
            IDLE:    if (loader_start) begin state<=LOADING; acnt<=13'd0; end
            LOADING: if (acnt==NWORD-1) begin state<=DRAIN; drain_cnt<=4'd0; end
                     else acnt<=acnt+13'd1;
            DRAIN:   if (drain_cnt==4'd8) state<=FINISH; else drain_cnt<=drain_cnt+4'd1;
            FINISH:  state<=IDLE;
            default: state<=IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin wb_enb<=1'b0; wb_addrb<=13'd0; end
        else     begin wb_enb<=(state==LOADING); wb_addrb<=acnt; end
    end

    //--------------------------------------------------------------------------
    // data-side: LOADING 을 3 cycle 지연 → wb_doutb valid 와 정렬(dvalid)
    //--------------------------------------------------------------------------
    reg dv0, dv1, dvalid;
    always @(posedge clk) begin
        if (rst) begin dv0<=1'b0; dv1<=1'b0; dvalid<=1'b0; end
        else     begin dv0<=(state==LOADING); dv1<=dv0; dvalid<=dv1; end
    end

    //--------------------------------------------------------------------------
    // narrow write: dvalid 마다 operand 1개를 해당 PE RAM(wm_op)에 직접 기록.
    //   (dentry, dopidx) = 현재 doutb 의 (entry, operand).  옛 wide assembly 제거.
    //   wm_we/addr/op/data 를 dvalid 에 함께 등록(+1) → 셋이 항상 정합.
    //--------------------------------------------------------------------------
    reg [7:0]    dopidx;    // 0..183 (operand within entry)
    reg [4:0]    dentry;    // 0..31  (entry/sel)
    always @(posedge clk) begin
        if (rst) begin
            dopidx<=8'd0; dentry<=5'd0;
            wm_we<=1'b0; wm_addr<=5'd0; wm_op<=8'd0; wm_data<={UW{1'b0}};
        end else begin
            wm_we <= 1'b0;
            if (loader_start) begin dopidx<=8'd0; dentry<=5'd0; end
            if (dvalid) begin
                wm_we   <= 1'b1;
                wm_addr <= dentry;
                wm_op   <= dopidx;
                wm_data <= wb_doutb[UW-1:0];
                if (dopidx==NOPS-1) begin dopidx<=8'd0; dentry<=dentry+5'd1; end
                else dopidx<=dopidx+8'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) loader_done<=1'b0;
        else     loader_done<=(state==FINISH);
    end
endmodule
