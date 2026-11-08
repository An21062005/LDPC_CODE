# Called by XSim custom Tcl BEFORE time advances. Log only selected signals,
# avoiding log_wave -r / and its very large databases for 36 PE/RAM blocks.
if {$cfg_waves ne "none"} {
  create_wave_config
  set count 0
  set missing {}
  foreach item $cfg_wave_groups {
    lassign $item name radix paths
    if {$radix eq "binary"} {set radix bin}
    if {$radix eq "signed"} {set radix dec}
    set group [add_wave_group $name]
    foreach path $paths {
      set objects [get_objects -quiet $path]
      # XSim's escaped generate-instance identifiers contain both a leading
      # backslash and a trailing space. Query only the requested signal name
      # under the core, then match its escaped scope. Never enumerate RAMs.
      if {[llength $objects] == 0 && [string first /decoder_core/ $path] >= 0} {
        regexp {^(.*?/decoder_core/).*/([^/]+)$} $path unused core signal
        foreach object [get_objects -r -quiet "${core}${signal}"] {
          if {[string match $path $object]} {lappend objects $object}
        }
      }
      if {[llength $objects] == 0} {
        lappend missing $path
        continue
      }
      add_wave -into $group -radix $radix $objects
      log_wave $objects
      incr count [llength $objects]
    }
  }
  save_wave_config [file join $cfg_run waves.wcfg]
  set_property needs_save false [current_wave_config]
  set fd [open [file join $cfg_run wave_signals.txt] w]
  puts $fd "LOGGED_OBJECTS=$count"
  foreach path $missing {puts $fd "MISSING=$path"}
  close $fd
  puts "WAVE_SIGNALS=$count MISSING=[llength $missing]"
}
# Preserve database/layout even when the test calls $fatal. The launcher
# checks real test PASS/FAIL markers; an XSim exit code alone is insufficient.
if {[catch {run all} message]} {puts "XSIM_RUN_MESSAGE=$message"}
if {$cfg_waves ne "none"} {
  save_wave_config [file join $cfg_run waves.wcfg]
  set_property needs_save false [current_wave_config]
}
