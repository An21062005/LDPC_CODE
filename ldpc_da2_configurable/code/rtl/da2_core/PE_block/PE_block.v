 //----------------------------------------------------------------------------------
// Design Name : PE_BLOCK
// File Name  : PE_BLOCK.v
// Function  : PE Memory Block for storing all information and performing VNU phase
//-----------------------------------------------------------------------------------

module PE_BLOCK 
#(
  parameter L=32,
  parameter K=6,
  parameter X=1,
  parameter Y=1,
  parameter ADDR_WIDTH=5,
  parameter RAM_DEPTH=1<<ADDR_WIDTH,
  parameter COUNT_FROM_1=0,
  parameter COUNT_FROM_2=0,
  parameter COUNT_FROM_3=0,
  parameter VNU_DELAY=4,
  parameter CNU_DELAY=8,
  parameter MESSAGE_WIDTH=5,
  parameter DECISION_WIDTH=1
)
(
  input  logic                     clk,               //clock
  input  logic                     clk_df,            //clock double frequency

  input  logic                     enable,            //enable pin
  input  logic                     freeze_decisions,  //valid-codeword early stop

  output logic                     enable_cnu,        //CNU enable pin

  input  logic                     reset,
  input logic ext_reset,
 //input logic testbench,

  output wire                     f_id,              //frame id
  output wire     [5:0]  relay,
  input  logic                     pe_select,         //PE_Block select line    
  
  input logic                      column_select,     //column_select line for reading decoded data

  input  logic [ADDR_WIDTH-1:0]    read_add_in,       //read address input for reading hard decision 
  output logic [ADDR_WIDTH-1:0]    read_add_out,      //read address output for reading hard decision

  input  logic [ADDR_WIDTH-1:0]    load_add_in,       //load address input for storing intrinsic data
  output logic [ADDR_WIDTH-1:0]    load_add_out,      //load address output for storing intrinsic data

  input  logic [K-1:0]             dec_in,            //hard decision input from previous block
  output logic [K-1:0]             dec_out,           //hard decision output to next block

  input  logic [MESSAGE_WIDTH-1:0] int_in,            //intrinsic message input from previous block
  output logic [MESSAGE_WIDTH-1:0] int_out,           //intrinsic message output to next block

  input  logic [((3*MESSAGE_WIDTH)-1):0] cnu_data_in , //input extrinsic messages from CNU
  output logic [(3*(MESSAGE_WIDTH+1))-1:0]   cnu_data_out  //output extrinsic messages to CNU
  
  
);

//------------Intrinsic RAM-----------------
logic [1:0][ADDR_WIDTH-1:0]    int_add      ;               //addresses for Intrinsic RAMs (INT_RAM)
logic [1:0][MESSAGE_WIDTH-1:0] int_data_in  ;               //data input for INT_RAMs  
logic      [1:0]               int_we       ;               //write enable for INT_RAMs
logic      [1:0]               int_cs       ;               //chip select for INT_RAMs   
logic [1:0][MESSAGE_WIDTH-1:0] int_data_out ;               //data output for INT_RAMs

logic [ADDR_WIDTH-1:0]         int_load_add;
logic [MESSAGE_WIDTH-1:0]      int_load_data;
logic                           int_load_we;
logic                           int_load_cs;
logic [ADDR_WIDTH-1:0]         int_decode_add;
logic                           int_decode_we;
logic                           int_decode_cs;

//------------Extrinsic RAM -----------------
logic [2:0][ADDR_WIDTH-1:0]    ext_add      ;               //address for Extrinsic RAM (EXT_RAM) 
logic [2:0][MESSAGE_WIDTH:0]   ext_data_in  ;               //data input for EXT_RAM  
logic                     ext_we            ;               //write enable for EXT_RAM  
logic                     ext_cs            ;               //chip select for EXT_RAM
logic [2:0][MESSAGE_WIDTH:0]   ext_data_out ;               //data output for EXT_RAM

// Separate state for the write and read half-cycles.  The physical EXT_RAM
// port below is driven by a single mux, so no net has multiple RTL drivers.
logic [2:0][ADDR_WIDTH-1:0]    ext_write_add;
logic [2:0][ADDR_WIDTH-1:0]    ext_read_add;
logic [2:0][MESSAGE_WIDTH:0]   ext_write_data;
logic                           ext_write_we;
logic                           ext_write_cs;
logic                           ext_read_we;
logic                           ext_read_cs;

