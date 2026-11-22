// Convert number from Two's complement to Signed format

module T_to_S #(
  parameter DATA_WIDTH = 7
) 
(
  input wire  [DATA_WIDTH - 1 : 0] inp,
  output wire [DATA_WIDTH : 0] out      // 'out' will have one extra bit than 'inp'
);

reg [DATA_WIDTH : 0] x;

always @* begin
  x[DATA_WIDTH] = inp[DATA_WIDTH-1];
  if (inp[DATA_WIDTH-1] == 1'b1)
    x[DATA_WIDTH-1:0] = (~inp)+1'b1;
  else
    x[DATA_WIDTH-1:0] = inp;
end

assign out = x;

endmodule
