// Port adapters so the Serial and Fully-Parallel cores instantiate the
// UNCHANGED da2 arithmetic units (da2_core/VNU/VNU.v, da2_core/CNU/CNU.v).
// The (1152,580) code is (3,6)-regular, so only DV=3 and DC=6 are legal.
`default_nettype none

module vn_unit #(
  parameter integer DV = 3
)(
  input  wire              clk,
  input  wire              en,
  input  wire [4:0]        z,        // intrinsic, two's complement
  input  wire [DV*5-1:0]   x,        // check->variable, sign-magnitude
  output wire [DV*6-1:0]   y,        // {hard decision, sign, phi magnitude}
  output wire              hd
);
  if (DV != 3) begin : g_illegal
    // synthesis translate_off
    initial $fatal(1, "vn_unit: da2 VNU supports DV=3 only (DV=%0d)", DV);
    // synthesis translate_on
  end
  wire [2:0][4:0] vx = x;
  wire [2:0][5:0] vy;
  VNU vnu (.X(vx), .Z(z), .clk(clk), .en(en), .Y(vy), .hard_decision(hd));
  assign y = vy;
endmodule

module cn_unit #(
  parameter integer DC = 6
)(
  input  wire              clk,
  input  wire              en,
  input  wire [DC*6-1:0]   x,        // {hard decision, sign, phi magnitude}
  output wire [DC*5-1:0]   y,        // check->variable, sign-magnitude
  output wire              parity    // XOR of the hard decisions
);
  if (DC != 6) begin : g_illegal
    // synthesis translate_off
    initial $fatal(1, "cn_unit: da2 CNU supports DC=6 only (DC=%0d)", DC);
    // synthesis translate_on
  end
  wire [5:0][5:0] cx = x;
  wire [5:0][4:0] cy;
  CNU cnu (.X(cx), .clk(clk), .en(en), .Y(cy), .p_bit(parity));
  assign y = cy;
endmodule

`default_nettype wire