//------------Decision RAM------------------
logic [1:0][ADDR_WIDTH-1:0]     dec_add      ;              //addresses for Decision RAMs (DEC_RAM)
logic [1:0][DECISION_WIDTH-1:0] dec_data_in  ;              //data input for DEC_RAMs      
logic      [1:0]                dec_we       ;              //write enable for DEC_RAMs
logic      [1:0]                dec_cs       ;              //chip select for DEC_RAMs
logic [1:0][DECISION_WIDTH-1:0] dec_data_out ;              //data output for DEC_RAMs

//---------Address Generator-----------------
logic                       ag_en            ;              //enable for address generator
logic [2:0][ADDR_WIDTH-1:0]      ag_out      ;              //output for address generator
logic                       ag_reset         ;              //reset for address generator

//-----------------VNU------------------------
logic [2:0][MESSAGE_WIDTH-1:0] vnu_ext_in    ;              //Extrinsic data input for VNU
logic [MESSAGE_WIDTH-1:0]   vnu_int_in       ;              //Intrinsic data input for VNU
logic [2:0][MESSAGE_WIDTH:0]vnu_ext_out      ;              //Extrinsic data output from VNU
logic [DECISION_WIDTH-1:0]  vnu_dec_out      ;              //Decision data output from VNU
logic                       vnu_en           ;              //enable pin for VNU



logic                       rs          ;             //RAM select to shift focus between data frames   
integer                     itr_count      ;             //count the number of iterations
logic extended;

// Synthesizable controller replacing the simulation-only event waits that
// previously controlled the VNU/CNU phase changes.
localparam [1:0] CTRL_IDLE  = 2'd0;
localparam [1:0] CTRL_RUN   = 2'd1;
localparam [1:0] CTRL_FLUSH = 2'd2;
localparam [1:0] CTRL_RESET = 2'd3;
logic [1:0] ctrl_state;
integer flush_count;

logic [3:0][ADDR_WIDTH-1:0] mem_reg_add ;
logic [VNU_DELAY-1:0] mem_reg_add_valid;
logic [DECISION_WIDTH-1:0] mem_reg_dec ;
logic [MESSAGE_WIDTH-1:0] mem_reg_int ;
logic [2:0][MESSAGE_WIDTH-1:0] mem_reg_extin  ;
logic [2:0][MESSAGE_WIDTH:0] mem_reg_extout  ;

logic [7:0][ADDR_WIDTH-1:0] mem_reg_add_cnu1;
logic [7:0][ADDR_WIDTH-1:0] mem_reg_add_cnu2;
logic [7:0][ADDR_WIDTH-1:0] mem_reg_add_cnu3;
logic [CNU_DELAY-1:0] mem_reg_add_cnu_valid;
logic [2:0][MESSAGE_WIDTH-1:0] mem_reg_cnu_extin  ;
logic [2:0][MESSAGE_WIDTH:0] mem_reg_cnu_extout  ;


assign f_id=rs;
assign enable_cnu= ~vnu_en;
assign relay=ext_add[1];
assign ext_add = clk ? ext_write_add : ext_read_add;
assign ext_data_in = ext_write_data;
assign ext_we = clk ? ext_write_we : ext_read_we;
assign ext_cs = clk ? ext_write_cs : ext_read_cs;

always_comb begin
  int_add = '0;
  int_data_in = '0;
  int_we = '0;
  int_cs = '0;

  int_add[~rs] = int_load_add;
  int_data_in[~rs] = int_load_data;
  int_we[~rs] = int_load_we;
  int_cs[~rs] = int_load_cs;

  int_add[rs] = int_decode_add;
  int_we[rs] = int_decode_we;
  int_cs[rs] = int_decode_cs;
end

