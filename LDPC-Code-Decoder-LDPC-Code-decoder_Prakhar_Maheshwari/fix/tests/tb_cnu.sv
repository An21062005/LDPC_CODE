`timescale 1ns/1ps

`include "Utilities/full_adder.v"
`include "Utilities/6-bit-ripple_carry_adder.v"
`include "Utilities/LUT.v"
`include "CNU/CNU.v"

module tb_cnu;
  logic clk=0;
  always #5 clk=~clk;
  logic [5:0][5:0] X;
  logic en;
  wire [5:0][4:0] Y;
  wire p_bit;
  integer i;

  CNU dut(.X(X),.clk(clk),.en(en),.Y(Y),.p_bit(p_bit));

  initial begin
    en=1;
    for(i=0;i<6;i=i+1) X[i]=6'b000001;
    @(posedge clk); #1;
    if(p_bit!==0) $fatal(1,"CNU parity all-zero failed");
    for(i=0;i<6;i=i+1)
      if(Y[i]!==5'b00010) $fatal(1,"CNU positive case failed output=%0d actual=%b",i,Y[i]);

    // One negative sign at input 0: output 0 excludes that sign; all others include it.
    X[0]=6'b010001;
    @(posedge clk); #1;
    if(Y[0][4]!==0) $fatal(1,"CNU exclude-own-sign failed");
    for(i=1;i<6;i=i+1)
      if(Y[i][4]!==1) $fatal(1,"CNU sign product failed output=%0d",i);

    X[0][5]=1; X[3][5]=1;
    @(posedge clk); #1;
    if(p_bit!==0) $fatal(1,"CNU even parity failed");
    X[3][5]=0;
    @(posedge clk); #1;
    if(p_bit!==1) $fatal(1,"CNU odd parity failed");
    $display("PASS tb_cnu");
    $finish;
  end
endmodule
