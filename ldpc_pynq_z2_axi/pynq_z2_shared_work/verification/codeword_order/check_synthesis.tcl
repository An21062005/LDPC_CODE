# Local synthesis check only; no board connection or programming.
set run_dir [file dirname [file normalize [info script]]]
set work_dir [file normalize [file join $run_dir .. ..]]
set rtl_dir [file join $work_dir fixed_rtl_source]
set_param general.maxThreads 1
create_project -in_memory -part xc7z020clg400-1
set_property include_dirs [list $rtl_dir] [current_fileset]
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
read_verilog -sv [list [file join $rtl_dir Decoder.v]]
read_verilog -sv [list [file join $rtl_dir LDPC_Decoder_PYNQ_Z2_top.sv]]
synth_design -top LDPC_Decoder_PYNQ_Z2_top -part xc7z020clg400-1 -mode out_of_context
create_clock -period 10.000 -name axi_clk [get_ports s_axi_aclk]
report_utilization -file [file join $run_dir synthesis_utilization.rpt]
report_timing_summary -file [file join $run_dir synthesis_timing.rpt]
puts "COD1_SYNTHESIS_PASS=1"
exit