initial begin 
  rs=1'b0;
  itr_count=0;
  extended=0;
  int_load_add='0;
  int_load_data='0;
  int_load_we=1'b0;
  int_load_cs=1'b0;
  int_decode_add='0;
  int_decode_we=1'b0;
  int_decode_cs=1'b0;
  ext_write_add='0;
  ext_read_add='0;
  ext_write_data='0;
  ext_write_we=1'b0;
  ext_write_cs=1'b0;
  ext_read_we=1'b0;
  ext_read_cs=1'b0;
  dec_add='0;
  dec_data_in='0;
  dec_we='0;
  dec_cs='0;
  vnu_ext_in='0;
  vnu_int_in='0;
  cnu_data_out='0;
  mem_reg_add='0;
  mem_reg_add_valid='0;
  mem_reg_dec='0;
  mem_reg_int='0;
  mem_reg_extin='0;
  mem_reg_extout='0;
  mem_reg_add_cnu1='0;
  mem_reg_add_cnu2='0;
  mem_reg_add_cnu3='0;
  mem_reg_add_cnu_valid='0;
  mem_reg_cnu_extin='0;
  mem_reg_cnu_extout='0;
  dec_out='0;
  ctrl_state=CTRL_IDLE;
  flush_count=0;
  //$monitor("%b\t%b\t%b",ag_out[0],vnu_ext_out[0],mem_reg_add[3]);

end

//---------------------------------------------------------------------------
//---------------------Module Instantiation ---------------------------------
//---------------------------------------------------------------------------

INT_RAM #(MESSAGE_WIDTH,ADDR_WIDTH,RAM_DEPTH) int_ram
(
  .clk      (clk),
  .address  (int_add),
  .data_in  (int_data_in),
  .we       (int_we),
  .cs       (int_cs),
  .data_out (int_data_out),
  .reset    (reset)
);


genvar i;
generate
  for(i=0;i<3;i=i+1)begin : ext_ram_bank
    EXT_RAM #(MESSAGE_WIDTH+1,ADDR_WIDTH,RAM_DEPTH)ext_ram_i
    (
      .clk      (clk_df),
      .address  (ext_add[i]),
      .we       (ext_we),
      .cs       (ext_cs),
      .data_in  (ext_data_in[i]),
      .data_out (ext_data_out[i]),
      .reset    (ext_reset)
    );
  end
endgenerate


DEC_RAM #(DECISION_WIDTH,ADDR_WIDTH,RAM_DEPTH) dec_ram
(
  .clk      (clk),
  .address  (dec_add),
  .data_in  (dec_data_in),
  .we       (dec_we),
  .cs       (dec_cs),
  .data_out (dec_data_out),
  .reset    (reset)
);


ADDRESS_GENERATOR #(ADDR_WIDTH,COUNT_FROM_1) ag1
(
  .clk   (clk),
  .en    (ag_en),
  .reset (ag_reset),
  .out   (ag_out[0])
);

ADDRESS_GENERATOR #(ADDR_WIDTH,COUNT_FROM_2) ag2
(
  .clk   (clk),
  .en    (ag_en),
  .reset (ag_reset),
  .out   (ag_out[1])
);

ADDRESS_GENERATOR #(ADDR_WIDTH,COUNT_FROM_3) ag3
(
  .clk   (clk),
  .en    (ag_en),
  .reset (ag_reset),
  .out   (ag_out[2])
);

VNU vnu
(
  .X             (vnu_ext_in),
  .Z             (vnu_int_in),
  .clk           (clk),
  .Y             (vnu_ext_out),
  .hard_decision (vnu_dec_out),
  .en            (vnu_en)
);



//---------------------------------------------------------------------------
//---------------------Intrinsic Data Frame Loading--------------------------
//---------------------------------------------------------------------------

assign load_add_out=load_add_in;
assign int_out=int_in;

always @(posedge clk_df) begin
    if(!clk && pe_select) begin
        int_load_we <= 1'b1;
        int_load_cs <= 1'b1;
        int_load_add <= load_add_in;
        int_load_data <= int_in;
    end

    if(clk && pe_select) begin
        int_load_we <= 1'b1;
        int_load_cs <= 1'b0;
    end
end

always @(negedge clk) begin
  if(enable && vnu_en) begin
      int_decode_we <= 1'b0;
      int_decode_cs <= !extended;
      int_decode_add <= mem_reg_add[0];
  end
end

//-----------------------------------------------------------------------------
//-----------------------Hard Decision Frame Reading---------------------------
//-----------------------------------------------------------------------------
assign read_add_out = read_add_in;

