// Variable-node unit of degree DV with the arithmetic of da2 VNU.v.
//
// Changed from VNU.v: the degree is a parameter and the adder width grows with
// it (da2 has DV=3 and 7-bit adders; the 802.11n code has DV up to 12, whose
// sums need 9 bits). Kept from VNU.v: sign-magnitude -> two's complement input
// (S_to_T), intrinsic sign extension, total-minus-own extrinsic sum, hard
// decision = sign of the total, |sum| -> LUT.v (phi), output {hd, sign, phi},
// two pipeline stages both gated by en, so the latency is identical.
// LUT.v maps every index >= 64 to 0, so clamping |sum| to 127 (7-bit LUT
// index) changes no value. tests/tb_units_equiv.sv checks DV=3 against VNU.v.
`default_nettype none

module VNU_G #(
  parameter integer DV = 3
)(
  input  wire [DV-1:0][4:0] X,          // check->variable, sign-magnitude
  input  wire [4:0]         Z,          // intrinsic, two's complement
  input  wire               clk,
  input  wire               en,
  output reg  [DV-1:0][5:0] Y,          // {hard decision, sign, phi}
  output reg                hard_decision
);
  localparam integer W = $clog2(16 + 15*DV) + 2;   // signed width, no overflow

  reg  signed [W-1:0] z_q;
  reg  signed [W-1:0] x_q [0:DV-1];
  reg  signed [W-1:0] total;
  reg  signed [W-1:0] ext  [0:DV-1];
  reg         [6:0]   idx  [0:DV-1];
  wire        [3:0]   phi  [0:DV-1];
  integer i;

  initial begin
    z_q = '0; Y = '0; hard_decision = 1'b0;
    for (i = 0; i < DV; i = i + 1) x_q[i] = '0;
  end

  always @* begin
    total = z_q;
    for (i = 0; i < DV; i = i + 1) total = total + x_q[i];
    for (i = 0; i < DV; i = i + 1) begin
      ext[i] = total - x_q[i];
      idx[i] = ((ext[i] < 0 ? -ext[i] : ext[i]) > 127) ? 7'd127 : (ext[i] < 0 ? -ext[i] : ext[i]);
    end
  end

  genvar g;
  for (g = 0; g < DV; g = g + 1) begin : g_lut
    LUT lut (.X(idx[g]), .Y(phi[g]));
  end

  always @(posedge clk) begin
    if (en) begin
      z_q <= {{(W-5){Z[4]}}, Z};
      for (i = 0; i < DV; i = i + 1)
        x_q[i] <= X[i][4] ? -$signed({{(W-4){1'b0}}, X[i][3:0]}) : $signed({{(W-4){1'b0}}, X[i][3:0]});
      hard_decision <= (total < 0);
      for (i = 0; i < DV; i = i + 1)
        Y[i] <= {(total < 0), (ext[i] < 0), phi[i]};
    end
  end
endmodule

`default_nettype wire
