// Parameterized ripple-carry adder.  CNU/VNU sums require seven bits.
module ripple_adder #(
  parameter WIDTH = 6
)(
  input [WIDTH-1:0] X,
  input [WIDTH-1:0] Y,

  output [WIDTH-1:0] S,
  output C_out
  );

 wire [WIDTH:0] carry;
 assign carry[0] = 1'b0;

 genvar bit_index;
 generate
   for (bit_index=0; bit_index<WIDTH; bit_index=bit_index+1) begin : add_bits
     fulladder u_add(
       .X(X[bit_index]), .Y(Y[bit_index]), .C_in(carry[bit_index]),
       .S(S[bit_index]), .C_out(carry[bit_index+1])
     );
   end
 endgenerate

 assign C_out = carry[WIDTH];

endmodule
