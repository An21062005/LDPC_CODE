`timescale 1ns/1ps

`include "permutations/PI_1_shuffle.v"
`include "permutations/PI_1_unshuffle.v"
`include "permutations/PI_2_shuffle.v"
`include "permutations/PI_2_unshuffle.v"
`include "permutations/PI_3_shuffle.v"
`include "permutations/PI_3_unshuffle.v"

module tb_permutations;
  logic clk=0, reset;
  always #5 clk=~clk;
  logic [35:0][5:0] din;
  wire [35:0][5:0] p1_mid,p1_out,p2_mid,p2_out,p3_mid,p3_out;
  integer i,cycle;

  PI_1_shuffle s1(.data_in(din),.data_out(p1_mid));
  PI_1_unshuffle u1(.data_in(p1_mid),.data_out(p1_out));
  PI_2_shuffle s2(.data_in(din),.data_out(p2_mid));
  PI_2_unshuffle u2(.data_in(p2_mid),.data_out(p2_out));
  PI_3_shuffle #(.START_STATE(0)) s3(.data_in(din),.clk(clk),.reset(reset),.data_out(p3_mid));
  PI_3_unshuffle #(.START_STATE(0)) u3(.data_in(p3_mid),.clk(clk),.reset(reset),.data_out(p3_out));

  task check_equal(input [35:0][5:0] actual, input integer which);
    begin
      for(i=0;i<36;i=i+1)
        if(actual[i]!==din[i]) $fatal(1,"PI%0d round-trip failed cycle=%0d index=%0d",which,cycle,i);
    end
  endtask

  initial begin
    for(i=0;i<36;i=i+1) din[i]=i;
    #1; cycle=0; check_equal(p1_out,1); check_equal(p2_out,2);
    reset=0; @(posedge clk); #1; check_equal(p3_out,3);
    reset=1;
    for(cycle=1;cycle<32;cycle=cycle+1) begin
      @(posedge clk); #1; check_equal(p3_out,3);
    end
    $display("PASS tb_permutations");
    $finish;
  end
endmodule
