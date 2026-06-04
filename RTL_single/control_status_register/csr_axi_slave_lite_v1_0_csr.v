
`timescale 1 ns / 1 ps

//////////////////////////////////////////////////////////////////////////////////
// csr_axi_slave_lite_v1_0_csr — Single-image CNN Accelerator CSR (AXI4-Lite)
//
//   Register map (C_S_AXI_ADDR_WIDTH=4 → 4 words):
//     0x00 CTRL   (R/W) : [0] enable  (level)
//                         [1] start   (write-1 → 1-cycle pulse, auto-clear)
//     0x04 STATUS  (R)  : [0]   done      (img_done latch)
//                         [4:1] result    (img_done 시 latch)
//     0x08 TIMER_LO (R) : timer[31:0]
//     0x0C TIMER_HI (R) : {16'b0, timer[47:32]}
//
//   PL(cnn_accelerator) 인터페이스:
//     out : enable, start
//     in  : result[3:0], img_done
//
//   Multi-image 대비 제거 항목:
//     - img_ready, input_consumed 포트
//     - ctrl_img_ready 레지스터
//     - inflight 카운터, can_load 신호
//     - img_cnt 카운터 (단일 이미지이므로 불필요)
//     - done_latch 조건을 img_cnt==10000 → img_done pulse로 변경
//////////////////////////////////////////////////////////////////////////////////

	module csr_axi_slave_lite_v1_0_csr #
	(
		parameter integer C_S_AXI_DATA_WIDTH	= 32,
		parameter integer C_S_AXI_ADDR_WIDTH	= 4
	)
	(
		// ===== PL (cnn_accelerator) 인터페이스 =====
		output wire        enable,
		output wire        start,
		input  wire [3:0]  result,
		input  wire        img_done,

		input wire  S_AXI_ACLK,
		input wire  S_AXI_ARESETN,
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
		input wire [2 : 0] S_AXI_AWPROT,
		input wire  S_AXI_AWVALID,
		output wire  S_AXI_AWREADY,
		input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
		input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
		input wire  S_AXI_WVALID,
		output wire  S_AXI_WREADY,
		output wire [1 : 0] S_AXI_BRESP,
		output wire  S_AXI_BVALID,
		input wire  S_AXI_BREADY,
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
		input wire [2 : 0] S_AXI_ARPROT,
		input wire  S_AXI_ARVALID,
		output wire  S_AXI_ARREADY,
		output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
		output wire [1 : 0] S_AXI_RRESP,
		output wire  S_AXI_RVALID,
		input wire  S_AXI_RREADY
	);

	// AXI4LITE signals
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_awaddr;
	reg  	axi_awready;
	reg  	axi_wready;
	reg [1 : 0] 	axi_bresp;
	reg  	axi_bvalid;
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_araddr;
	reg  	axi_arready;
	reg [1 : 0] 	axi_rresp;
	reg  	axi_rvalid;

	localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
	localparam integer OPT_MEM_ADDR_BITS = 1;

	// Register select index
	localparam [1:0] REG_CTRL = 2'h0,
	                 REG_STAT = 2'h1,
	                 REG_TLO  = 2'h2,
	                 REG_THI  = 2'h3;

	// I/O Connections assignments
	assign S_AXI_AWREADY	= axi_awready;
	assign S_AXI_WREADY	= axi_wready;
	assign S_AXI_BRESP	= axi_bresp;
	assign S_AXI_BVALID	= axi_bvalid;
	assign S_AXI_ARREADY	= axi_arready;
	assign S_AXI_RRESP	= axi_rresp;
	assign S_AXI_RVALID	= axi_rvalid;

	reg [1:0] state_write;
	reg [1:0] state_read;
	localparam Idle = 2'b00, Raddr = 2'b10, Rdata = 2'b11, Waddr = 2'b10, Wdata = 2'b11;

	// ============================================================================
	// AXI Write 채널 FSM
	// ============================================================================
	always @(posedge S_AXI_ACLK)
	  begin
	     if (S_AXI_ARESETN == 1'b0)
	       begin
	         axi_awready <= 0;
	         axi_wready <= 0;
	         axi_bvalid <= 0;
	         axi_bresp <= 0;
	         axi_awaddr <= 0;
	         state_write <= Idle;
	       end
	     else
	       begin
	         case(state_write)
	           Idle:
	             begin
	               if(S_AXI_ARESETN == 1'b1)
	                 begin
	                   axi_awready <= 1'b1;
	                   axi_wready <= 1'b1;
	                   state_write <= Waddr;
	                 end
	               else state_write <= state_write;
	             end
	           Waddr:
	             begin
	               if (S_AXI_AWVALID && S_AXI_AWREADY)
	                  begin
	                    axi_awaddr <= S_AXI_AWADDR;
	                    if(S_AXI_WVALID)
	                      begin
	                        axi_awready <= 1'b1;
	                        state_write <= Waddr;
	                        axi_bvalid <= 1'b1;
	                      end
	                    else
	                      begin
	                        axi_awready <= 1'b0;
	                        state_write <= Wdata;
	                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                      end
	                  end
	               else
	                  begin
	                    state_write <= state_write;
	                    if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                   end
	             end
	          Wdata:
	             begin
	               if (S_AXI_WVALID)
	                 begin
	                   state_write <= Waddr;
	                   axi_bvalid <= 1'b1;
	                   axi_awready <= 1'b1;
	                 end
	                else
	                 begin
	                   state_write <= state_write;
	                   if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                 end
	             end
	          endcase
	        end
	      end

	// ============================================================================
	// Write address index
	// ============================================================================
	wire [OPT_MEM_ADDR_BITS:0] wr_index =
	       (S_AXI_AWVALID) ? S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]
	                       : axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];
	wire wr_en = S_AXI_WVALID;

	// ============================================================================
	// CTRL register : enable(level), start(1-cycle pulse)
	// ============================================================================
	reg ctrl_enable;
	reg ctrl_start;

	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) begin
	        ctrl_enable <= 1'b0;
	        ctrl_start  <= 1'b0;
	    end else begin
	        ctrl_start <= 1'b0;   // 매 cycle auto-clear (1-cycle pulse 보장)
	        if (wr_en && (wr_index == REG_CTRL)) begin
	            ctrl_enable <= S_AXI_WDATA[0];   // level
	            ctrl_start  <= S_AXI_WDATA[1];   // pulse
	        end
	    end
	end

	assign enable = ctrl_enable;
	assign start  = ctrl_start;

	// ============================================================================
	// Status latch
	// ============================================================================
	// done : img_done pulse 수신 시 latch (단일 이미지 완료)
	reg done_latch;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) done_latch <= 1'b0;
	    else if (img_done)  done_latch <= 1'b1;
	end

	// result : img_done 시 latch
	reg [3:0] result_latch;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) result_latch <= 4'd0;
	    else if (img_done)  result_latch <= result;
	end

	// timer : start pulse 부터 done 까지 free-running 48-bit
	reg [47:0] timer;
	reg        timer_run;
	always @(posedge S_AXI_ACLK) begin
	    if (!S_AXI_ARESETN) begin
	        timer     <= 48'd0;
	        timer_run <= 1'b0;
	    end else begin
	        if (ctrl_start)               timer_run <= 1'b1;
	        if (timer_run && !done_latch) timer     <= timer + 48'd1;
	    end
	end

	// ============================================================================
	// AXI Read 채널 FSM
	// ============================================================================
	always @(posedge S_AXI_ACLK)
	  begin
	    if (S_AXI_ARESETN == 1'b0)
	      begin
	         axi_arready <= 1'b0;
	         axi_rvalid <= 1'b0;
	         axi_rresp <= 1'b0;
	         state_read <= Idle;
	      end
	    else
	      begin
	        case(state_read)
	          Idle:
	            begin
	              if (S_AXI_ARESETN == 1'b1)
	                begin
	                  state_read <= Raddr;
	                  axi_arready <= 1'b1;
	                end
	              else state_read <= state_read;
	            end
	          Raddr:
	            begin
	              if (S_AXI_ARVALID && S_AXI_ARREADY)
	                begin
	                  state_read <= Rdata;
	                  axi_araddr <= S_AXI_ARADDR;
	                  axi_rvalid <= 1'b1;
	                  axi_arready <= 1'b0;
	                end
	              else state_read <= state_read;
	            end
	          Rdata:
	            begin
	              if (S_AXI_RVALID && S_AXI_RREADY)
	                begin
	                  axi_rvalid <= 1'b0;
	                  axi_arready <= 1'b1;
	                  state_read <= Raddr;
	                end
	              else state_read <= state_read;
	            end
	         endcase
	        end
	      end

	// ============================================================================
	// Read data mux
	// ============================================================================
	wire [OPT_MEM_ADDR_BITS:0] rd_index =
	       axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];

	wire [31:0] ctrl_rb = {30'd0, ctrl_start, ctrl_enable};
	wire [31:0] status  = {27'd0, result_latch, done_latch};

	assign S_AXI_RDATA =
	       (rd_index == REG_CTRL) ? ctrl_rb               :
	       (rd_index == REG_STAT) ? status                :
	       (rd_index == REG_TLO ) ? timer[31:0]           :
	       (rd_index == REG_THI ) ? {16'd0, timer[47:32]} : 32'd0;

	endmodule
