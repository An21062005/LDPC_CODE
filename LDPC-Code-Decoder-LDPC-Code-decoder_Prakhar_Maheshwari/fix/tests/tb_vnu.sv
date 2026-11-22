`timescale 1ns/1ps

`include "Utilities/full_adder.v"
`include "Utilities/6-bit-ripple_carry_adder.v"
`include "Utilities/LUT.v"
`include "Utilities/S_to_T.v"
`include "Utilities/T_to_S.v"
`include "VNU/VNU.v"

module tb_vnu;
  logic clk=0;
  always #5 clk=~clk;
  logic [2:0][4:0] X;
  logic [4:0] Z;
  logic en;
  wire [2:0][5:0] Y;
  wire hard_decision;
  integer i;

  VNU dut(.X(X),.Z(Z),.clk(clk),.en(en),.Y(Y),.hard_decision(hard_decision));

  task clock_pipeline;
    begin
      @(posedge clk); #1;
      @(posedge clk); #1;
    end
  endtask

  initial begin
    en=1; X='0;
    Z=5'b00101; // +5 in two's complement
    clock_pipeline();
    if(hard_decision!==0) $fatal(1,"VNU positive hard decision failed");
    for(i=0;i<3;i=i+1)
      if(Y[i]!==6'b000010) $fatal(1,"VNU positive output failed i=%0d actual=%b",i,Y[i]);

    Z=5'b11011; // -5 in two's complement
    clock_pipeline();
    if(hard_decision!==1) $fatal(1,"VNU negative hard decision failed");
    for(i=0;i<3;i=i+1)
      if(Y[i]!==6'b110010) $fatal(1,"VNU negative output failed i=%0d actual=%b",i,Y[i]);

    $display("PASS tb_vnu");
    $finish;
  end
endmodule
