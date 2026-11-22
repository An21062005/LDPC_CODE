// Unit equivalence test: the generalised units must equal the unchanged da2
// units at the da2 degrees, cycle by cycle, for random inputs and random en.
//   VNU_G #(3) vs da2 VNU.v      CNU_G #(6) vs da2 CNU.v
// Purpose: show that the Wi-Fi decoders reuse the da2 arithmetic exactly.
`timescale 1ns/1ps

module tb_units_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg en_v = 0, en_c = 0;
  reg [2:0][4:0] vx; reg [4:0] vz;
  reg [5:0][5:0] cx;
  wire [2:0][5:0] y_ref, y_gen; wire hd_ref, hd_gen;
  wire [5:0][4:0] c_ref, c_gen; wire p_ref, p_gen;

  VNU   ref_v (.X(vx), .Z(vz), .clk(clk), .en(en_v), .Y(y_ref), .hard_decision(hd_ref));
  VNU_G #(.DV(3)) gen_v (.X(vx), .Z(vz), .clk(clk), .en(en_v), .Y(y_gen), .hard_decision(hd_gen));
  CNU   ref_c (.X(cx), .clk(clk), .en(en_c), .Y(c_ref), .p_bit(p_ref));
  CNU_G #(.DC(6)) gen_c (.X(cx), .clk(clk), .en(en_c), .Y(c_gen), .p_bit(p_gen));

  integer cycle, errors = 0, vectors = 200000, seed = 1;
  initial begin
    if ($value$plusargs("VECTORS=%d", vectors)) begin end
    vx = '0; vz = '0; cx = '0;
    repeat (3) @(posedge clk);
    for (cycle = 0; cycle < vectors; cycle = cycle + 1) begin
      @(negedge clk);
      if (cycle > 2 && ({y_ref, hd_ref} !== {y_gen, hd_gen} || {c_ref, p_ref} !== {c_gen, p_gen})) begin
        errors = errors + 1;
        if (errors <= 5) $display("MISMATCH cycle=%0d vnu ref=%h gen=%h cnu ref=%h gen=%h", cycle,
                                  {y_ref, hd_ref}, {y_gen, hd_gen}, {c_ref, p_ref}, {c_gen, p_gen});
      end
      vx = {$random(seed), $random(seed)}; vz = $random(seed);
      cx = {$random(seed), $random(seed)};
      en_v = ($random(seed) % 4) != 0; en_c = ($random(seed) % 4) != 0;
    end
    if (errors) $fatal(1, "FAIL_UNITS mismatches=%0d of %0d cycles", errors, vectors);
    $display("PASS_UNITS cycles=%0d VNU_G(3)==VNU CNU_G(6)==CNU", vectors);
    $finish;
  end
endmodule
