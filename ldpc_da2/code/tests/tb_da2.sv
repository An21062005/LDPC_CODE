`timescale 1ns/1ps
module tb_da2;
  reg clk=0, aresetn=0;
  always #5 clk=~clk;
  reg [5:0] awaddr=0, araddr=0;
  reg [31:0] wdata=0;
  reg [3:0] wstrb=0;
  reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
  wire awready,wready,bvalid,arready,rvalid;
  wire [1:0] bresp,rresp;
  wire [31:0] rdata;
  LDPC_Decoder_PYNQ_Z2_top dut(
    .s_axi_aclk(clk),.s_axi_aresetn(aresetn),
    .s_axi_awaddr(awaddr),.s_axi_awprot(3'd0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
    .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
    .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
    .s_axi_araddr(araddr),.s_axi_arprot(3'd0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
    .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
  task automatic wr(input [5:0] a,input [31:0] v);
    @(negedge clk);awaddr=a;wdata=v;wstrb=15;awvalid=1;wvalid=1;
    do @(posedge clk);while(!(awready && wready));
    @(negedge clk);awvalid=0;wvalid=0;bready=1;
    do @(posedge clk);while(!bvalid);
    if(bresp!==0)$fatal(1,"write response");
    @(negedge clk);bready=0;
  endtask
  task automatic rd(input [5:0] a,output [31:0] v);
    @(negedge clk);araddr=a;arvalid=1;
    do @(posedge clk);while(!arready);
    @(negedge clk);arvalid=0;rready=1;
    do @(posedge clk);while(!rvalid);
    v=rdata;if(rresp!==0)$fatal(1,"read response");
    @(negedge clk);rready=0;
  endtask
  string input_path,expected_path,actual_path;
  integer fi,fe,fo,result,frame,sample,chunk,bitnum,polls,frames=5;
  integer frame_errors=0,total_errors=0;
  // Simulation-only views: first character/bit of the codeword is on the left.
  integer first_error_bit=0,compared_bits=0,output_frame=0;
  reg compare_done=0;
  reg [0:1151] decoded_view='0;
  wire [0:1151] expected_view;
  wire [0:1151] difference_view=compare_done ? decoded_view^expected_view : '0;
  wire [0:15] decoded_first16=decoded_view[0:15];
  wire [0:15] expected_first16=expected_view[0:15];
  wire [0:15] difference_first16=difference_view[0:15];
  reg [4:0] llr;
  reg [31:0] status,lo,hi;
  reg [1151:0] expected_word;
  for(genvar view_bit=0;view_bit<1152;view_bit=view_bit+1)begin
    assign expected_view[view_bit]=expected_word[1151-view_bit];
  end
  initial begin
    #200000000;
    $fatal(1,"global simulation timeout");
  end
  initial begin
    if(!$value$plusargs("INPUT=%s",input_path))$fatal(1,"INPUT required");
    if(!$value$plusargs("EXPECTED=%s",expected_path))$fatal(1,"EXPECTED required");
    if(!$value$plusargs("ACTUAL=%s",actual_path))actual_path="output_codeword.txt";
    result=$value$plusargs("FRAMES=%d",frames);
    fi=$fopen(input_path,"r");fe=$fopen(expected_path,"r");fo=$fopen(actual_path,"w");
    if(!fi||!fe||!fo)$fatal(1,"open data files");
    repeat(20)@(negedge clk);aresetn=1;
    repeat(200)@(negedge clk);
    rd('h20,lo);if(lo!==32'h434f4431)$fatal(1,"COD1 required");
    for(frame=1;frame<=frames;frame=frame+1)begin
      wr('h08,0);
      for(sample=0;sample<1152;sample=sample+1)begin
        result=$fscanf(fi,"%b",llr);
        if(result!=1)$fatal(1,"input frame %0d sample %0d",frame,sample);
        wr('h0c,{27'd0,llr});
      end
      wr('h00,1);status=0;polls=0;
      while(!status[1])begin
        rd('h04,status);polls=polls+1;
        if(status[4]||polls>25000)$fatal(1,"frame timeout %0d status=%h",frame,status);
      end
      if(status[0]||status[31:16]!=frame||status[2]!=(frame>=3))
        $fatal(1,"invalid frame status %0d %h",frame,status);
      if(frame>=3)begin
        compare_done=0;
        frame_errors=0;
        first_error_bit=0;
        output_frame=frame-2;
        result=$fscanf(fe,"%b",expected_word);
        if(result!=1)$fatal(1,"expected frame missing");
        for(chunk=0;chunk<32;chunk=chunk+1)begin
          wr('h10,chunk);rd('h14,lo);rd('h18,hi);
          if(hi[31:4]!==0)$fatal(1,"nonzero output padding");
          for(bitnum=0;bitnum<36;bitnum=bitnum+1)begin
            if(bitnum<32)begin
              decoded_view[chunk*36+bitnum]=lo[bitnum];
              if(lo[bitnum]!==expected_word[1151-chunk*36-bitnum])begin
                if(first_error_bit==0)first_error_bit=chunk*36+bitnum+1;
                frame_errors=frame_errors+1;
              end
              $fwrite(fo,"%b",lo[bitnum]);
            end else begin
              decoded_view[chunk*36+bitnum]=hi[bitnum-32];
              if(hi[bitnum-32]!==expected_word[1151-chunk*36-bitnum])begin
                if(first_error_bit==0)first_error_bit=chunk*36+bitnum+1;
                frame_errors=frame_errors+1;
              end
              $fwrite(fo,"%b",hi[bitnum-32]);
            end
          end
        end
        $fwrite(fo,"\n");
        total_errors=total_errors+frame_errors;
        compared_bits=compared_bits+1152;
        compare_done=1;
        $display("FRAME_COMPARE output=%0d bit_errors=%0d",frame-2,frame_errors);
      end
      $display("TRANSACTION_DONE transaction=%0d",frame);
    end
    wr('h10,32);rd('h14,lo);rd('h18,hi);
    if(lo!==0||hi!==0)$fatal(1,"out-of-range output index");
    $fclose(fi);$fclose(fe);$fclose(fo);
    if(total_errors!=0)$fatal(1,"FAIL_DA2 compared_frames=%0d bit_errors=%0d",frames-2,total_errors);
    $display("PASS_DA2 transactions=%0d compared_frames=%0d compared_bits=%0d",frames,frames-2,(frames-2)*1152);
    $finish;
  end
endmodule
