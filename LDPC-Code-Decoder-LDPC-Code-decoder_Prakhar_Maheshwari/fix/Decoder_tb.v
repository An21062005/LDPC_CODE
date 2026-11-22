`timescale 1ms/1ns
// Testbench for LDPC_Decoder module

`include "Decoder.v"

module Decoder_tb ();
  parameter L = 32;
  parameter K = 6;
  parameter DATA_COUNT = 1152;     // L*K*K
  parameter ADDR_WIDTH = 5;    // log2L
  parameter MESSAGE_WIDTH = 5;
  parameter CNU_DATA_IN_WIDTH  = 6;
  parameter CNU_DATA_OUT_WIDTH = 5;
  parameter INTRINSIC_DATA_WIDTH = 5;


  // Full-image defaults for Run Behavioral Simulation in Vivado.
  // input.txt contains 696 payload frames followed by two zero flush frames.
  // The loop below generates its own flush frames, so only 696 are read.
  string inp_file_name =
"C:/Users/HOANG AN/Downloads/ldpc_code/LDPC-Code-Decoder-LDPC-Code-decoder_Prakhar_Maheshwari/input.txt";

  string out_file_name =
"C:/Users/HOANG AN/Downloads/ldpc_code/LDPC-Code-Decoder-LDPC-Code-decoder_Prakhar_Maheshwari/rtl_work/full_input_output.txt";

  string ordered_out_file_name =
