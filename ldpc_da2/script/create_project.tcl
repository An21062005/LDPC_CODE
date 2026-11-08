# Create a PYNQ-Z2 Vivado project with the LDPC core behind AXI4-Lite.
# Invoke through: python script/run.py project|build

set package_dir [file normalize [file join [file dirname [info script]] ..]]
set script_dir [file join $package_dir code rtl]
set board_repo [file join $package_dir code board_files_repo]
# The launcher supplies a fresh project directory under ldpc_da2/outfeed.
set project_dir [file normalize [lindex $argv 1]]
source [file normalize [lindex $argv 2]]
if {![string match "${package_dir}/*" $project_dir]} {
  error "Project directory must be inside ldpc_da2"
}
set build_requested [expr {[llength $argv] > 0 && [lindex $argv 0] eq "build"}]

if {![file isdirectory $board_repo]} {
  error "Missing $board_repo. The bundled PYNQ-Z2 board definition is required."
}

set_param board.repoPaths [list $board_repo]
set board_candidates [get_board_parts -quiet *pynq-z2*]
if {[llength $board_candidates] == 0} {
  error "Vivado did not find PYNQ-Z2 in $board_repo. Restart Vivado and run this script again."
}
set pynq_board [lindex $board_candidates 0]

create_project p $project_dir -part $cfg_part
set_param general.maxThreads $cfg_threads
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
set_property board_part $pynq_board [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

source [file join $package_dir script sources.tcl]
da2_add_sources $cfg_rtl_files $cfg_rtl_includes
update_compile_order -fileset sources_1

create_bd_design ldpc_system

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
  $ps7
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000}] $ps7

set decoder_axi [create_bd_cell -type module -reference LDPC_Decoder_PYNQ_Z2_top decoder_axi]
set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $axi_ic
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M]
set locked_const [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 clocks_locked]
set_property CONFIG.CONST_VAL {1} $locked_const

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                    [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] \
                    [get_bd_intf_pins decoder_axi/S_AXI]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins axi_smc/aclk] \
  [get_bd_pins decoder_axi/s_axi_aclk] \
  [get_bd_pins rst_ps7_0_100M/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
  [get_bd_pins rst_ps7_0_100M/ext_reset_in]
connect_bd_net [get_bd_pins clocks_locked/dout] \
  [get_bd_pins rst_ps7_0_100M/dcm_locked]
connect_bd_net [get_bd_pins rst_ps7_0_100M/interconnect_aresetn] \
  [get_bd_pins axi_smc/aresetn]
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
  [get_bd_pins decoder_axi/s_axi_aresetn]

assign_bd_address -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs decoder_axi/S_AXI/reg0] -force
set decoder_segment [get_bd_addr_segs -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
  -filter {NAME =~ "*decoder_axi*"}]
if {[llength $decoder_segment] > 0} {
  set_property offset 0x43C00000 [lindex $decoder_segment 0]
  set_property range 64K [lindex $decoder_segment 0]
}

validate_bd_design
save_bd_design

set bd_file [get_files ldpc_system.bd]
# Synthesize the BD with the top run.  This avoids a large decoder OOC child
# run and makes the project independent of board.repoPaths in child Vivado
# processes after the PYNQ-Z2 PS/DDR preset has already been applied.
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file
set wrapper_file [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_file
set_property top ldpc_system_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

# The part and complete PS7 configuration are now stored in the block design.
# Clear board_part so synthesis/implementation child processes do not require
# the external board repository to be installed globally.
set_property board_part {} [current_project]

if {$build_requested} {
  set artifact_dir [file join $project_dir reports]
  file mkdir $artifact_dir

  # The decoder OOC run needs about 2.4 GB.  One job avoids Windows killing
  # parallel Vivado child processes on machines with limited free pagefile.
  launch_runs synth_1 -jobs $cfg_jobs
  wait_on_run synth_1
  if {[get_property PROGRESS [get_runs synth_1]] ne "100%" ||
      [string match -nocase "*ERROR*" [get_property STATUS [get_runs synth_1]]]} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
  }

  launch_runs impl_1 -to_step write_bitstream -jobs $cfg_jobs
  wait_on_run impl_1
  if {[get_property PROGRESS [get_runs impl_1]] ne "100%" ||
      [string match -nocase "*ERROR*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation/bitstream failed: [get_property STATUS [get_runs impl_1]]"
  }

  open_run impl_1
  report_utilization -file [file join $artifact_dir utilization_impl.rpt]
  report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $artifact_dir timing_impl.rpt]
  report_route_status -file [file join $artifact_dir route_status_impl.rpt]
  report_power -file [file join $artifact_dir power_impl.rpt]
  report_drc -file [file join $artifact_dir drc_impl.rpt]
  report_methodology -file [file join $artifact_dir methodology_impl.rpt]

  set setup_wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
  set hold_whs  [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
  puts "TIMING_RESULT WNS=$setup_wns WHS=$hold_whs"
  if {$setup_wns < 0.0 || $hold_whs < 0.0} {
    error "Timing failed: WNS=$setup_wns ns, WHS=$hold_whs ns; artifacts were not packaged"
  }
  puts "Timing passed: WNS=$setup_wns ns, WHS=$hold_whs ns"

  set impl_dir [get_property DIRECTORY [get_runs impl_1]]
  set bit_candidates [glob -nocomplain -types f [file join $impl_dir *.bit]]
  set hwh_candidates [glob -nocomplain -types f \
    [file join $project_dir p.gen sources_1 bd ldpc_system hw_handoff *.hwh]]
  if {[llength $bit_candidates] == 0 || [llength $hwh_candidates] == 0} {
    error "Build passed but .bit or .hwh artifact was not found"
  }
  foreach test {regression order} {
    set result_file [file join $package_dir outfeed reports latest_test_${test}.json]
    if {![file exists $result_file]} {error "Missing $test simulation result; board package withheld"}
    set fd [open $result_file r]
    set result_text [read $fd]
    close $fd
    if {![regexp {"result"\s*:\s*"PASS"} $result_text]} {
      error "Timing passed but $test simulation failed; board package withheld"
    }
    if {![regexp [format {"rtl_sha256"\s*:\s*"%s"} $cfg_rtl_sha256] $result_text]} {
      error "RTL changed since $test simulation; board package withheld"
    }
    if {$test eq "regression" &&
        (![regexp {"compared_frames"\s*:\s*([0-9]+)} $result_text unused verified_frames] || $verified_frames < 3)} {
      error "Regression must compare at least 3 codewords; smoke overrides cannot certify a board package"
    }
  }
  set ready_dir [file join $package_dir outfeed artifacts [file tail $project_dir]]
  file mkdir $ready_dir
  file copy [lindex $bit_candidates 0] [file join $ready_dir ldpc_da2.bit]
  file copy [lindex $hwh_candidates 0] [file join $ready_dir ldpc_da2.hwh]
  file copy [file join $package_dir script run_board.py] $ready_dir
  puts "BOARD_PACKAGE_READY=$ready_dir"
}

puts ""
puts "PYNQ-Z2 AXI project created:"
puts "  [file join $project_dir p.xpr]"
if {$build_requested} {
  puts "Bitstream package: $ready_dir"
} else {
  puts "Next in Flow Navigator: Run Synthesis -> Run Implementation -> Generate Bitstream."
}
