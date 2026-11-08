// Simulation-only second top level for tb_axi: measures, in decoder-clock
// cycles, the core decode time and the whole transaction (load + decode +
// read-back inside the wrapper) for every transaction. It only observes
// signals; it does not drive anything.
//   ARCH_PP defined : da2 core, decode = decoder_enable rise -> f_id toggle
//   otherwise       : new cores, decode = ldpc_core.busy high
`timescale 1ns/1ps

module core_monitor;
  wire clk  = tb_axi.dut.decoder_clk;
  wire txn  = tb_axi.dut.busy_decoder;
`ifdef ARCH_PP
  wire en   = tb_axi.dut.decoder_enable;
  wire fid  = tb_axi.dut.f_id_core;
  reg  fid0 = 1'b0;
  wire dec  = en && (fid == fid0);
  always @(posedge en) fid0 = fid;
`else
  wire dec  = tb_axi.dut.core_busy;
`endif
  integer n = 0, dec_cycles = 0, txn_cycles = 0;
  reg txn_q = 1'b0;
  always @(posedge clk) begin
    if (txn) txn_cycles = txn_cycles + 1;
    if (txn && dec) dec_cycles = dec_cycles + 1;
    if (txn_q && !txn) begin
      n = n + 1;
      $display("CORE_CYCLES transaction=%0d decode=%0d transaction_total=%0d", n, dec_cycles, txn_cycles);
      dec_cycles = 0; txn_cycles = 0;
    end
    txn_q = txn;
  end
endmodule
