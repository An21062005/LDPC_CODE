 //-----------------------------------------------------
// Design Name : RAM_SP_SR_RW
// File Name  : RAM_SP_SR_RW.v
// Function  : Single port Synchronous read and write RAM
//-----------------------------------------------------
module RAM_SP_SR_RW 
#(
  parameter DATA_WIDTH = 8 ,
  parameter ADDR_WIDTH = 8 ,
  parameter RAM_DEPTH  = 1 << ADDR_WIDTH
)
(
  input  logic                  clk   , // Clock Input
  input  logic [ADDR_WIDTH-1:0] address , // Address Input
  input  logic [DATA_WIDTH-1:0] data_in , // Data Input
  output logic [DATA_WIDTH-1:0] data_out , // Data Output
  input  logic                  we    , // Write Enable
  input  logic                  cs   ,  // Chip select
  input  logic                  reset      
);

  //This defines a memory bank of size RAM_DEPTH storing word of size DATA_WIDTH
  logic [DATA_WIDTH-1:0] ram_mem [0:RAM_DEPTH-1] ;
  logic [RAM_DEPTH-1:0] valid;


  //------------------------------------------------------
  // Single-port synchronous RAM.  Do not reset every RAM data bit: that
  // prevents Vivado from inferring FPGA memory and implements the array as
  // thousands of flip-flops.  The validity bitmap preserves the externally
  // visible reset behavior (an unwritten location reads as zero).
  //------------------------------------------------------
  always @(posedge clk) begin
    if(cs && we)
      ram_mem[address] <= data_in;
  end

  always @(posedge clk or posedge reset) begin
    if(reset) begin
      data_out <= '0;
      valid <= '0;
    end
    else if(cs) begin
      if(we)
        valid[address] <= 1'b1;
      else
        data_out <= valid[address] ? ram_mem[address] : '0;
    end
  end

endmodule
