# Behavioral regression for the AXI wrapper. Run from the fix directory with:
# vivado -mode batch -source run_pynq_axi_wrapper_test.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file join $script_dir tests wrapper_sim_project]
cd $script_dir

create_project -force wrapper_sim $project_dir -part xc7z020clg400-1
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -scan_for_includes -norecurse [list \
  [file join $script_dir Decoder.v] \
  [file join $script_dir LDPC_Decoder_PYNQ_Z2_top.sv]]
set_property file_type SystemVerilog [get_files Decoder.v]
set_property file_type SystemVerilog [get_files LDPC_Decoder_PYNQ_Z2_top.sv]

add_files -fileset sim_1 -norecurse [list \
  [file join $script_dir tests tb_pynq_axi_wrapper.sv]]
set_property file_type SystemVerilog [get_files tb_pynq_axi_wrapper.sv]
set_property top tb_pynq_axi_wrapper [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

launch_simulation
run all
close_sim

set sim_log [file join $project_dir wrapper_sim.sim sim_1 behav xsim simulate.log]
set log_fd [open $sim_log r]
set log_text [read $log_fd]
close $log_fd
if {[string first "PASS: AXI wrapper loaded 3 frames" $log_text] < 0} {
  error "AXI wrapper regression did not pass; inspect $sim_log"
}

close_project
