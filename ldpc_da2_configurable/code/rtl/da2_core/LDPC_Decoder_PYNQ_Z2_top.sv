// PYNQ-Z2 board wrapper for the unchanged LDPC_Decoder core.
//
// The Zynq processing system accesses this block through AXI4-Lite. Software
// writes 1152 five-bit samples into input_mem, starts one frame, then reads
// back 1152 hard-decision bits in reference codeword order, LSB first in each
// AXI output word. The controller reproduces Decoder_tb.v timing.
//
// AXI register map (byte offsets):
//   0x00 CONTROL    W bit 0: start one frame (ignored while busy)
//   0x04 STATUS     R bit 0: busy, bit 1: done, bit 2: output_valid,
//                         bit 3: core f_id, bit 4: timeout,
//                         bits 31:16: completed frame count
//   0x08 INPUT_ADDR R/W auto-incrementing input sample index (0..1151)
//   0x0c INPUT_DATA W lower five bits; stores sample and increments INPUT_ADDR
//   0x10 OUTPUT_ADDR R/W codeword chunk index (0..31)
//   0x14 OUTPUT_LO   R codeword bits [chunk*36 +: 32], LSB first
//   0x18 OUTPUT_HI   R next four codeword bits in bits [3:0]
//   0x1c CORE_DEBUG R relay[5:0]
//   0x20 OUTPUT_FORMAT R 0x434f4431 ("COD1": ordered codeword output)
//
// Decoder_tb discards its first two completed frames. STATUS.output_valid uses
// the same warm-up rule and becomes one from the third completed frame onward.

