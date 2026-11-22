`timescale 1ns/1ps

// Simulation-only monitor. It binds to signals that exist in both the RTL
// wrapper and the synthesized functional netlist.
module wrapper_trace_monitor (
  input wire        trace_clk,
  input wire        trace_resetn,
  input wire        trace_f_id,
  input wire [35:0] trace_dec_out,
  input wire        trace_freeze,
  input wire        trace_cnu_active
);
  integer trace_fd;
  integer trace_cycle;
  reg [1023:0] trace_path;

  initial begin
    trace_cycle = 0;
    if(!$value$plusargs("TRACE_FILE=%s", trace_path))
      trace_path = "wrapper_trace_v2.txt";
    trace_fd = $fopen(trace_path, "w");
    if(!trace_fd)
      $fatal(1, "cannot open trace output");
  end

  always @(posedge trace_clk) begin
    if(trace_resetn) begin
      $fwrite(trace_fd, "%0d %b %b %b %b\n", trace_cycle, trace_f_id,
              trace_freeze, trace_cnu_active, trace_dec_out);
      trace_cycle = trace_cycle + 1;
    end
  end
endmodule

module wrapper_trace_binding;
  bind LDPC_Decoder_PYNQ_Z2_top wrapper_trace_monitor trace_monitor_i (
    .trace_clk(decoder_clk_df),
    .trace_resetn(s_axi_aresetn),
    .trace_f_id(f_id_core),
    .trace_dec_out(dec_out_flat),
    .trace_freeze(decoder_core.freeze_decisions),
    .trace_cnu_active(decoder_core.cnu_active)
  );
endmodule
