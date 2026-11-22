`timescale 1ns/1ps

`include "Utilities/full_adder.v"
`include "Utilities/6-bit-ripple_carry_adder.v"
`include "Utilities/LUT.v"
`include "Utilities/S_to_T.v"
`include "Utilities/T_to_S.v"

module tb_utilities;
  logic fa_x, fa_y, fa_ci;
  wire fa_s, fa_co;
  logic [5:0] add_x, add_y;
  wire [5:0] add_s;
  wire add_co;
  logic [4:0] st_in;
  wire [4:0] st_out;
  logic [6:0] ts_in;
  wire [7:0] ts_out;
  logic [6:0] lut_in;
  wire [3:0] lut_out;
  integer i, j, k;
  integer expected;

  fulladder fa(.X(fa_x), .Y(fa_y), .C_in(fa_ci), .S(fa_s), .C_out(fa_co));
  ripple_adder ra(.X(add_x), .Y(add_y), .S(add_s), .C_out(add_co));
  S_to_T st(.inp(st_in), .out(st_out));
  T_to_S ts(.inp(ts_in), .out(ts_out));
  LUT lut(.X(lut_in), .Y(lut_out));

  initial begin
    for (i=0; i<2; i=i+1)
      for (j=0; j<2; j=j+1)
        for (k=0; k<2; k=k+1) begin
          fa_x=i; fa_y=j; fa_ci=k; #1;
          expected=i+j+k;
          if ({fa_co,fa_s} !== expected[1:0])
            $fatal(1,"fulladder failed x=%0d y=%0d ci=%0d",i,j,k);
        end

    for (i=0; i<64; i=i+1)
      for (j=0; j<64; j=j+1) begin
        add_x=i; add_y=j; #1;
        expected=i+j;
        if ({add_co,add_s} !== expected[6:0])
          $fatal(1,"ripple_adder failed x=%0d y=%0d",i,j);
      end

    // Exhaustive 5-bit sign-magnitude to two's-complement conversion.
    for (i=0; i<32; i=i+1) begin
      st_in=i; #1;
      expected = (i & 16) ? (-(i & 15)) : (i & 15);
      if (st_out !== (expected & 31))
        $fatal(1,"S_to_T failed input=%b expected=%b actual=%b",st_in,(expected&31),st_out);
    end

    // Exhaustive 7-bit two's-complement to {sign,magnitude} conversion.
    for (i=0; i<128; i=i+1) begin
      ts_in=i; #1;
      if (i & 64) expected = 128 + ((128-i) & 127);
      else        expected = i;
      if (ts_out !== expected[7:0])
        $fatal(1,"T_to_S failed input=%b expected=%b actual=%b",ts_in,expected[7:0],ts_out);
    end

    lut_in=6'b000000; #1; if(lut_out!==4'b1111) $fatal(1,"LUT x=0 failed");
    lut_in=6'b000101; #1; if(lut_out!==4'b0010) $fatal(1,"LUT x=5 failed");
    lut_in=6'b001100; #1; if(lut_out!==4'b0000) $fatal(1,"LUT x=12 failed");
    $display("PASS tb_utilities");
    $finish;
  end
endmodule
