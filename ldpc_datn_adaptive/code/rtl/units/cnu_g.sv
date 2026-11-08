// Check-node unit of degree DC with the arithmetic of da2 CNU.v.
//
// Changed from CNU.v: the degree is a parameter (802.11n rate 1/2 has DC 7
// and 8; da2 has 6). Kept from CNU.v: one register stage gated by en holding
// the input phi magnitudes, signs, sign XOR and parity; outputs computed
// combinationally from those registers: magnitude = LUT.v(sum of the other
// phi values, 7-bit), sign = XOR of the other signs, p_bit = XOR of the hard
// decisions. Sums stay below 128 for DC <= 9. tests/tb_units_equiv.sv checks
// DC=6 against CNU.v.
`default_nettype none

module CNU_G #(
  parameter integer DC = 6,
  parameter integer NZ = DC          // max inputs that can be non-zero (others tied 0)
)(
  input  wire [DC-1:0][5:0] X,          // {hard decision, sign, phi}
  input  wire               clk,
  input  wire               en,
  output wire [DC-1:0][4:0] Y,          // check->variable, sign-magnitude
  output wire               p_bit
);
  reg [3:0] phi_q  [0:DC-1];
  reg       sign_q [0:DC-1];
  reg       sign_xor_q, parity_q;
  reg [6:0] sum, other [0:DC-1];
  integer i;

  // synthesis translate_off
  initial if (NZ*15 > 127) $fatal(1, "CNU_G: NZ=%0d non-zero inputs overflow the 7-bit sum", NZ);
  // synthesis translate_on
  initial begin
    sign_xor_q = 1'b0; parity_q = 1'b0;
    for (i = 0; i < DC; i = i + 1) begin phi_q[i] = '0; sign_q[i] = 1'b0; end
  end

  always @(posedge clk) begin
    if (en) begin
      for (i = 0; i < DC; i = i + 1) begin phi_q[i] <= X[i][3:0]; sign_q[i] <= X[i][4]; end
      sign_xor_q <= xor_signs(X);
      parity_q   <= xor_hd(X);
    end
  end

  function automatic logic xor_signs(input [DC-1:0][5:0] v);
    xor_signs = 1'b0;
    for (int k = 0; k < DC; k++) xor_signs ^= v[k][4];
  endfunction
  function automatic logic xor_hd(input [DC-1:0][5:0] v);
    xor_hd = 1'b0;
    for (int k = 0; k < DC; k++) xor_hd ^= v[k][5];
  endfunction

  always @* begin
    sum = '0;
    for (i = 0; i < DC; i = i + 1) sum = sum + phi_q[i];
    for (i = 0; i < DC; i = i + 1) other[i] = sum - phi_q[i];
  end

  genvar g;
  for (g = 0; g < DC; g = g + 1) begin : g_out
    LUT lut (.X(other[g]), .Y(Y[g][3:0]));
    assign Y[g][4] = sign_xor_q ^ sign_q[g];
  end
  assign p_bit = parity_q;
endmodule

`default_nettype wire
