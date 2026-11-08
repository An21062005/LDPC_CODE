// PYNQ-Z2 AXI4-Lite wrapper for the Serial and Fully-Parallel cores.
//
// Software view is the same as ldpc_da2 (da2_core/LDPC_Decoder_PYNQ_Z2_top.sv),
// so code/tests/tb_da2.sv and run_board.py work unchanged:
//   0x00 CONTROL       W bit 0: start one transaction (ignored while busy)
//   0x04 STATUS        R bit 0 busy, 1 done, 2 output_valid (>=3 transactions),
//                        3 rs, 4 timeout (always 0), 31:16 completed transactions
//   0x08 INPUT_ADDR    R/W auto-incrementing sample index
//   0x0c INPUT_DATA    W five-bit sample, increments INPUT_ADDR
//   0x10 OUTPUT_ADDR   R/W 36-bit chunk index
//   0x14 OUTPUT_LO     R codeword bits [chunk*36 +: 32], bit 0 = first bit
//   0x18 OUTPUT_HI     R next four codeword bits in [3:0]
//   0x1c CORE_DEBUG    R core debug[5:0]
//   0x20 OUTPUT_FORMAT R 0x434f4431 ("COD1", codeword order)
// Transaction t loads frame t, decodes frame t-1 and returns frame t-2, the
// same two-transaction latency as da2. The decoder runs on a 30 MHz MMCM
// clock (same frequency as the da2 core clock), derived from the 100 MHz AXI
// clock. Codeword bit n is VN n, input sample n and H column n: no reordering.
`default_nettype none

module LDPC_Decoder_PYNQ_Z2_top import ldpc_code_pkg::*; #(
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
  localparam integer N = LDPC_N;      // code length from the package (not a BD parameter)
  localparam integer AW = $clog2(N);
  localparam integer CHUNKS = (N + 35) / 36;
  localparam integer PAD = CHUNKS*36;

  // ---------------- AXI4-Lite register interface (as in da2) ----------------
  reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
  reg [C_S_AXI_DATA_WIDTH-1:0] wdata_hold;
  reg [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_hold;
  reg aw_hold_valid, w_hold_valid, bvalid_reg, rvalid_reg;
  reg [C_S_AXI_DATA_WIDTH-1:0] rdata_reg;
  reg [10:0] input_index;
  reg [5:0]  output_index;
  reg start_toggle_axi, done_latched_axi;
  reg [15:0] completed_frames_axi;
  reg [PAD-1:0] codeword_axi;            // AXI-domain copy taken at done

  wire busy_decoder, done_toggle_decoder, rs_decoder;
  wire [5:0] debug_core;
  reg  [PAD-1:0] codeword_dec;           // decoder-domain capture
  (* ASYNC_REG = "TRUE" *) reg [1:0] busy_sync_axi, done_sync_axi, rs_sync_axi;
  (* ASYNC_REG = "TRUE" *) reg [5:0] debug_sync_axi_0, debug_sync_axi_1;
  reg done_seen_axi;

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
    if (!s_axi_aresetn) begin
      awaddr_hold <= '0; wdata_hold <= '0; wstrb_hold <= '0;
      aw_hold_valid <= 1'b0; w_hold_valid <= 1'b0; bvalid_reg <= 1'b0; rvalid_reg <= 1'b0;
      rdata_reg <= '0; input_index <= '0; output_index <= '0;
      start_toggle_axi <= 1'b0; done_latched_axi <= 1'b0; completed_frames_axi <= '0;
      busy_sync_axi <= '0; done_sync_axi <= '0; rs_sync_axi <= '0;
      debug_sync_axi_0 <= '0; debug_sync_axi_1 <= '0; done_seen_axi <= 1'b0;
    end else begin
      busy_sync_axi <= {busy_sync_axi[0], busy_decoder};
      done_sync_axi <= {done_sync_axi[0], done_toggle_decoder};
      rs_sync_axi   <= {rs_sync_axi[0], rs_decoder};
      debug_sync_axi_0 <= debug_core;
      debug_sync_axi_1 <= debug_sync_axi_0;

      if (done_sync_axi[1] != done_seen_axi) begin
        done_seen_axi        <= done_sync_axi[1];
        done_latched_axi     <= 1'b1;
        completed_frames_axi <= completed_frames_axi + 1'b1;
      end

      if (s_axi_awready && s_axi_awvalid) begin awaddr_hold <= s_axi_awaddr; aw_hold_valid <= 1'b1; end
      if (s_axi_wready && s_axi_wvalid) begin
        wdata_hold <= s_axi_wdata; wstrb_hold <= s_axi_wstrb; w_hold_valid <= 1'b1;
      end

      if (write_commit) begin
        case (awaddr_hold[5:2])
          4'h0: if (wstrb_hold[0] && wdata_hold[0] && !busy_sync_axi[1]) begin
                  start_toggle_axi <= ~start_toggle_axi;
                  done_latched_axi <= 1'b0;
                end
          4'h2: begin
                  if (wstrb_hold[0]) input_index[7:0]  <= wdata_hold[7:0];
                  if (wstrb_hold[1]) input_index[10:8] <= wdata_hold[10:8];
                end
          4'h3: if (wstrb_hold[0] && !busy_sync_axi[1] && input_index < N && input_index < N-1)
                  input_index <= input_index + 1'b1;
          4'h4: if (wstrb_hold[0]) output_index <= wdata_hold[5:0];
          default: begin end
        endcase
        aw_hold_valid <= 1'b0; w_hold_valid <= 1'b0; bvalid_reg <= 1'b1;
      end else if (bvalid_reg && s_axi_bready) begin
        bvalid_reg <= 1'b0;
      end

      if (s_axi_arready && s_axi_arvalid) begin
        case (s_axi_araddr[5:2])
          4'h1: rdata_reg <= {completed_frames_axi, 11'b0, 1'b0, rs_sync_axi[1],
                              (completed_frames_axi >= 16'd3), done_latched_axi, busy_sync_axi[1]};
          4'h2: rdata_reg <= {{(C_S_AXI_DATA_WIDTH-11){1'b0}}, input_index};
          4'h4: rdata_reg <= {{(C_S_AXI_DATA_WIDTH-6){1'b0}}, output_index};
          4'h5: rdata_reg <= (output_index < CHUNKS) ? codeword_axi[output_index*36 +: 32] : 32'h0;
          4'h6: rdata_reg <= (output_index < CHUNKS) ?
                             {{(C_S_AXI_DATA_WIDTH-4){1'b0}}, codeword_axi[output_index*36+32 +: 4]} : 32'h0;
          4'h7: rdata_reg <= {26'b0, debug_sync_axi_1};
          4'h8: rdata_reg <= 32'h434f4431;
          default: rdata_reg <= 32'h0;
        endcase
        rvalid_reg <= 1'b1;
      end else if (rvalid_reg && s_axi_rready) begin
        rvalid_reg <= 1'b0;
      end
    end
  end

  // The decoder-domain capture is stable from before the done toggle until
  // the next start, so it is copied once when done is seen.
  always @(posedge s_axi_aclk)
    if (s_axi_aresetn && done_sync_axi[1] != done_seen_axi) codeword_axi <= codeword_dec;

  // ---------------- decoder clock: 30 MHz from the 100 MHz AXI clock --------
  wire clk_feedback, clk_feedback_buf, decoder_clk_raw, decoder_clk, decoder_clocks_locked;
  MMCME2_BASE #(
    .BANDWIDTH("OPTIMIZED"), .CLKFBOUT_MULT_F(9.000), .CLKIN1_PERIOD(10.000),
    .CLKOUT0_DIVIDE_F(30.000), .CLKOUT0_PHASE(0.000), .DIVCLK_DIVIDE(1), .STARTUP_WAIT("FALSE")
  ) decoder_clock_mmcm (
    .CLKIN1(s_axi_aclk), .CLKFBIN(clk_feedback_buf), .RST(!s_axi_aresetn), .PWRDWN(1'b0),
    .CLKFBOUT(clk_feedback), .CLKOUT0(decoder_clk_raw), .LOCKED(decoder_clocks_locked),
    .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
  );
  BUFG feedback_buffer (.I(clk_feedback), .O(clk_feedback_buf));
  BUFG decoder_clk_buf (.I(decoder_clk_raw), .O(decoder_clk));

  (* ASYNC_REG = "TRUE" *) reg [3:0] decoder_reset_pipe;
  always @(posedge decoder_clk or negedge decoder_clocks_locked) begin
    if (!decoder_clocks_locked) decoder_reset_pipe <= 4'b1111;
    else decoder_reset_pipe <= {decoder_reset_pipe[2:0], 1'b0};
  end
  wire decoder_reset = decoder_reset_pipe[3];

  // ---------------- input frame buffer (AXI write, decoder read) ----------
  wire input_mem_write = write_commit && (awaddr_hold[5:2] == 4'h3) && wstrb_hold[0] &&
                         !busy_sync_axi[1] && (input_index < N);
  reg  [AW-1:0] input_read_addr;
  wire [4:0]    input_sample;
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(5),
    .CLOCKING_MODE("independent_clock"), .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(2048*5), .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(5), .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(5), .WRITE_MODE_B("read_first")
  ) input_frame_buffer (
    .dbiterrb(), .doutb(input_sample), .sbiterrb(),
    .addra(input_index), .addrb({{(11-AW){1'b0}}, input_read_addr}),
    .clka(s_axi_aclk), .clkb(decoder_clk), .dina(wdata_hold[4:0]), .ena(1'b1), .enb(1'b1),
    .injectdbiterra(1'b0), .injectsbiterra(1'b0), .regceb(1'b1), .rstb(1'b0), .sleep(1'b0),
    .wea(input_mem_write)
  );

  // ---------------- transaction sequencer (decoder clock) ----------------
  // STREAM: sample k -> core bank ~rs and decision k of bank ~rs -> capture,
  // one per clock, while the core decodes bank rs. DONE waits for both.
  localparam [1:0] Q_IDLE = 2'd0, Q_STREAM = 2'd1, Q_WAIT = 2'd2;
  reg [1:0]    qstate;
  reg [AW:0]   k;
  reg          v_d;
  reg [AW-1:0] k_d;
  reg          core_start, core_swap, busy_reg, done_toggle_reg;
  (* ASYNC_REG = "TRUE" *) reg [1:0] start_sync_decoder;
  reg start_seen_decoder;
  wire core_busy, dec_bit;

  always @(posedge decoder_clk) begin
    if (decoder_reset) begin
      qstate <= Q_IDLE; k <= '0; v_d <= 1'b0; k_d <= '0; core_start <= 1'b0; core_swap <= 1'b0;
      busy_reg <= 1'b0; done_toggle_reg <= 1'b0; start_sync_decoder <= '0; start_seen_decoder <= 1'b0;
      input_read_addr <= '0;
    end else begin
      start_sync_decoder <= {start_sync_decoder[0], start_toggle_axi};
      core_start <= 1'b0;
      core_swap  <= 1'b0;
      v_d <= (qstate == Q_STREAM) && (k < N);
      k_d <= k[AW-1:0];
      if (v_d) codeword_dec[k_d] <= dec_bit;
      case (qstate)
        Q_IDLE: if (start_sync_decoder[1] != start_seen_decoder) begin
          start_seen_decoder <= start_sync_decoder[1];
          busy_reg <= 1'b1; core_start <= 1'b1; k <= '0; input_read_addr <= '0;
          qstate <= Q_STREAM;
        end
        Q_STREAM: begin
          if (k < N) begin
            k <= k + 1'b1;
            input_read_addr <= (k + 1 < N) ? k[AW-1:0] + 1'b1 : '0;
          end else if (!v_d) qstate <= Q_WAIT;
        end
        Q_WAIT: if (!core_busy && !core_start) begin
          core_swap <= 1'b1; busy_reg <= 1'b0; done_toggle_reg <= ~done_toggle_reg;
          qstate <= Q_IDLE;
        end
        default: qstate <= Q_IDLE;
      endcase
    end
  end
  initial codeword_dec = '0;

  ldpc_core core (
    .clk(decoder_clk), .rst(decoder_reset), .start(core_start), .swap(core_swap), .busy(core_busy),
    .load_we(v_d), .load_addr(k_d), .load_data(input_sample),
    .dec_addr(k[AW-1:0]), .dec_bit(dec_bit), .debug(debug_core)
  );

  assign busy_decoder = busy_reg;
  assign done_toggle_decoder = done_toggle_reg;
  assign rs_decoder = debug_core[5];
  wire unused_axi_prot = ^{s_axi_awprot, s_axi_arprot};
endmodule

`default_nettype wire
