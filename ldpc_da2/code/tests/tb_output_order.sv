`timescale 1ns/1ps

module tb_pynq_codeword_order;
  localparam integer DATA_COUNT = 1152;

  reg clk = 1'b0;
  reg aresetn = 1'b0;
  always #5 clk = ~clk;

  reg [5:0]  awaddr = '0;
  reg [2:0]  awprot = '0;
  reg        awvalid = 1'b0;
  wire       awready;
  reg [31:0] wdata = '0;
  reg [3:0]  wstrb = '0;
  reg        wvalid = 1'b0;
  wire       wready;
  wire [1:0] bresp;
  wire       bvalid;
  reg        bready = 1'b0;
  reg [5:0]  araddr = '0;
  reg [2:0]  arprot = '0;
  reg        arvalid = 1'b0;
  wire       arready;
  wire [31:0] rdata;
  wire [1:0]  rresp;
  wire        rvalid;
  reg         rready = 1'b0;

  integer input_fd;
  integer expected_fd;
  integer scan_result;
  integer frame;
  integer sample;
  integer block_index;
  integer bit_index;
  integer poll_count;
  integer mismatch_count;
  integer actual_fd;
  reg [4:0] sample_value;
  reg [31:0] status_value;
  reg [31:0] low_value;
  reg [31:0] high_value;
  reg [1151:0] actual_bits;
  reg [1151:0] expected_line;
  // Simulation-only views, shared names with tb_da2 for waveform profiles.
  integer frame_errors=0,total_errors=0,first_error_bit=0,compared_bits=0,output_frame=0;
  reg compare_done=0;
  wire [0:1151] decoded_view,expected_view;
  wire [0:1151] difference_view=compare_done ? decoded_view^expected_view : '0;
  wire [0:15] decoded_first16=decoded_view[0:15];
  wire [0:15] expected_first16=expected_view[0:15];
  wire [0:15] difference_first16=difference_view[0:15];
  for(genvar view_bit=0;view_bit<1152;view_bit=view_bit+1)begin
    assign decoded_view[view_bit]=actual_bits[view_bit];
    assign expected_view[view_bit]=expected_line[1151-view_bit];
  end
  string input_path;
  string expected_path;

  LDPC_Decoder_PYNQ_Z2_top dut (
    .s_axi_aclk(clk),
    .s_axi_aresetn(aresetn),
    .s_axi_awaddr(awaddr),
    .s_axi_awprot(awprot),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb),
    .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_araddr(araddr),
    .s_axi_arprot(arprot),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rdata(rdata),
    .s_axi_rresp(rresp),
    .s_axi_rvalid(rvalid),
    .s_axi_rready(rready)
  );

  task automatic axi_write(input [5:0] address, input [31:0] value);
    begin
      @(posedge clk);
      awaddr  <= address;
      awvalid <= 1'b1;
      wdata   <= value;
      wstrb   <= 4'hf;
      wvalid  <= 1'b1;
      do @(posedge clk); while (!(awready && wready));
      awvalid <= 1'b0;
      wvalid  <= 1'b0;
      bready  <= 1'b1;
      do @(posedge clk); while (!bvalid);
      if (bresp != 2'b00) $fatal(1, "AXI write response error");
      bready <= 1'b0;
    end
  endtask

  task automatic axi_read(input [5:0] address, output [31:0] value);
    begin
      @(posedge clk);
      araddr  <= address;
      arvalid <= 1'b1;
      do @(posedge clk); while (!arready);
      arvalid <= 1'b0;
      rready  <= 1'b1;
      do @(posedge clk); while (!rvalid);
      value = rdata;
      if (rresp != 2'b00) $fatal(1, "AXI read response error");
      rready <= 1'b0;
    end
  endtask


  integer raw_fd;
  integer ordered_fd;
  string raw_path;
  string ordered_path;
  reg [1151:0] raw_line;

  initial begin
    if (!$value$plusargs("RAW_FILE=%s", raw_path))
      $fatal(1, "RAW_FILE must name the recorded raw board output");
    if (!$value$plusargs("EXPECTED_FILE=%s", expected_path))
      $fatal(1, "EXPECTED_FILE must name the clean codeword reference");
    if (!$value$plusargs("ORDERED_FILE=%s", ordered_path))
      ordered_path = "output_codeword.txt";
    raw_fd = $fopen(raw_path, "r");
    expected_fd = $fopen(expected_path, "r");
    ordered_fd = $fopen(ordered_path, "w");
    if (!raw_fd || !expected_fd || !ordered_fd) $fatal(1, "cannot open codeword-order test files");

    repeat (20) @(posedge clk);
    aresetn <= 1'b1;
    repeat (200) @(posedge clk);
    axi_read(6'h20, status_value);
    if (status_value !== 32'h434f4431) $fatal(1, "missing COD1 output format");

    // Feed recorded capture-bank data, then exercise the real RTL AXI readout.
    // No permutation is applied to expected or to the bits returned over AXI.
    for (frame = 0; frame < 696; frame = frame + 1) begin
      compare_done=0;
      output_frame=frame+1;
      scan_result = $fscanf(raw_fd, "%b", raw_line);
      if (scan_result != 1) $fatal(1, "missing raw frame %0d", frame);
      scan_result = $fscanf(expected_fd, "%b", expected_line);
      if (scan_result != 1) $fatal(1, "missing expected frame %0d", frame);
      for (block_index = 0; block_index < 32; block_index = block_index + 1)
        for (bit_index = 0; bit_index < 36; bit_index = bit_index + 1)
          dut.output_blocks[block_index][bit_index] = raw_line[1151-block_index*36-bit_index];
      actual_bits = '0;
      for (block_index = 0; block_index < 32; block_index = block_index + 1) begin
        axi_write(6'h10, block_index);
        axi_read(6'h14, low_value);
        axi_read(6'h18, high_value);
        if (high_value[31:4] !== 28'd0) $fatal(1, "OUTPUT_HI padding is nonzero");
        for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
          actual_bits[block_index*36+bit_index] = low_value[bit_index];
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1)
          actual_bits[block_index*36+32+bit_index] = high_value[bit_index];
      end
      compare_done=1;
      compared_bits=compared_bits+1152;
      for (bit_index = 0; bit_index < 1152; bit_index = bit_index + 1) begin
        if (actual_bits[bit_index] !== expected_line[1151-bit_index])
          $fatal(1, "ordered output mismatch frame=%0d bit=%0d", frame, bit_index);
        $fwrite(ordered_fd, "%b", actual_bits[bit_index]);
      end
      $fwrite(ordered_fd, "\n");
    end
    scan_result = $fscanf(raw_fd, "%b", raw_line);
    if (scan_result == 1) $fatal(1, "unexpected extra raw frame");
    scan_result = $fscanf(expected_fd, "%b", expected_line);
    if (scan_result == 1) $fatal(1, "unexpected extra expected frame");
    axi_write(6'h10, 32'd32);
    axi_read(6'h14, low_value);
    axi_read(6'h18, high_value);
    if (low_value !== 0 || high_value !== 0) $fatal(1, "invalid output index must return zero");
    $fclose(raw_fd);
    $fclose(expected_fd);
    $fclose(ordered_fd);
    $display("PASS: direct RTL AXI codeword output matched 696 frames / 801792 bits");
    $finish;
  end
endmodule
