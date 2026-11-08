# PYNQ-Z2 project/build for one architecture (block design as in ldpc_da2:
# PS7 M_AXI_GP0 -> SmartConnect -> LDPC_Decoder_PYNQ_Z2_top at 0x43C00000,
# FCLK0 = 100 MHz). Invoked by: python script/run.py project|build --arch A
#   argv: project|build  <run directory>  <build_config.tcl>
# Never programs the FPGA. Timing failure does not stop the reports.

set mode [lindex $argv 0]
set project_dir [file normalize [lindex $argv 1]]
source [file normalize [lindex $argv 2]]
set package_dir [file normalize [file join [file dirname [info script]] ..]]
if {![string match "${package_dir}/outfeed/*" $project_dir]} {error "project must be inside outfeed/"}

set_param board.repoPaths [list $cfg_board_repo]
set boards [get_board_parts -quiet *pynq-z2*]
if {[llength $boards] == 0} {error "PYNQ-Z2 board files not found in $cfg_board_repo"}

create_project p $project_dir -part $cfg_part
set_param general.maxThreads $cfg_threads
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
set_property board_part [lindex $boards 0] [current_project]
set_property target_language Verilog [current_project]
set_property include_dirs $cfg_includes [get_filesets sources_1]
add_files -norecurse -scan_for_includes $cfg_files
foreach f $cfg_files {set_property file_type SystemVerilog [get_files -all [list $f]]}
# Headers (.vh) must be project files for the block-design module reference.
foreach d $cfg_includes {
  foreach h [glob -nocomplain -types f [file join $d *.vh]] {
    if {[llength [get_files -quiet -all [list $h]]] == 0} {add_files -norecurse [list $h]}
    set_property file_type {Verilog Header} [get_files -all [list $h]]
  }
}
update_compile_order -fileset sources_1

create_bd_design ldpc_system
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps7
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000}] $ps7
create_bd_cell -type module -reference LDPC_Decoder_PYNQ_Z2_top decoder_axi
set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $smc
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M
set locked [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 clocks_locked]
set_property CONFIG.CONST_VAL {1} $locked
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins decoder_axi/S_AXI]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins axi_smc/aclk] [get_bd_pins decoder_axi/s_axi_aclk] [get_bd_pins rst_ps7_0_100M/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_100M/ext_reset_in]
connect_bd_net [get_bd_pins clocks_locked/dout] [get_bd_pins rst_ps7_0_100M/dcm_locked]
connect_bd_net [get_bd_pins rst_ps7_0_100M/interconnect_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] [get_bd_pins decoder_axi/s_axi_aresetn]
assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs decoder_axi/S_AXI/reg0] -force
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces processing_system7_0/Data] -filter {NAME =~ "*decoder_axi*"}]
if {[llength $seg] > 0} {set_property offset 0x43C00000 [lindex $seg 0]; set_property range 64K [lindex $seg 0]}
validate_bd_design
save_bd_design
set bd_file [get_files ldpc_system.bd]
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]
set_property top ldpc_system_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1
set_property board_part {} [current_project]
puts "PROJECT_CREATED=[file join $project_dir p.xpr]"
if {$mode ne "build"} {return}

set rpt [file join $project_dir reports]
file mkdir $rpt
proc run_failed {run} {
  return [expr {[get_property PROGRESS [get_runs $run]] ne "100%" ||
                [string match -nocase "*ERROR*" [get_property STATUS [get_runs $run]]]}]
}

launch_runs synth_1 -jobs $cfg_jobs
wait_on_run synth_1
if {[run_failed synth_1]} {
  puts "BUILD_STAGE_FAILED=synth STATUS=[get_property STATUS [get_runs synth_1]]"
  return
}
open_run synth_1
report_utilization -file [file join $rpt utilization_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $rpt utilization_synth_hier.rpt]
close_design

if {[catch {launch_runs impl_1 -to_step write_bitstream -jobs $cfg_jobs; wait_on_run impl_1} msg]} {
  puts "IMPL_LAUNCH_MESSAGE=$msg"
}
if {[run_failed impl_1]} {
  puts "BUILD_STAGE_FAILED=impl STATUS=[get_property STATUS [get_runs impl_1]]"
  set impl_dir [get_property DIRECTORY [get_runs impl_1]]
  foreach f [glob -nocomplain -types f [file join $impl_dir *.log] [file join $impl_dir runme.log]] {
    set fd [open $f r]; set text [read $fd]; close $fd
    foreach line [split $text \n] {if {[string match "ERROR:*" $line]} {puts "IMPL_$line"}}
  }
  return
}
open_run impl_1
report_utilization -file [file join $rpt utilization_impl.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $rpt utilization_impl_hier.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $rpt timing_impl.rpt]
report_clock_interaction -file [file join $rpt clock_interaction_impl.rpt]
report_route_status -file [file join $rpt route_status_impl.rpt]
report_drc -file [file join $rpt drc_impl.rpt]
report_methodology -file [file join $rpt methodology_impl.rpt]
report_power -file [file join $rpt power_impl.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "TIMING_RESULT WNS=$wns WHS=$whs"
# Per clock: worst setup slack of paths captured by the clock (path group,
# includes clock crossings) and of paths launched AND captured by it (intra).
foreach c [get_clocks] {
  set p [get_timing_paths -delay_type max -max_paths 1 -group $c -quiet]
  set s [expr {[llength $p] ? [get_property SLACK $p] : "none"}]
  set q [get_timing_paths -delay_type max -max_paths 1 -from $c -to $c -quiet]
  set si [expr {[llength $q] ? [get_property SLACK $q] : "none"}]
  puts "CLOCK_SLACK $c period=[get_property PERIOD $c] wns=$s intra_wns=$si"
}
set fd [open [file join $rpt power_impl.rpt] r]; set ptext [read $fd]; close $fd
regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $ptext unused ptot
regexp {Dynamic \(W\)\s*\|\s*([\d.]+)} $ptext unused pdyn
regexp {Device Static \(W\)\s*\|\s*([\d.]+)} $ptext unused psta
if {[info exists ptot] && [info exists pdyn] && [info exists psta]} {
  puts "POWER_ESTIMATE total_w=$ptot dynamic_w=$pdyn static_w=$psta"
}
set bits [glob -nocomplain -types f [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]]
set hwhs [glob -nocomplain -types f [file join $project_dir p.gen sources_1 bd ldpc_system hw_handoff *.hwh]]
if {[llength $bits]} {puts "BITSTREAM=[lindex $bits 0]"}
if {[llength $hwhs]} {puts "HWH=[lindex $hwhs 0]"}