always @(posedge clk_df) begin
    if(!clk && column_select) begin
        dec_we[~rs] <= 1'b0;
        dec_cs[~rs] <= 1'b1;
        dec_add[~rs] <= read_add_in;
    end

    if(clk && column_select) begin
        dec_we[~rs] <= 1'b1;
        dec_cs[~rs] <= 1'b0;
        // Forward the decision vector and replace this PE column's bit.
        // This also handles the Y=1 and Y=K boundary cases without an
        // out-of-range or empty part-select.
        dec_out = dec_in;
        dec_out[Y-1] = dec_data_out[~rs];
    end

    if(!clk && enable && vnu_en) begin
        dec_add[rs] <= mem_reg_add[3];
        dec_cs[rs] <= mem_reg_add_valid[VNU_DELAY-1];
        dec_we[rs] <= !freeze_decisions && mem_reg_add_valid[VNU_DELAY-1];
        dec_data_in[rs] <= mem_reg_dec;
    end
end

//------------------------------------------------------------------------------
//-----------------------PE/phase controller------------------------------------
//------------------------------------------------------------------------------
// All waits are represented by states and clock counts so this controller maps
// to flip-flops in hardware while retaining the original phase timing.
always @(posedge clk) begin
  if(reset) begin
    ag_en <= 1'b1;
    ag_reset <= 1'b1;
    vnu_en <= 1'b1;
    extended <= 1'b0;
    rs <= 1'b0;
    itr_count <= 0;
    flush_count <= 0;
    ctrl_state <= CTRL_IDLE;
  end
  else if(!enable) begin
    ag_en <= 1'b1;
    ag_reset <= 1'b1;
    vnu_en <= 1'b1;
    extended <= 1'b0;
    flush_count <= 0;
    ctrl_state <= CTRL_IDLE;
  end
  else begin
    ag_en <= 1'b1;
    case(ctrl_state)
      CTRL_IDLE: begin
        // ag_reset was sampled high on this edge; release it for the next edge.
        ag_reset <= 1'b0;
        vnu_en <= 1'b1;
        extended <= 1'b0;
        flush_count <= 0;
        ctrl_state <= CTRL_RUN;
      end

      CTRL_RUN: begin
        if(ag_out[0] == L-1) begin
          extended <= 1'b1;
          flush_count <= 0;
          ctrl_state <= CTRL_FLUSH;
        end
      end

      CTRL_FLUSH: begin
        if((!vnu_en && flush_count == CNU_DELAY-1) ||
           ( vnu_en && flush_count == VNU_DELAY-1)) begin
          ag_reset <= 1'b1;
          ctrl_state <= CTRL_RESET;
        end
        else begin
          flush_count <= flush_count + 1;
        end
      end

      CTRL_RESET: begin
        // ag_reset is sampled by the address generators on this edge.
        ag_reset <= 1'b0;
        vnu_en <= ~vnu_en;
        extended <= 1'b0;
        flush_count <= 0;
        ctrl_state <= CTRL_RUN;

        if(itr_count == 35) begin
          rs <= ~rs;
          itr_count <= 0;
        end
        else begin
          itr_count <= itr_count + 1;
        end
      end

      default: begin
        ag_reset <= 1'b1;
        vnu_en <= 1'b1;
        extended <= 1'b0;
        flush_count <= 0;
        ctrl_state <= CTRL_IDLE;
      end
    endcase
  end
end


