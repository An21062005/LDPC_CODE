set kind [lindex $argv 0]
set target [file normalize [lindex $argv 1]]
set config [lindex $argv 2]
set mode [lindex $argv 3]
if {$kind eq "wave"} {
  load_features simulator
  open_wave_database -noautoloadwcfg $target
  if {$config ne ""} {open_wave_config [file normalize $config]}
  if {$mode ne "check"} {catch {wave zoom full}}
  puts "WAVE_OPEN_VERIFIED=$target"
} elseif {$kind eq "project"} {
  open_project $target
  puts "PROJECT_OPEN_VERIFIED=$target"
} else {error "Expected wave or project"}
# In GUI mode Vivado retains the window after this script returns.
