source [file normalize [lindex $argv 0]]
set root $cfg_root
set project_dir $cfg_run
set mode $cfg_mode
set frames $cfg_frames
if {![string match "${root}/*" $project_dir]} {error "Simulation must stay inside ldpc_da2"}
create_project p $project_dir -part $cfg_part
set_param general.maxThreads $cfg_threads
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
source [file join $root script sources.tcl]
da2_add_sources $cfg_rtl_files $cfg_rtl_includes
set test_files {}
foreach path $cfg_files {if {$path ni $cfg_rtl_files} {lappend test_files $path}}
da2_add_sources $test_files $cfg_includes sim_1
if {$mode eq "full"} {
  # %s in $value$plusargs stops at spaces. Paths relative to the XSim work
  # directory avoid the space in the Windows account name.
  set args [list "INPUT=../../../../stimulus/input.txt" "EXPECTED=../../../../stimulus/expected_codeword.txt" "ACTUAL=../../../../output_codeword.txt" "FRAMES=$frames"]
} elseif {$mode eq "order"} {
  set args [list "RAW_FILE=../../../../stimulus/raw.txt" "EXPECTED_FILE=../../../../stimulus/expected_codeword.txt" "ORDERED_FILE=../../../../output_codeword.txt"]
} else {error "Mode must be full or order"}
set_property top $cfg_top [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
set opts {}
foreach arg $args {append opts " -testplusarg \"$arg\""}
set_property xsim.simulate.xsim.more_options $opts [get_filesets sim_1]
set fd [open [file join $project_dir wave_run.tcl] w]
puts $fd [list source [file join $project_dir run_config.tcl]]
puts $fd [list source [file join $root script waveforms.tcl]]
close $fd
# XSim splits an absolute -tclbatch path containing spaces on Windows.
# The simulator working directory is p.sim/sim_1/behav/xsim.
set_property xsim.simulate.custom_tcl ../../../../wave_run.tcl [get_filesets sim_1]
launch_simulation
close_sim -force
set logfile [file join $project_dir p.sim sim_1 behav xsim simulate.log]
set fd [open $logfile r]
set logtext [read $fd]
close $fd
if {$mode eq "full"} {set marker PASS_DA2} else {set marker "PASS: direct RTL AXI codeword output matched"}
if {[string first $marker $logtext] < 0} {error "Simulation did not pass: $logfile"}
puts "SIMULATION_VERIFIED mode=$mode log=$logfile"
close_project