// EXT_RAM has one physical port.  Keep the read and write half-cycle state in
// separate registers and select it with clk, instead of assigning ext_* from
// multiple clocked processes.
always @(posedge clk_df) begin
  if(!clk && enable) begin
    ext_write_we <= 1'b1;
    if(vnu_en) begin
      ext_write_cs <= mem_reg_add_valid[VNU_DELAY-1];
      ext_write_add[0] <= mem_reg_add[3];
      ext_write_add[1] <= mem_reg_add[3];
      ext_write_add[2] <= mem_reg_add[3];
      ext_write_data[0] <= mem_reg_extout[0];
      ext_write_data[1] <= mem_reg_extout[1];
      ext_write_data[2] <= mem_reg_extout[2];
    end
    else begin
      ext_write_cs <= mem_reg_add_cnu_valid[CNU_DELAY-1];
      ext_write_add[0] <= mem_reg_add_cnu1[7];
      ext_write_add[1] <= mem_reg_add_cnu2[7];
      ext_write_add[2] <= mem_reg_add_cnu3[7];
      ext_write_data[0] <= {1'b0, mem_reg_cnu_extin[0]};
      ext_write_data[1] <= {1'b0, mem_reg_cnu_extin[1]};
      ext_write_data[2] <= {1'b0, mem_reg_cnu_extin[2]};
    end
  end
end

always @(negedge clk) begin
  if(enable) begin
    ext_read_we <= 1'b0;
    ext_read_cs <= !extended;

    if(vnu_en) begin
      ext_read_add[0] <= mem_reg_add[0];
      ext_read_add[1] <= mem_reg_add[0];
      ext_read_add[2] <= mem_reg_add[0];
    end
    else begin
      ext_read_add[0] <= mem_reg_add_cnu1[0];
      ext_read_add[1] <= mem_reg_add_cnu2[0];
      ext_read_add[2] <= mem_reg_add_cnu3[0];
    end
  end
end


//----------------------------------------------------------------------------
//-------------------------------CNU Phase------------------------------------
//----------------------------------------------------------------------------

always @(posedge clk_df) begin
  if(clk && enable && !vnu_en)  begin
      mem_reg_cnu_extout[0] <= ext_data_out[0];
      mem_reg_cnu_extout[1] <= ext_data_out[1];
      mem_reg_cnu_extout[2] <= ext_data_out[2];


      mem_reg_add_cnu1[1] <= mem_reg_add_cnu1[0];
      mem_reg_add_cnu1[2] <= mem_reg_add_cnu1[1];
      mem_reg_add_cnu1[3] <= mem_reg_add_cnu1[2];
      mem_reg_add_cnu1[4] <= mem_reg_add_cnu1[3];
      mem_reg_add_cnu1[5] <= mem_reg_add_cnu1[4];
      mem_reg_add_cnu1[6] <= mem_reg_add_cnu1[5];
      mem_reg_add_cnu1[7] <= mem_reg_add_cnu1[6];

      mem_reg_add_cnu2[1] <= mem_reg_add_cnu2[0];
      mem_reg_add_cnu2[2] <= mem_reg_add_cnu2[1];
      mem_reg_add_cnu2[3] <= mem_reg_add_cnu2[2];
      mem_reg_add_cnu2[4] <= mem_reg_add_cnu2[3];
      mem_reg_add_cnu2[5] <= mem_reg_add_cnu2[4];
      mem_reg_add_cnu2[6] <= mem_reg_add_cnu2[5];
      mem_reg_add_cnu2[7] <= mem_reg_add_cnu2[6];

      mem_reg_add_cnu3[1] <= mem_reg_add_cnu3[0];
      mem_reg_add_cnu3[2] <= mem_reg_add_cnu3[1];
      mem_reg_add_cnu3[3] <= mem_reg_add_cnu3[2];
      mem_reg_add_cnu3[4] <= mem_reg_add_cnu3[3];
      mem_reg_add_cnu3[5] <= mem_reg_add_cnu3[4];
      mem_reg_add_cnu3[6] <= mem_reg_add_cnu3[5];
      mem_reg_add_cnu3[7] <= mem_reg_add_cnu3[6];

      mem_reg_add_cnu_valid[1] <= mem_reg_add_cnu_valid[0];
      mem_reg_add_cnu_valid[2] <= mem_reg_add_cnu_valid[1];
      mem_reg_add_cnu_valid[3] <= mem_reg_add_cnu_valid[2];
      mem_reg_add_cnu_valid[4] <= mem_reg_add_cnu_valid[3];
      mem_reg_add_cnu_valid[5] <= mem_reg_add_cnu_valid[4];
      mem_reg_add_cnu_valid[6] <= mem_reg_add_cnu_valid[5];
      mem_reg_add_cnu_valid[7] <= mem_reg_add_cnu_valid[6];

      {mem_reg_cnu_extin[0], mem_reg_cnu_extin[1], mem_reg_cnu_extin[2]} <= cnu_data_in;

      
      if(extended) begin
          mem_reg_add_cnu1[0] <= '0;
          mem_reg_add_cnu2[0] <= '0;
          mem_reg_add_cnu3[0] <= '0;
          mem_reg_add_cnu_valid[0] <= 1'b0;
      end
  
      else begin
          mem_reg_add_cnu1[0] <= ag_out[0];
          mem_reg_add_cnu2[0] <= ag_out[1];
          mem_reg_add_cnu3[0] <= ag_out[2];
          mem_reg_add_cnu_valid[0] <= 1'b1;
      end
      
  end
end

always @(posedge clk_df) begin
  if(!clk && enable && !vnu_en) begin


      cnu_data_out <={ mem_reg_cnu_extout[0], mem_reg_cnu_extout[1], mem_reg_cnu_extout[2]}; 

  end
end 


//---------------------------------------------------------------------------------
//------------------------------VNU Phase------------------------------------------
//---------------------------------------------------------------------------------

always @(posedge clk_df) begin
  if(clk && enable && vnu_en)  begin
    mem_reg_extin[0] <= ext_data_out[0][4:0];
    mem_reg_extin[1] <= ext_data_out[1][4:0];
    mem_reg_extin[2] <= ext_data_out[2][4:0];
    mem_reg_int <= int_data_out[rs];

    mem_reg_add[1] <= mem_reg_add[0];
    mem_reg_add[2] <= mem_reg_add[1];
    mem_reg_add[3] <= mem_reg_add[2];
    mem_reg_add_valid[1] <= mem_reg_add_valid[0];
    mem_reg_add_valid[2] <= mem_reg_add_valid[1];
    mem_reg_add_valid[3] <= mem_reg_add_valid[2];
    

    mem_reg_extout[0] <= vnu_ext_out[0];
    mem_reg_extout[1] <= vnu_ext_out[1];
    mem_reg_extout[2] <= vnu_ext_out[2];
    mem_reg_dec <= vnu_dec_out;
    
    if(extended) begin
        mem_reg_add[0] <= '0;
        mem_reg_add_valid[0] <= 1'b0;
    end

    else begin
        mem_reg_add[0] <= ag_out[0];
        mem_reg_add_valid[0] <= 1'b1;
    end
      
  end
end

always @(posedge clk_df) begin
  if(!clk && enable && vnu_en) begin
      vnu_ext_in[0] <= mem_reg_extin[0];
      vnu_ext_in[1] <= mem_reg_extin[1];
      vnu_ext_in[2] <= mem_reg_extin[2];
      vnu_int_in <= mem_reg_int;

  end
end 


//always @(ag_out[0]) begin
  //$display("%b\t%b\t%b\t%b\t",ag_out[0], cnu_data_in[0], cnu_data_in[1], cnu_data_in[2]);
//end


//-----------------------------------------------------------------------------------------
//--------------------------Flipping focus on data frames----------------------------------
//-----------------------------------------------------------------------------------------

  /*
  always @(testbench) begin
    if(testbench) begin
    
        ag_en=1;
        vnu_en=1'bz;
        ag_reset=1;

        repeat(1) @(posedge clk);
        for (int p=0; p<L ; p=p+1) begin
          repeat(1) @(negedge clk);
          int_add[0]=p;
          int_cs[0]=1;
          int_we[0]=1;
          int_data_in[0]=0;
          repeat(1) @(posedge clk);
          #1;
        end
        
        rs=0;
        vnu_en=1;

        
        wait(itr_count==2)begin
          vnu_en=1'bz;
          ag_reset=1;
          if(X==1 && Y==1) begin
            $display("i\tEXT1\tEXT2\tEXT3");
          for(int p=0;p<L;p=p+1) begin
            repeat(1) @(negedge clk_df);
            ext_add[0]=p;
            ext_add[1]=p;
            ext_add[2]=p;

            ext_cs=1;
            ext_we=0;
            
            repeat(1) @(posedge clk_df);
            #1;
            $display("%d\t%b\t%b\t%b",p,ext_data_out[0],ext_data_out[1],ext_data_out[2]);
            
                
          end
          end
          
        end
        
      end



    end
initial begin
  $monitor("%b\t%b\t%b\t%b\t%b\t%b\t%b\t%b\t",ag_out[0],ag_out[1],ag_out[2],cnu_data_in,cnu_data_out,mem_reg_add_cnu1[6],mem_reg_add_cnu2[6],mem_reg_add_cnu3[6]);
end
*/
endmodule
