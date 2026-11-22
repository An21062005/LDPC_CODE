`timescale 1ns/1ps

`include "memory/RAM_SP_SR_RW.v"
`include "address_generator/ADDRESS_GENERATOR.v"

module tb_memory_ag;
  logic clk=0;
  always #5 clk=~clk;

  logic [2:0] address;
  logic [4:0] data_in;
  wire [4:0] data_out;
  logic we, cs, reset;
  logic ag_en, ag_reset;
  wire [2:0] ag_out;
  integer i;

  RAM_SP_SR_RW #(.DATA_WIDTH(5),.ADDR_WIDTH(3),.RAM_DEPTH(8)) ram(
    .clk(clk),.address(address),.data_in(data_in),.data_out(data_out),
    .we(we),.cs(cs),.reset(reset));
  ADDRESS_GENERATOR #(.DATA_WIDTH(3),.COUNT_FROM(3)) ag(
    .clk(clk),.en(ag_en),.reset(ag_reset),.out(ag_out));

  initial begin
    address=0; data_in=0; we=0; cs=0; reset=0; ag_en=0; ag_reset=0;
    #1 reset=1; #1 reset=0;
    for(i=0;i<8;i=i+1) begin
      address=i; data_in=(i*3+1); we=1; cs=1; @(posedge clk); #1;
    end
    we=0;
    for(i=0;i<8;i=i+1) begin
      address=i; cs=1; @(posedge clk); #1;
      if(data_out !== ((i*3+1)&31)) $fatal(1,"RAM read failed address=%0d",i);
    end
    reset=1; #1; reset=0;
    for(i=0;i<8;i=i+1) begin
      address=i; cs=1; we=0; @(posedge clk); #1;
      if(data_out !== 0) $fatal(1,"RAM reset failed address=%0d",i);
    end

    ag_en=1; ag_reset=1; @(posedge clk); #1;
    if(ag_out!==3) $fatal(1,"AG reset/start failed");
    ag_reset=0;
    for(i=4;i<=7;i=i+1) begin
      @(posedge clk); #1;
      if(ag_out!==i[2:0]) $fatal(1,"AG count failed expected=%0d actual=%0d",i,ag_out);
    end
    $display("PASS tb_memory_ag");
    $finish;
  end
endmodule
