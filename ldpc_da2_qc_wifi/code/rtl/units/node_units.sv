// Port adapters used by every core in this project. Same ports as
// ldpc_da2_configurable/code/rtl/common/node_units.sv, but the degree is free:
// the 802.11n rate-1/2 code has VN degrees 2, 3, 12 and CN degrees 7, 8.
`default_nettype none

module vn_unit #(
  parameter integer DV = 3
)(
  input  wire              clk,
  input  wire              en,
  input  wire [4:0]        z,
  input  wire [DV*5-1:0]   x,
  output wire [DV*6-1:0]   y,
  output wire              hd
);
  wire [DV-1:0][4:0] vx = x;
  wire [DV-1:0][5:0] vy;
  VNU_G #(.DV(DV)) vnu (.X(vx), .Z(z), .clk(clk), .en(en), .Y(vy), .hard_decision(hd));
  assign y = vy;
endmodule

module cn_unit #(
  parameter integer DC = 6
)(
  input  wire              clk,
  input  wire              en,
  input  wire [DC*6-1:0]   x,
  output wire [DC*5-1:0]   y,
  output wire              parity
);
  wire [DC-1:0][5:0] cx = x;
  wire [DC-1:0][4:0] cy;
  CNU_G #(.DC(DC)) cnu (.X(cx), .clk(clk), .en(en), .Y(cy), .p_bit(parity));
  assign y = cy;
endmodule

`default_nettype wire