module LDPC_Decoder_PYNQ_Z2_top #(
  parameter integer L = 32,
  parameter integer ADDR_WIDTH = 5,
  parameter integer MESSAGE_WIDTH = 5,
  parameter integer K = 6,
  parameter integer CNU_DATA_IN_WIDTH = 6,
  parameter integer CNU_DATA_OUT_WIDTH = 5,
  parameter integer INTRINSIC_DATA_WIDTH = 5,
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 6
)(
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  input  wire                              s_axi_aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  input  wire                              s_axi_aresetn,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
  input  wire [2:0]                        s_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input  wire                              s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire                              s_axi_awready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input  wire                              s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire                              s_axi_wready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output wire [1:0]                        s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output wire                              s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input  wire                              s_axi_bready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
  input  wire [2:0]                        s_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input  wire                              s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire                              s_axi_arready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output wire [1:0]                        s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output wire                              s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input  wire                              s_axi_rready
);

  localparam integer DATA_COUNT = L*K*K;
  localparam [2:0] CTRL_IDLE = 3'd0;
  localparam [2:0] CTRL_FRAME_RESET = 3'd1;
  localparam [2:0] CTRL_PREFETCH = 3'd2;
  localparam [2:0] CTRL_RUN = 3'd3;

  // AXI4-Lite register interface.
  reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
  reg [C_S_AXI_DATA_WIDTH-1:0] wdata_hold;
  reg [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_hold;
  reg aw_hold_valid;
  reg w_hold_valid;
  reg bvalid_reg;
  reg rvalid_reg;
  reg [C_S_AXI_DATA_WIDTH-1:0] rdata_reg;

  reg [10:0] input_index;
  reg [5:0] output_index;
  reg start_toggle_axi;
  reg done_latched_axi;
  reg timeout_latched_axi;
  reg [15:0] completed_frames_axi;

  // Capture the core's block/lane layout. Parallel taps below expose every
  // captured bit, so this bank is registers rather than a single-read-port RAM.
  reg [(K*K)-1:0] output_blocks [0:L-1];
  wire [DATA_COUNT-1:0] output_codeword;

  // Reference order: column, row, then the L addresses of that processing
  // element. All indices are elaboration constants: this is wiring in RTL,
  // with no runtime permutation or expected bit values stored in the RTL.
  generate
    for(genvar q = 0; q < K*K; q = q + 1) begin : codeword_lane
      for(genvar b = 0; b < L; b = b + 1) begin : codeword_address
        assign output_codeword[q*L+b] = output_blocks[b][(q%K)*K+q/K];
      end
    end
  endgenerate

  wire busy_decoder;
  wire done_toggle_decoder;
  wire timeout_toggle_decoder;
  wire f_id_core;
  wire [5:0] relay_core;

  (* ASYNC_REG = "TRUE" *) reg [1:0] busy_sync_axi;
  (* ASYNC_REG = "TRUE" *) reg [1:0] f_id_sync_axi;
  (* ASYNC_REG = "TRUE" *) reg [1:0] done_sync_axi;
  (* ASYNC_REG = "TRUE" *) reg [1:0] timeout_sync_axi;
  (* ASYNC_REG = "TRUE" *) reg [5:0] relay_sync_axi_0;
  (* ASYNC_REG = "TRUE" *) reg [5:0] relay_sync_axi_1;
  reg done_seen_axi;
  // FIX (ldpc_da2_configurable): AXI-domain copy of the result, refreshed only
  // while the synchronised busy flag is low (output_blocks is then static), so
  // the read multiplexer is a 100 MHz path instead of a clock-domain crossing.
  reg [DATA_COUNT-1:0] codeword_axi;
  always @(posedge s_axi_aclk)
    if(!busy_sync_axi[1]) codeword_axi <= output_codeword;
  reg timeout_seen_axi;

  assign s_axi_awready = !aw_hold_valid && !bvalid_reg;
  assign s_axi_wready  = !w_hold_valid && !bvalid_reg;
  assign s_axi_bresp   = 2'b00;
  assign s_axi_bvalid  = bvalid_reg;
  assign s_axi_arready = !rvalid_reg;
  assign s_axi_rdata   = rdata_reg;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rvalid  = rvalid_reg;

  wire write_commit = aw_hold_valid && w_hold_valid && !bvalid_reg;

  always @(posedge s_axi_aclk) begin
    if(!s_axi_aresetn) begin
      awaddr_hold          <= '0;
      wdata_hold           <= '0;
      wstrb_hold           <= '0;
      aw_hold_valid        <= 1'b0;
      w_hold_valid         <= 1'b0;
      bvalid_reg           <= 1'b0;
      rvalid_reg           <= 1'b0;
      rdata_reg            <= '0;
      input_index          <= '0;
      output_index         <= '0;
      start_toggle_axi     <= 1'b0;
      done_latched_axi     <= 1'b0;
      timeout_latched_axi  <= 1'b0;
      completed_frames_axi <= '0;
      busy_sync_axi        <= '0;
      f_id_sync_axi        <= '0;
      done_sync_axi        <= '0;
      timeout_sync_axi     <= '0;
      relay_sync_axi_0     <= '0;
      relay_sync_axi_1     <= '0;
      done_seen_axi        <= 1'b0;
      timeout_seen_axi     <= 1'b0;
    end else begin
      busy_sync_axi    <= {busy_sync_axi[0], busy_decoder};
      f_id_sync_axi    <= {f_id_sync_axi[0], f_id_core};
      done_sync_axi    <= {done_sync_axi[0], done_toggle_decoder};
      timeout_sync_axi <= {timeout_sync_axi[0], timeout_toggle_decoder};
      relay_sync_axi_0 <= relay_core;
      relay_sync_axi_1 <= relay_sync_axi_0;

      if(done_sync_axi[1] != done_seen_axi) begin
        done_seen_axi        <= done_sync_axi[1];
        done_latched_axi     <= 1'b1;
        completed_frames_axi <= completed_frames_axi + 1'b1;
      end

      if(timeout_sync_axi[1] != timeout_seen_axi) begin
        timeout_seen_axi    <= timeout_sync_axi[1];
        timeout_latched_axi <= 1'b1;
      end

      if(s_axi_awready && s_axi_awvalid) begin
        awaddr_hold   <= s_axi_awaddr;
        aw_hold_valid <= 1'b1;
      end

      if(s_axi_wready && s_axi_wvalid) begin
        wdata_hold   <= s_axi_wdata;
        wstrb_hold   <= s_axi_wstrb;
        w_hold_valid <= 1'b1;
      end

      if(write_commit) begin
        case(awaddr_hold[5:2])
          4'h0: begin
            if(wstrb_hold[0] && wdata_hold[0] && !busy_sync_axi[1]) begin
              start_toggle_axi    <= ~start_toggle_axi;
              done_latched_axi    <= 1'b0;
              timeout_latched_axi <= 1'b0;
            end
          end
          4'h2: begin
            if(wstrb_hold[0]) input_index[7:0]  <= wdata_hold[7:0];
            if(wstrb_hold[1]) input_index[10:8] <= wdata_hold[10:8];
          end
          4'h3: begin
            if(wstrb_hold[0] && !busy_sync_axi[1] && input_index < DATA_COUNT) begin
              if(input_index < DATA_COUNT-1)
                input_index <= input_index + 1'b1;
            end
          end
          4'h4: begin
            if(wstrb_hold[0]) output_index <= wdata_hold[5:0];
          end
          default: begin end
        endcase
        aw_hold_valid <= 1'b0;
        w_hold_valid  <= 1'b0;
        bvalid_reg    <= 1'b1;
      end else if(bvalid_reg && s_axi_bready) begin
        bvalid_reg <= 1'b0;
      end

      if(s_axi_arready && s_axi_arvalid) begin
        case(s_axi_araddr[5:2])
          4'h0: rdata_reg <= 32'h0000_0000;
          4'h1: rdata_reg <= {completed_frames_axi,
                              11'b0,
                              timeout_latched_axi,
                              f_id_sync_axi[1],
                              (completed_frames_axi >= 16'd3),
                              done_latched_axi,
                              busy_sync_axi[1]};
          4'h2: rdata_reg <= {{(C_S_AXI_DATA_WIDTH-11){1'b0}}, input_index};
          4'h3: rdata_reg <= 32'h0000_0000;
          4'h4: rdata_reg <= {{(C_S_AXI_DATA_WIDTH-6){1'b0}}, output_index};
          4'h5: begin
            if(output_index < L)
              rdata_reg <= codeword_axi[output_index*(K*K) +: 32];
            else
              rdata_reg <= 32'h0000_0000;
          end
          4'h6: begin
            if(output_index < L)
              rdata_reg <= {{(C_S_AXI_DATA_WIDTH-4){1'b0}}, codeword_axi[output_index*(K*K)+32 +: 4]};
            else
              rdata_reg <= 32'h0000_0000;
          end
          4'h7: rdata_reg <= {26'b0, relay_sync_axi_1};
          4'h8: rdata_reg <= 32'h434f4431;
          default: rdata_reg <= 32'h0000_0000;
        endcase
        rvalid_reg <= 1'b1;
      end else if(rvalid_reg && s_axi_rready) begin
        rvalid_reg <= 1'b0;
      end
    end
  end

  // AXI/FCLK0 is 100 MHz. The core gets related 30/60 MHz clocks.  The
  // 30 MHz clock is shifted by 90 degrees so each 60 MHz active edge occurs
  // away from a 30 MHz edge, matching the relationship used by Decoder_tb.v.
  wire clk_feedback;
  wire clk_feedback_buf;
  wire decoder_clk_raw;
  wire decoder_clk_df_raw;
  wire decoder_clk;
  wire decoder_clk_df;
  wire decoder_clocks_locked;

  MMCME2_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT_F(9.000),
    .CLKIN1_PERIOD(10.000),
    .CLKOUT0_DIVIDE_F(30.000),
    .CLKOUT0_PHASE(90.000),
    .CLKOUT1_DIVIDE(15),
    .CLKOUT1_PHASE(0.000),
    .DIVCLK_DIVIDE(1),
    .STARTUP_WAIT("FALSE")
  ) decoder_clock_mmcm (
    .CLKIN1(s_axi_aclk),
    .CLKFBIN(clk_feedback_buf),
    .RST(!s_axi_aresetn),
    .PWRDWN(1'b0),
    .CLKFBOUT(clk_feedback),
    .CLKOUT0(decoder_clk_raw),
    .CLKOUT1(decoder_clk_df_raw),
    .LOCKED(decoder_clocks_locked)
  );

  BUFG feedback_buffer (.I(clk_feedback), .O(clk_feedback_buf));
  BUFG decoder_clk_buf (.I(decoder_clk_raw), .O(decoder_clk));
  BUFG decoder_df_buf  (.I(decoder_clk_df_raw), .O(decoder_clk_df));

  (* ASYNC_REG = "TRUE" *) reg [3:0] decoder_reset_pipe;
  always @(posedge decoder_clk or negedge decoder_clocks_locked) begin
    if(!decoder_clocks_locked)
      decoder_reset_pipe <= 4'b1111;
    else
      decoder_reset_pipe <= {decoder_reset_pipe[2:0], 1'b0};
  end
  wire decoder_reset = decoder_reset_pipe[3];

  // One block RAM buffers a complete frame. Port A is written by AXI before
  // start; port B prefetches samples in decoder_clk domain.
  wire input_mem_write = write_commit && (awaddr_hold[5:2] == 4'h3) &&
                         wstrb_hold[0] && !busy_sync_axi[1] &&
                         (input_index < DATA_COUNT);
  reg [10:0] input_read_addr;
  wire [MESSAGE_WIDTH-1:0] input_sample_prefetch;

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(11),
    .ADDR_WIDTH_B(11),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(MESSAGE_WIDTH),
    .CLOCKING_MODE("independent_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(DATA_COUNT*MESSAGE_WIDTH),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(MESSAGE_WIDTH),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(MESSAGE_WIDTH),
    .WRITE_MODE_B("read_first")
  ) input_frame_buffer (
    .dbiterrb(),
    .doutb(input_sample_prefetch),
    .sbiterrb(),
    .addra(input_index),
    .addrb(input_read_addr),
    .clka(s_axi_aclk),
    .clkb(decoder_clk),
    .dina(wdata_hold[MESSAGE_WIDTH-1:0]),
    .ena(1'b1),
    .enb(1'b1),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .regceb(1'b1),
    // The controller prefetches valid data before enabling the core, so the
    // BRAM read output does not need resetting. Keeping RSTB low also avoids
    // an asynchronous reset path into the RAM primitive.
    .rstb(1'b0),
    .sleep(1'b0),
    .wea(input_mem_write)
  );

  // Frame sequencer. Controls change on decoder_clk falling edges, as in TB.
  reg [2:0] controller_state;
  reg [15:0] transfer_count;
  reg decoder_enable;
  reg decoder_ext_reset;
  reg previous_f_id;
  reg busy_decoder_reg;
  reg done_toggle_reg;
  reg timeout_toggle_reg;

  (* ASYNC_REG = "TRUE" *) reg [1:0] start_sync_decoder;
  reg start_seen_decoder;

  reg [K-1:0] column_select_decoder;
  reg [(K*K)-1:0] pe_select_decoder;
  reg [MESSAGE_WIDTH-1:0] int_in_decoder;
  reg [ADDR_WIDTH-1:0] load_addr_decoder;
  reg [ADDR_WIDTH-1:0] read_addr_decoder;
  wire [K-1:0][K-1:0] dec_out_decoder;
  wire [K*K-1:0] dec_out_flat = dec_out_decoder;

  assign busy_decoder = busy_decoder_reg;
  assign done_toggle_decoder = done_toggle_reg;
  assign timeout_toggle_decoder = timeout_toggle_reg;

  always @* begin
    column_select_decoder = '0;
    pe_select_decoder     = '0;
    int_in_decoder        = '0;
    load_addr_decoder     = '0;
    read_addr_decoder     = '0;

    if(controller_state == CTRL_RUN) begin
      if(transfer_count < DATA_COUNT) begin
        pe_select_decoder[transfer_count/L] = 1'b1;
        int_in_decoder = input_sample_prefetch;
        load_addr_decoder = transfer_count % L;
      end
      if(transfer_count < L*K) begin
        read_addr_decoder = transfer_count/K;
        column_select_decoder[transfer_count % K] = 1'b1;
      end
    end
  end

  always @(negedge decoder_clk) begin
    if(decoder_reset) begin
      controller_state   <= CTRL_IDLE;
      transfer_count     <= '0;
      decoder_enable     <= 1'b0;
      decoder_ext_reset  <= 1'b0;
      previous_f_id      <= 1'b0;
      busy_decoder_reg   <= 1'b0;
      done_toggle_reg    <= 1'b0;
      timeout_toggle_reg <= 1'b0;
      start_sync_decoder <= '0;
      start_seen_decoder <= 1'b0;
      input_read_addr <= '0;
    end else begin
      start_sync_decoder <= {start_sync_decoder[0], start_toggle_axi};

      case(controller_state)
        CTRL_IDLE: begin
          busy_decoder_reg  <= 1'b0;
          decoder_enable    <= 1'b0;
          decoder_ext_reset <= 1'b0;
          if(start_sync_decoder[1] != start_seen_decoder) begin
            start_seen_decoder <= start_sync_decoder[1];
            transfer_count     <= '0;
            previous_f_id      <= f_id_core;
            decoder_ext_reset  <= 1'b1;
            busy_decoder_reg   <= 1'b1;
            controller_state   <= CTRL_FRAME_RESET;
          end
        end

        CTRL_FRAME_RESET: begin
          decoder_ext_reset <= 1'b0;
          decoder_enable    <= 1'b1;
          input_read_addr   <= '0;
          controller_state  <= CTRL_PREFETCH;
        end

        CTRL_PREFETCH: begin
          input_read_addr  <= 11'd1;
          controller_state <= CTRL_RUN;
        end

        CTRL_RUN: begin
          if(f_id_core != previous_f_id) begin
            busy_decoder_reg <= 1'b0;
            decoder_enable   <= 1'b0;
            done_toggle_reg  <= ~done_toggle_reg;
            controller_state <= CTRL_IDLE;
          end else if(transfer_count == 16'hffff) begin
            busy_decoder_reg   <= 1'b0;
            decoder_enable     <= 1'b0;
            timeout_toggle_reg <= ~timeout_toggle_reg;
            controller_state   <= CTRL_IDLE;
          end else begin
            if(transfer_count < DATA_COUNT-2)
              input_read_addr <= transfer_count + 2'd2;
            transfer_count <= transfer_count + 1'b1;
          end
        end

        default: controller_state <= CTRL_IDLE;
      endcase
    end
  end

  // FIX (ldpc_da2_configurable, not in ldpc_da2): output capture.
  // The original path toggled sample_toggle on the decoder_clk rising edge and
  // sampled it on the decoder_clk_df falling edge. With the 90-degree MMCM
  // phase these two edges coincide, so captures were lost or doubled (0, 32 or
  // 64 writes per transaction instead of 32) and the previous codeword was
  // returned. For transfer_count T the PE read is issued on the clk_df rising
  // edge with clk low, the DEC_RAM output on the next clk rising edge, and
  // dec_out updates on the following clk_df rising edge (clk high), 8.3 ns
  // before the decoder_clk falling edge that advances T. Capture on that edge,
  // deterministically: on the next clk_df rising edge with clk low, dec_out
  // still holds T (stable for 16.7 ns), so block T/K is written exactly once
  // (clk is used as a qualifier here, as in PE_block). Kept in the clk_df
  // domain: the
  // decoder_clk edges are only 1.67 ns from a 100 MHz edge (90-degree phase).
  // No reset on this RAM: software only reads it after STATUS.done is set.
  // The block decision for T is registered on the same decoder_clk falling
  // edge that advances T (the /K and %K logic then has a full 33 ns), so the
  // 8.3 ns clk_df capture path is only a register and a 5-bit decode.
  reg       cap_en;
  reg [4:0] cap_idx;
  always @(negedge decoder_clk) begin
    cap_en  <= !decoder_reset && controller_state == CTRL_RUN &&
               transfer_count < L*K && (transfer_count % K) == (K-1);
    cap_idx <= transfer_count / K;
  end
  always @(posedge decoder_clk_df) begin
    if(!decoder_reset && !decoder_clk && cap_en)
      output_blocks[cap_idx] <= dec_out_flat;
  end

  LDPC_Decoder #(
    .L(L),
    .ADDR_WIDTH(ADDR_WIDTH),
    .MESSAGE_WIDTH(MESSAGE_WIDTH),
    .K(K),
    .CNU_DATA_IN_WIDTH(CNU_DATA_IN_WIDTH),
    .CNU_DATA_OUT_WIDTH(CNU_DATA_OUT_WIDTH),
    .INTRINSIC_DATA_WIDTH(INTRINSIC_DATA_WIDTH)
  ) decoder_core (
    .clk(decoder_clk),
    .clk_df(decoder_clk_df),
    .en(decoder_enable),
    .f_id(f_id_core),
    .relay(relay_core),
    .ext_reset(decoder_ext_reset),
    .column_select(column_select_decoder),
    .pe_select(pe_select_decoder),
    .int_in(int_in_decoder),
    .load_add_in(load_addr_decoder),
    .read_add_in(read_addr_decoder),
    .reset(decoder_reset),
    .dec_out_fin(dec_out_decoder)
  );

  wire unused_axi_prot = ^{s_axi_awprot, s_axi_arprot};

endmodule
