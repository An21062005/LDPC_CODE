`timescale 1ns/1ps

module tb_pynq_axi_wrapper;
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

  initial begin
    if (!$value$plusargs("INPUT_FILE=%s", input_path))
      input_path = "../../board_uploads/input.txt";
    if (!$value$plusargs("EXPECTED_FILE=%s", expected_path))
      expected_path = "../../FINAL_REPORT_PACKAGE/results/expected_codeword.txt";
    input_fd = $fopen(input_path, "r");
    expected_fd = $fopen(expected_path, "r");
    if (!input_fd || !expected_fd) $fatal(1, "cannot open AXI wrapper test data");
    scan_result = $fscanf(expected_fd, "%b", expected_line);
    if (scan_result != 1) $fatal(1, "cannot read expected output line");

    repeat (20) @(posedge clk);
    aresetn <= 1'b1;
    repeat (200) @(posedge clk);
    axi_read(6'h20, status_value);
    if (status_value !== 32'h434f4431) $fatal(1, "missing COD1 output format");

    for (frame = 1; frame <= 3; frame = frame + 1) begin
      axi_write(6'h08, 32'd0);
      for (sample = 0; sample < DATA_COUNT; sample = sample + 1) begin
        scan_result = $fscanf(input_fd, "%b", sample_value);
        if (scan_result != 1) $fatal(1, "input ended at frame %0d sample %0d", frame, sample);
        axi_write(6'h0c, {27'd0, sample_value});
      end

      axi_write(6'h00, 32'd1);
      status_value = 32'd0;
      poll_count = 0;
      while (!(status_value[1])) begin
        axi_read(6'h04, status_value);
        poll_count = poll_count + 1;
        if (status_value[4]) $fatal(1, "hardware timeout on frame %0d", frame);
        if (poll_count > 20000) $fatal(1, "software poll timeout on frame %0d", frame);
      end
      $display("AXI frame %0d completed, status=%08x", frame, status_value);
    end

    if (!status_value[2]) $fatal(1, "third frame is not marked output-valid");

    actual_bits = '0;
    for (block_index = 0; block_index < 32; block_index = block_index + 1) begin
      axi_write(6'h10, block_index);
      axi_read(6'h14, low_value);
      axi_read(6'h18, high_value);
      for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
        actual_bits[block_index*36 + bit_index] = low_value[bit_index];
      for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1)
        actual_bits[block_index*36 + 32 + bit_index] = high_value[bit_index];
    end

    mismatch_count = 0;
    for (bit_index = 0; bit_index < DATA_COUNT; bit_index = bit_index + 1)
      if (actual_bits[bit_index] !== expected_line[DATA_COUNT-1-bit_index])
        mismatch_count = mismatch_count + 1;

    if (mismatch_count != 0) begin
      actual_fd = $fopen("wrapper_actual.txt", "w");
      for (bit_index = 0; bit_index < DATA_COUNT; bit_index = bit_index + 1)
        $fwrite(actual_fd, "%b", actual_bits[bit_index]);
      $fwrite(actual_fd, "\n");
      $fclose(actual_fd);
      $fatal(1, "AXI wrapper output mismatch: %0d bits", mismatch_count);
    end

    $display("PASS: AXI wrapper loaded 3 frames and matched all 1152 output bits");
    $fclose(input_fd);
    $fclose(expected_fd);
    $finish;
  end
endmodule
