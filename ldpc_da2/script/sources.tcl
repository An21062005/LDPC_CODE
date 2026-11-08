# Compilation units come only from the resolved .f filelists.
proc da2_add_sources {sources includes {fileset sources_1}} {
  set_property include_dirs $includes [get_filesets $fileset]
  add_files -fileset $fileset -scan_for_includes -norecurse $sources
  foreach path $sources {
    set_property file_type SystemVerilog [get_files -all [list $path]]
  }
}
