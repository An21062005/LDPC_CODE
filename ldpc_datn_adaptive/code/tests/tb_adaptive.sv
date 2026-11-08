// Core-level test of adaptive_core: several (code, P_act, C_act) segments run
// one after another on the SAME hardware in one simulation. For every segment
// the configuration image produced by script/mapper.py is written through the
// configuration port while the core is idle, then the frames of that code are
// decoded. As with every ldpc_da2_* core, output t is frame t-2, so the first
// two outputs after a reconfiguration are discarded. Pass rule as in tb_da2:
// every compared bit equals the clean codeword. The launcher also compares the
// outputs bit by bit with the Python model. Last check: a configuration write
// while the core is busy must set cfg_err and must not change Z.
//
// plusargs: PLAN=<file>, each line "config input expected frames n"; TIMEOUT_US
`timescale 1ns/1ps

module tb_adaptive;
  reg clk = 0, rst = 1;
  always #16.667 clk = ~clk;                       // 30 MHz decoder clock
  reg start = 0, swap = 0, load_we = 0, cfg_we = 0;
  reg [10:0] load_addr = 0, dec_addr = 0;
  reg [4:0] load_data = 0;
  reg [11:0] cfg_addr = 0;
  reg [7:0] cfg_data = 0;
  wire busy, dec_bit, cfg_err;
  wire [10:0] n_bits;
  wire [5:0] debug;
  adaptive_core core (.clk(clk), .rst(rst), .start(start), .swap(swap), .busy(busy),
    .load_we(load_we), .load_addr(load_addr), .load_data(load_data), .dec_addr(dec_addr), .dec_bit(dec_bit),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data), .cfg_err(cfg_err), .n_bits(n_bits), .debug(debug));

  string plan_path, cfg_path, in_path, exp_path, out_path;
  integer fp, fc, fi, fe, fo, r, seg = 0, frames, n, t, j, cycles, errs, total_errors = 0, compared = 0, a, d;
  reg [4:0] sample [0:1295];
  reg [0:1295] decoded;
  reg [1295:0] expected_word;

  task automatic cfg_write(input [11:0] ad, input [7:0] dt);
    @(negedge clk); cfg_addr = ad; cfg_data = dt; cfg_we = 1;
    @(negedge clk); cfg_we = 0;
  endtask

  task automatic transaction(input integer nn, output integer cyc);
    @(negedge clk) start = 1;
    @(negedge clk) start = 0;
    cyc = 1;
    for (j = 0; j <= nn; j = j + 1) begin          // stream as the AXI wrapper does
      load_we = (j > 0); load_addr = j - 1; load_data = (j > 0) ? sample[j-1] : 0;
      dec_addr = (j < nn) ? j : 0;
      @(posedge clk);
      if (j > 0) decoded[j-1] = dec_bit;
      if (busy) cyc = cyc + 1;
      @(negedge clk);
    end
    load_we = 0;
    while (busy) begin @(posedge clk); cyc = cyc + 1; @(negedge clk); end
    swap = 1; @(negedge clk) swap = 0;
  endtask

  // Hang guard sized by the launcher from the plan (frames x predicted cycles);
  // 1 us steps avoid 32-bit delay overflow.
  longint timeout_us = 1000000;
  initial begin
    if ($value$plusargs("TIMEOUT_US=%d", timeout_us)) begin end
    repeat (timeout_us) #1000;
    $fatal(1, "global simulation timeout");
  end

  initial begin
    if (!$value$plusargs("PLAN=%s", plan_path)) $fatal(1, "PLAN required");
    fp = $fopen(plan_path, "r");
    if (!fp) $fatal(1, "open plan");
    repeat (5) @(negedge clk); rst = 0; repeat (5) @(negedge clk);
    while ($fscanf(fp, "%s %s %s %d %d\n", cfg_path, in_path, exp_path, frames, n) == 5) begin
      seg = seg + 1;
      fc = $fopen(cfg_path, "r");
      if (!fc) $fatal(1, "open %s", cfg_path);
      while ($fscanf(fc, "%h %h\n", a, d) == 2) cfg_write(a, d);
      $fclose(fc);
      @(negedge clk);
      if (cfg_err || n_bits != n) $fatal(1, "segment %0d: configuration not applied (n_bits=%0d)", seg, n_bits);
      fi = $fopen(in_path, "r"); fe = $fopen(exp_path, "r");
      $sformat(out_path, "output_segment%0d.txt", seg);
      fo = $fopen(out_path, "w");
      if (!fi || !fe || !fo) $fatal(1, "segment %0d: open data files", seg);
      errs = 0;
      for (t = 1; t <= frames; t = t + 1) begin
        for (j = 0; j < n; j = j + 1) begin
          r = $fscanf(fi, "%b", sample[j]);
          if (r != 1) $fatal(1, "segment %0d input frame %0d sample %0d", seg, t, j);
        end
        transaction(n, cycles);
        $display("CORE_DECODE_CYCLES segment=%0d transaction=%0d cycles=%0d", seg, t, cycles);
        if (t >= 3) begin
          r = $fscanf(fe, "%b", expected_word);
          if (r != 1) $fatal(1, "segment %0d expected frame missing", seg);
          d = 0;
          for (j = 0; j < n; j = j + 1) begin
            $fwrite(fo, "%b", decoded[j]);
            if (decoded[j] !== expected_word[n-1-j]) d = d + 1;
          end
          $fwrite(fo, "\n");
          errs = errs + d; compared = compared + n;
          $display("FRAME_COMPARE segment=%0d output=%0d bit_errors=%0d", seg, t - 2, d);
        end
      end
      $fclose(fi); $fclose(fe); $fclose(fo);
      total_errors = total_errors + errs;
      $display("SEGMENT_DONE segment=%0d config=%s n=%0d frames=%0d bit_errors=%0d", seg, cfg_path, n, frames - 2, errs);
    end
    // Negative check: a configuration write while busy is refused.
    for (j = 0; j < n; j = j + 1) sample[j] = 5'd0;
    @(negedge clk) start = 1;
    @(negedge clk) start = 0;
    repeat (3) @(negedge clk);
    if (!busy) $fatal(1, "core not busy for the busy-write check");
    cfg_write(12'h000, (n_bits == 648) ? 8'd54 : 8'd27);
    while (busy) @(negedge clk);
    if (!cfg_err || n_bits != n) $fatal(1, "FAIL_CFG_GUARD cfg_err=%0d n_bits=%0d", cfg_err, n_bits);
    $display("CFG_GUARD_OK write while busy rejected, cfg_err=1, n_bits=%0d", n_bits);
    if (total_errors != 0) $fatal(1, "FAIL_ADAPTIVE segments=%0d bit_errors=%0d", seg, total_errors);
    $display("PASS_ADAPTIVE segments=%0d compared_bits=%0d", seg, compared);
    $finish;
  end
endmodule
