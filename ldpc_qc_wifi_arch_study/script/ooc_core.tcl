# arch_study: out-of-context synthesis / implementation of ldpc_core alone (no
# wrapper, MMCM or AXI) with one clock constraint, for core resources and Fmax.
# Invoked by: python script/run.py fmax --arch A [--code C] [--part P] [--steps synth]
#   argv: synth|impl <run directory> <ooc_config.tcl>
# Only register-to-register paths of 'clk' are timed (ports are unconstrained).
# Never programs the FPGA.

set mode [lindex $argv 0]
set run_dir [file normalize [lindex $argv 1]]
source [file normalize [lindex $argv 2]]
set package_dir [file normalize [file join [file dirname [info script]] ..]]
if {![string match "${package_dir}/outfeed/*" $run_dir]} {error "run directory must be inside outfeed/"}
set_param general.maxThreads $cfg_threads

foreach f $cfg_files {read_verilog -sv [list $f]}
set xdc [file join $run_dir clock.xdc]
set fd [open $xdc w]
puts $fd "create_clock -name clk -period $cfg_period \[get_ports clk\]"
close $fd
read_xdc [list $xdc]

proc worst {type} {
  set p [get_timing_paths -delay_type $type -max_paths 1 -nworst 1 -quiet]
  if {[llength $p] == 0} {return none}
  return [get_property SLACK $p]
}

if {[catch {synth_design -top ldpc_core -part $cfg_part -mode out_of_context} msg]} {
  puts "OOC_FAILED stage=synth message=$msg"
  return
}
report_utilization -file [file join $run_dir utilization_synth.rpt]
report_timing_summary -file [file join $run_dir timing_synth.rpt]
puts "OOC_STAGE stage=synth wns=[worst max]"
if {$mode eq "synth"} {puts "OOC_DONE"; return}

foreach step {opt_design place_design phys_opt_design route_design} {
  if {[catch {$step} msg]} {
    puts "OOC_FAILED stage=$step message=$msg"
    return
  }
}
report_utilization -file [file join $run_dir utilization_impl.rpt]
report_timing_summary -file [file join $run_dir timing_impl.rpt]
report_route_status -file [file join $run_dir route_status_impl.rpt]
report_power -file [file join $run_dir power_impl.rpt]
puts "OOC_STAGE stage=impl wns=[worst max] whs=[worst min]"
set fd [open [file join $run_dir power_impl.rpt] r]; set ptext [read $fd]; close $fd
if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $ptext unused ptot] &&
    [regexp {Dynamic \(W\)\s*\|\s*([\d.]+)} $ptext unused pdyn] &&
    [regexp {Device Static \(W\)\s*\|\s*([\d.]+)} $ptext unused psta]} {
  puts "POWER_ESTIMATE total_w=$ptot dynamic_w=$pdyn static_w=$psta"
}
puts "OOC_DONE"