"C:/Users/HOANG AN/Downloads/ldpc_code/LDPC-Code-Decoder-LDPC-Code-decoder_Prakhar_Maheshwari/rtl_work/full_input_output_ordered.txt";

  integer code_frames = 696;
  integer frame_dbg=0;
  integer payload_frame_dbg=0;
  integer scan_faults;
  integer count=0;
  integer t=0;
  integer flag;

  integer inp_fd;
  integer out_fd;
  integer ordered_out_fd;
  logic ext_reset;
  logic clk;
  logic clk_df;
  logic en;
  logic f_id;
  logic prev_f_id;
  logic [5:0] relay;
  logic reset;
  logic [K-1:0] column_select;
  logic [(K*K)-1:0] pe_select;
  logic [MESSAGE_WIDTH-1:0] int_in;
  logic [ADDR_WIDTH-1:0] load_add_in;
  logic [ADDR_WIDTH-1:0] read_add_in;
  logic [K-1:0][K-1:0] dec_out_fin ;
  logic [(L*K*K)-1:0] hard_dec;

  reg [5-1:0] curr_data;
  reg [5-1:0] int_data[0:(L*K*K)-1];
  reg [(L*K*K)-1:0] out_data;

  // Debug signals in normal codeword order (bit 1 through bit 1152), matching
  // the Simulink/expected-codeword files.  hard_dec itself uses the decoder's
  // internal 32 x 6 x 6 readout order.
  reg  [DATA_COUNT-1:0] noisy_codeword_ordered;
  wire [DATA_COUNT-1:0] decoded_codeword_ordered;
  wire [0:DATA_COUNT-1] input_codeword_1152;
  wire [0:DATA_COUNT-1] output_codeword_1152;
  wire [0:DATA_COUNT-1] corrected_difference_1152;
  wire [0:15]           input_bits_1_to_16;
  wire [0:15]           output_bits_1_to_16;
  wire [0:15]           difference_bits_1_to_16;
  wire [0:2]            input_bits_1_to_3;
  wire [0:2]            output_bits_1_to_3;
  wire [0:2]            difference_bits_1_to_3;
  reg                    input_codeword_valid;
  reg                    decoded_codeword_ordered_valid;
  wire                   output_codeword_valid;
  reg  [10:0]            corrected_bit_position;
  reg  [10:0]            corrected_bit_count;
  wire                   correction_detected;
  wire                   corrected_bit_before;
  wire                   corrected_bit_after;

  assign correction_detected = decoded_codeword_ordered_valid &&
                               (corrected_bit_count != 11'd0);
  assign corrected_bit_before = correction_detected ?
                                noisy_codeword_ordered[corrected_bit_position-1] : 1'b0;
  assign corrected_bit_after = correction_detected ?
                               decoded_codeword_ordered[corrected_bit_position-1] : 1'b0;
  assign output_codeword_valid = decoded_codeword_ordered_valid;

  // Human-facing buses use an ascending range so bit 1 is displayed on the
  // left and bit 1152 on the right.  The short 1..16 views make the injected
  // error at bit 8 readable without expanding a 1152-bit waveform.
  genvar dbg_bit;
  generate
    for(dbg_bit=0; dbg_bit<DATA_COUNT; dbg_bit=dbg_bit+1) begin: GEN_DBG_BIT
      assign input_codeword_1152[dbg_bit] = noisy_codeword_ordered[dbg_bit];
      // Hide the decoder's partial/X data until the complete frame is valid.
      assign output_codeword_1152[dbg_bit] = decoded_codeword_ordered_valid ?
             decoded_codeword_ordered[dbg_bit] : 1'b0;
      assign corrected_difference_1152[dbg_bit] =
             decoded_codeword_ordered_valid ?
             (noisy_codeword_ordered[dbg_bit] ^ decoded_codeword_ordered[dbg_bit]) :
             1'b0;
    end
  endgenerate

  assign input_bits_1_to_16 = input_codeword_1152[0:15];
  assign output_bits_1_to_16 = output_codeword_1152[0:15];
  assign difference_bits_1_to_16 = corrected_difference_1152[0:15];
  assign input_bits_1_to_3 = input_codeword_1152[0:2];
  assign output_bits_1_to_3 = output_codeword_1152[0:2];
  assign difference_bits_1_to_3 = corrected_difference_1152[0:2];

  // Same permutation previously performed by compare.py:
  // ordered[l + L*(K*y+x)] = hard_dec[K*K*l + K*x+y].
  genvar dbg_l;
  genvar dbg_x;
  genvar dbg_y;
  generate
    for(dbg_l=0; dbg_l<L; dbg_l=dbg_l+1) begin: GEN_DBG_L
      for(dbg_x=0; dbg_x<K; dbg_x=dbg_x+1) begin: GEN_DBG_X
        for(dbg_y=0; dbg_y<K; dbg_y=dbg_y+1) begin: GEN_DBG_Y
          assign decoded_codeword_ordered[dbg_l + L*(K*dbg_y + dbg_x)] =
                 hard_dec[K*K*dbg_l + K*dbg_x + dbg_y];
        end
      end
    end
  endgenerate

  LDPC_Decoder #(.L(L), 
                 .ADDR_WIDTH(ADDR_WIDTH), 
                 .MESSAGE_WIDTH(MESSAGE_WIDTH), 
                 .K(K),
                 .CNU_DATA_IN_WIDTH(CNU_DATA_IN_WIDTH),
                 .CNU_DATA_OUT_WIDTH(CNU_DATA_OUT_WIDTH),
                 .INTRINSIC_DATA_WIDTH(INTRINSIC_DATA_WIDTH)) decoder
  (
  .clk(clk),
  .clk_df(clk_df),
  .en(en),
  .f_id(f_id),
  .column_select(column_select),
  .pe_select(pe_select),
  .int_in(int_in),
  .load_add_in(load_add_in),
  .read_add_in(read_add_in),
  .relay(relay),
  .reset(reset),
  .dec_out_fin(dec_out_fin),
  .ext_reset(ext_reset)
  );


  initial begin
    // Taking arguments from the command line
    if ($value$plusargs("FRAMES=%0d", code_frames) | 1'b1) begin 
      //$display("Number of frames = %0d", code_frames);
    end

    if ($value$plusargs("INP_FILE=%s", inp_file_name) | 1'b1) begin 
      //$display("Input file = %s", inp_file_name);
    end

    if ($value$plusargs("OUT_FILE=%s", out_file_name) | 1'b1) begin 
      //$display("Output file = %s", out_file_name);
    end

    if ($value$plusargs("ORDERED_OUT_FILE=%s", ordered_out_file_name) | 1'b1) begin
      //$display("Ordered output file = %s", ordered_out_file_name);
    end


    // Reading data from input file
    inp_fd = $fopen(inp_file_name, "r");
    out_fd = $fopen(out_file_name, "w");
    ordered_out_fd = $fopen(ordered_out_file_name, "w");

    noisy_codeword_ordered='0;
    input_codeword_valid=1'b0;
    decoded_codeword_ordered_valid=1'b0;
    corrected_bit_position=11'd0;
    corrected_bit_count=11'd0;
    
    en=1'b0;
    reset=1'b1;
    repeat(1) @(posedge clk);
    #0.5;


    // Only code_frames are real input payloads.  Two all-zero frames are
    // generated internally to flush the decoder pipeline.
    for(int frame=1; frame<=code_frames+2; frame=frame+1) begin
      frame_dbg=frame;
      if(frame<=code_frames) begin
        payload_frame_dbg=frame;
      end
      if(frame<=code_frames) begin
        $display("Payload frame number: %0d",frame);
      end else begin
        $display("Internal pipeline flush: %0d",frame-code_frames);
      end
      for(int i=0; i<DATA_COUNT; i=i+1) begin
        if(frame<=code_frames) begin
          scan_faults = $fscanf(inp_fd, "%b", int_data[i]);
        end else begin
          int_data[i]='0;
        end
        // MSB of the signed 5-bit LLR is the received hard-decision bit.
        // The first frame is the single payload selected for this debug run.
        if(frame==1) begin
          noisy_codeword_ordered[i]=int_data[i][MESSAGE_WIDTH-1];
        end
        //$display("data: %b", int_data[i]);
      end
      if(frame==1) begin
        input_codeword_valid=1'b1;
      end
      reset=1'b0;
      ext_reset=1'b1;
      repeat(1) @(posedge clk_df);
      #0.5;
      ext_reset=1'b0;
      
      en=1'b1;
      prev_f_id=f_id;
      flag=1;
      t=0;
      while(flag) begin
        //$display("Count = %d",count);
        //$display("relay = %b",relay);
        //$display("prev_f_id = %b\n",prev_f_id);
        
        repeat(1) @(negedge clk); 
        // These controls are one-hot for the current transfer.  Leaving old
        // bits asserted overwrites every previously selected PE/column.
        pe_select='0;
        column_select='0;
        if((count/L)<(K*K)) begin
          pe_select[count/L]=1'b1;
          int_in=int_data[count];
          load_add_in=count%L;        
        end
        if((count/K)<L) begin
          read_add_in=count/K;
          column_select[count%K]=1'b1;          
        end
      


        repeat(1) @(posedge clk);
        repeat(1) @(posedge clk_df);
        #0.5;

        if(count%K==(K-1) && (count/K)<L) begin
          //for(int x=0; x<K; x=x+1) begin
            for(int y=0; y<K; y=y+1) begin
              hard_dec[t]=dec_out_fin[0][y];
              t=t+1;
              //$display("%b",dec_out_fin[0][y]);
            end

            for(int y=0; y<K; y=y+1) begin
              hard_dec[t]=dec_out_fin[1][y];
              t=t+1;
              //$display("%b",dec_out_fin[1][y]);
            end

            for(int y=0; y<K; y=y+1) begin
              hard_dec[t]=dec_out_fin[2][y];
              t=t+1;  
              //$display("%b",dec_out_fin[2][y]);
            end

            for(int y=0; y<K; y=y+1) begin
              hard_dec[t]=dec_out_fin[3][y];
              t=t+1;
              //$display("%b",dec_out_fin[3][y]);
            end

            for(int y=0; y<K; y=y+1) begin
              hard_dec[t]=dec_out_fin[4][y];
              t=t+1;
              //$display("%b",dec_out_fin[4][y]);
            end

            for(int y=0; y<K; y=y+1) begin
              hard_dec[t]=dec_out_fin[5][y];
              t=t+1;
              //$display("%b",dec_out_fin[5][y]);
            end

          //end
        end

        if(f_id!=prev_f_id) begin
          flag=0;
        end

        count=count+1;

        //(L*K*y)+(L*x)+((count)/K)

      end

      
      column_select=6'b0;
      pe_select=36'b0;
      count=0;

      if(frame!=1 && frame!=2) begin
        // Let the continuous permutation settle after the last hard_dec update.
        #0;
        corrected_bit_position=11'd0;
        corrected_bit_count=11'd0;
        for(int j=0; j<DATA_COUNT; j=j+1) begin
          if(noisy_codeword_ordered[j] !== decoded_codeword_ordered[j]) begin
            corrected_bit_count=corrected_bit_count+1'b1;
            if(corrected_bit_position==11'd0) begin
              // Human-readable one-based bit position.
              corrected_bit_position=j+1;
            end
          end
        end
        decoded_codeword_ordered_valid=1'b1;
        #0;
        $display("Ordered decoder output valid: corrected_count=%0d, corrected_position=%0d",
                 corrected_bit_count, corrected_bit_position);
        $display("Input bits 1..16      = %b", input_bits_1_to_16);
        $display("Output bits 1..16     = %b", output_bits_1_to_16);
        $display("Difference bits 1..16 = %b", difference_bits_1_to_16);

        for(int j=0; j<(L*K*K); j=j+1) begin
          $fwrite(out_fd, "%b", hard_dec[j]);
          $fwrite(ordered_out_fd, "%b", decoded_codeword_ordered[j]);
        end
        $fwrite(out_fd, "\n");
        $fwrite(ordered_out_fd, "\n");
      end
      
  
      
    end

    $fclose(inp_fd);
    $fclose(out_fd);
    $fclose(ordered_out_fd);

    // Keep the final debug result visible on the waveform.  Without this
    // interval, valid/position are updated in the same simulation instant as
    // $finish and can look like they stayed at zero in XSim.
    #1000;
    $finish;


    // Writing decoded data to file, assumes that the data for current frame is in 

  end

  initial begin
    clk<=0;
    clk_df<=0;
  end
  
  always begin
    #1 clk <= ~clk; 
  end

  always begin
    #0.5 clk_df <= ~clk_df;
  end


endmodule
