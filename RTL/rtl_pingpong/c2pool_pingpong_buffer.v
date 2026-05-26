`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: c2pool_pingpong_buffer
// Description:
//   Conv2 output activation -> Maxpool input activation ping-pong buffer
//
//   Purpose:
//     - Conv2 writes output feature map into one bank.
//     - Maxpool reads output feature map from the valid read bank.
//     - Two banks are alternated using ping-pong control.
//
//   Data format:
//     - DATA_WIDTH = 128
//     - 1 word = 16 output channels x 8-bit
//
//   Address format:
//     - Physical address:
//         addr[10]  = bank select
//         addr[9:0] = local address, 0~575 valid
//
//     - Conv2 write address:
//         conv2_waddr = {conv2_output_bank_sel, conv2_local_waddr}
//
//     - Maxpool read address:
//         internal read address = {read_bank_sel, maxpool_raddr}
//
//   Important:
//     - This module models BMG-like registered read latency L=2.
//     - stage 1: memory read register
//     - stage 2: output register
//
//   Connection:
//     Conv2 side:
//       conv2_we / conv2_waddr / conv2_wdata / conv2_wdone
//
//     Maxpool side:
//       maxpool_re / maxpool_raddr / maxpool_rdata / maxpool_rdone
//
//   Handshake:
//     conv2_wdone    -> prior_wdone_to_maxpool
//     maxpool_rdone  -> frees current read bank
//
//   Typical use:
//     conv2_engine.c2pool_we   -> conv2_we
//     conv2_engine.c2pool_addr -> conv2_waddr
//     conv2_engine.c2pool_din  -> conv2_wdata
//     conv2_engine.wdone       -> conv2_wdone
//
//     maxpool_rdone            -> conv2_engine.succ_rdone
//////////////////////////////////////////////////////////////////////////////////

module c2pool_pingpong_buffer #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 11,
    parameter LOCAL_ADDR_WIDTH = 10,
    parameter DEPTH = 2048
)(
    input  wire                         clk,
    input  wire                         rst,    // active-high synchronous reset

    //==========================================================================
    // Conv2 write side
    //==========================================================================
    input  wire                         conv2_we,
    input  wire [ADDR_WIDTH-1:0]        conv2_waddr,  // {bank, local_addr[9:0]}
    input  wire [DATA_WIDTH-1:0]        conv2_wdata,
    input  wire                         conv2_wdone,

    output wire                         conv2_can_write,

    //==========================================================================
    // Maxpool read side
    //
    // Maxpool only needs to generate local address 0~575.
    // This buffer internally attaches read_bank_sel.
    //==========================================================================
    input  wire                         maxpool_re,
    input  wire [LOCAL_ADDR_WIDTH-1:0]  maxpool_raddr,
    output reg  [DATA_WIDTH-1:0]        maxpool_rdata,
    input  wire                         maxpool_rdone,

    //==========================================================================
    // Handshake to Maxpool FSM
    //
    // Connect this to Maxpool's prior_wdone or start/data_ready input.
    // 1-cycle pulse when Conv2 completed writing one full bank.
    //==========================================================================
    output reg                          prior_wdone_to_maxpool,

    //==========================================================================
    // Debug / status
    //==========================================================================
    output wire                         maxpool_read_bank_sel,
    output wire [1:0]                   bank_valid
);

    //==========================================================================
    // 1. Memory
    //
    //   Total address space:
    //     bank 0: 0    ~ 1023
    //     bank 1: 1024 ~ 2047
    //
    //   Actual valid region:
    //     each bank uses local address 0~575
    //
    //   address:
    //     {bank, local_addr[9:0]}
    //==========================================================================
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //==========================================================================
    // 2. Bank control
    //==========================================================================
    reg       read_bank_sel;
    reg [1:0] valid_reg;

    assign maxpool_read_bank_sel = read_bank_sel;
    assign bank_valid            = valid_reg;

    wire conv2_write_bank_sel;
    assign conv2_write_bank_sel = conv2_waddr[ADDR_WIDTH-1];

    // Conv2가 현재 쓰려는 bank가 비어 있을 때만 write 허용
    assign conv2_can_write = (valid_reg[conv2_write_bank_sel] == 1'b0);

    // Maxpool physical read address
    wire [ADDR_WIDTH-1:0] maxpool_phys_raddr;
    assign maxpool_phys_raddr = {read_bank_sel, maxpool_raddr};

    // 현재 read bank에 유효 데이터가 있을 때만 Maxpool read 허용
    wire maxpool_can_read;
    assign maxpool_can_read = valid_reg[read_bank_sel];

    //==========================================================================
    // 3. Conv2 write
    //
    //   Conv2 FSM에서도 after_diff로 overflow를 막고 있지만,
    //   여기서도 conv2_can_write를 걸어서 잘못된 overwrite를 방지.
    //==========================================================================
    always @(posedge clk) begin
        if (conv2_we && conv2_can_write) begin
            mem[conv2_waddr] <= conv2_wdata;
        end
    end

    //==========================================================================
    // 4. Maxpool read path, BMG-like L=2
    //
    //   cycle N:
    //     maxpool_re    = 1
    //     maxpool_raddr = A
    //
    //   cycle N+1:
    //     mem[{read_bank_sel, A}] -> read_data_stage
    //
    //   cycle N+2:
    //     maxpool_rdata valid
    //==========================================================================
    reg [DATA_WIDTH-1:0] read_data_stage;
    reg                  re_d1;

    always @(posedge clk) begin
        if (rst) begin
            read_data_stage <= {DATA_WIDTH{1'b0}};
            maxpool_rdata   <= {DATA_WIDTH{1'b0}};
            re_d1           <= 1'b0;
        end else begin
            // stage 1: memory read
            if (maxpool_re && maxpool_can_read) begin
                read_data_stage <= mem[maxpool_phys_raddr];
            end

            // delay enable by 1 cycle
            re_d1 <= maxpool_re && maxpool_can_read;

            // stage 2: output register
            if (re_d1) begin
                maxpool_rdata <= read_data_stage;
            end
        end
    end

    //==========================================================================
    // 5. Bank valid next-state logic
    //
    //   conv2_wdone:
    //     Conv2가 방금 쓴 bank becomes valid.
    //
    //   maxpool_rdone:
    //     Maxpool이 방금 읽은 bank becomes empty.
    //
    //   If both happen in the same cycle, both updates are reflected.
    //==========================================================================
    reg [1:0] valid_next;

    always @(*) begin
        valid_next = valid_reg;

        // Maxpool finished reading current read bank
        if (maxpool_rdone) begin
            valid_next[read_bank_sel] = 1'b0;
        end

        // Conv2 finished writing current write bank
        if (conv2_wdone && conv2_can_write) begin
            valid_next[conv2_write_bank_sel] = 1'b1;
        end
    end

    //==========================================================================
    // 6. Bank select toggle + handshake pulse generation
    //
    //   prior_wdone_to_maxpool:
    //     Maxpool FSM에게 "읽을 bank 하나 준비됨"을 알려주는 1-cycle pulse.
    //
    //   read_bank_sel:
    //     Maxpool이 한 bank를 다 읽으면 다음 bank로 toggle.
    //
    //   주의:
    //     Conv2의 write bank toggle은 conv2_fsm 내부 output_bank_sel이 담당함.
    //     따라서 이 buffer는 write_bank_sel을 따로 toggle하지 않음.
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            read_bank_sel           <= 1'b0;
            valid_reg               <= 2'b00;
            prior_wdone_to_maxpool  <= 1'b0;
        end else begin
            valid_reg              <= valid_next;
            prior_wdone_to_maxpool <= 1'b0;

            // Conv2 completed one full output bank
            if (conv2_wdone && conv2_can_write) begin
                prior_wdone_to_maxpool <= 1'b1;
            end

            // Maxpool completed reading one full bank
            if (maxpool_rdone) begin
                read_bank_sel <= ~read_bank_sel;
            end
        end
    end

endmodule