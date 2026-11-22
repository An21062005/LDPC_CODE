// Core-level decode test for the new cores (Serial, Fully-Parallel): no AXI,
// no wrapper. Drives the ldpc_core transaction interface exactly as the
// wrapper does (load bank ~rs, read decisions of bank ~rs, swap), so output t
// is frame t-2. Same data files and the same pass rule as tb_da2.sv: every
// compared bit must equal the clean codeword. Also reports decode cycles.
`timescale 1ns/1ps

module tb_core import ldpc_code_pkg::*;;   // import ; then header ;
  localparam integer N = LDPC_N;
  localparam integer AW = $clog2(N);
  reg clk = 0, rst = 1;
  always #16.667 clk = ~clk;                 // 30 MHz, the decoder clock
  reg start = 0, swap = 0, load_we = 0;
  reg [AW-1:0] load_addr = 0, dec_addr = 0;
  reg [4:0] load_data = 0;
  wire busy, dec_bit;
  wire [5:0] debug;
  ldpc_core core (.clk(clk), .rst(rst), .start(start), .swap(swap), .busy(busy),
                  .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
                  .dec_addr(dec_addr), .dec_bit(dec_bit), .debug(debug));

  string input_path, expected_path, actual_path;
  integer fi, fe, fo, r, frames = 5, t, i, cycles, frame_errors, total_errors = 0;
  integer first_error_bit = 0, output_frame = 0, compared_bits = 0;
  reg compare_done = 0;
  reg [4:0] sample [0:N-1];
  reg [0:N-1] decoded_view = '0, expected_view = '0;
  wire [0:N-1] difference_view = compare_done ? decoded_view ^ expected_view : '0;
  wire [0:15] decoded_first16 = decoded_view[0:15];
  wire [0:15] expected_first16 = expected_view[0:15];
  wire [0:15] difference_first16 = difference_view[0:15];
  reg [N-1:0] expected_word;

  initial begin
    #2000000000; $fatal(1, "global simulation timeout");
  end

  initial begin
    if (!$value$plusargs("INPUT=%s", input_path)) $fatal(1, "INPUT required");
    if (!$value$plusargs("EXPECTED=%s", expected_path)) $fatal(1, "EXPECTED required");
    if (!$value$plusargs("ACTUAL=%s", actual_path)) actual_path = "output_codeword.txt";
    r = $value$plusargs("FRAMES=%d", frames);
    fi = $fopen(input_path, "r"); fe = $fopen(expected_path, "r"); fo = $fopen(actual_path, "w");
    if (!fi || !fe || !fo) $fatal(1, "open data files");
    repeat (5) @(negedge clk); rst = 0;
    repeat (5) @(negedge clk);
    for (t = 1; t <= frames; t = t + 1) begin
      for (i = 0; i < N; i = i + 1) begin
        r = $fscanf(fi, "%b", sample[i]);
        if (r != 1) $fatal(1, "input frame %0d sample %0d", t, i);
      end
      @(negedge clk) start = 1;
      @(negedge clk) start = 0;
      cycles = 1;
      for (i = 0; i <= N; i = i + 1) begin      // stream as the wrapper does
        load_we = (i > 0); load_addr = i - 1; load_data = (i > 0) ? sample[i-1] : 0;
        dec_addr = (i < N) ? i : 0;
        @(posedge clk);
        if (i > 0) decoded_view[i-1] = dec_bit;  // dec_bit for address i-1
        if (busy) cycles = cycles + 1;   // counts from the start pulse: +1 vs core_monitor
        @(negedge clk);
      end
      load_we = 0;
      while (busy) begin @(posedge clk); cycles = cycles + 1; @(negedge clk); end
      $display("CORE_DECODE_CYCLES transaction=%0d cycles=%0d", t, cycles);
      swap = 1; @(negedge clk) swap = 0;
      if (t >= 3) begin
        r = $fscanf(fe, "%b", expected_word);
        if (r != 1) $fatal(1, "expected frame missing");
        for (i = 0; i < N; i = i + 1) expected_view[i] = expected_word[N-1-i];
        frame_errors = 0; first_error_bit = 0; output_frame = t - 2;
        for (i = 0; i < N; i = i + 1) begin
          $fwrite(fo, "%b", decoded_view[i]);
          if (decoded_view[i] !== expected_view[i]) begin
            if (first_error_bit == 0) first_error_bit = i + 1;
            frame_errors = frame_errors + 1;
          end
        end
        $fwrite(fo, "\n");
        compare_done = 1;
        total_errors = total_errors + frame_errors;
        compared_bits = compared_bits + N;
        $display("FRAME_COMPARE output=%0d bit_errors=%0d", t - 2, frame_errors);
      end
    end
    $fclose(fi); $fclose(fe); $fclose(fo);
    if (total_errors != 0) $fatal(1, "FAIL_CORE compared_frames=%0d bit_errors=%0d", frames - 2, total_errors);
    $display("PASS_CORE transactions=%0d compared_frames=%0d compared_bits=%0d", frames, frames - 2, compared_bits);
    $finish;
  end
endmodule
