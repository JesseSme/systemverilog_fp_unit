# Block-design (IP integrator) check of the Verilog/VHDL tops: each top is
# added to a block design as a module reference, its parameters are set
# through CONFIG.*, and the inferred interfaces are listed (the AXI tops must
# show one AXI4-Lite slave S_AXI with its clock and reset associated).
#
#   vivado -mode batch -source syn/vivado-bd-check.tcl
#
# Creates a throw-away project in syn/out/bd_check/ (gitignored).

set root [file normalize [file join [file dirname [info script]] ..]]
set dir  [file join $root syn out bd_check]
file delete -force $dir
create_project bd_check $dir -part xcvu9p-flga2104-2L-e

proc read_list {root name} {
  set out {}
  set fh [open [file join $root rtl $name] r]
  foreach line [split [read $fh] "\n"] {
    set line [string trim [lindex [split $line "#"] 0]]
    if {$line ne ""} { lappend out [file join $root $line] }
  }
  close $fh
  return $out
}
add_files [concat [read_list $root filelist.f] [read_list $root filelist_wrappers.f] \
                  [read_list $root filelist_vhdl.f]]
foreach f [get_files *.sv] { set_property FILE_TYPE SystemVerilog $f }
update_compile_order -fileset sources_1

create_bd_design fpu_bd
set errors 0
foreach {cell ref cfg} {
  u_axi_vhd jsm_fp_unit_axilite_vhd {CONFIG.W_EXP 5 CONFIG.W_MANT 10}
  u_axi_v   jsm_fp_unit_axilite_top {CONFIG.W_EXP 8 CONFIG.W_MANT 23 CONFIG.DIVSQRT_IMPL 3}
  u_fpu_vhd jsm_fp_unit_vhd         {CONFIG.W_EXP 11 CONFIG.W_MANT 52 CONFIG.TAG_W 4}
  u_fpu_v   jsm_fp_unit_top         {CONFIG.W_EXP 8 CONFIG.W_MANT 7 CONFIG.OPS_EN 39}
} {
  create_bd_cell -type module -reference $ref $cell
  set_property -dict $cfg [get_bd_cells $cell]
  set ip [get_bd_intf_pins -quiet -of_objects [get_bd_cells $cell]]
  set intf [expr {[llength $ip] ? [lsort [get_property NAME $ip]] : {}}]
  set clks {}
  foreach p [get_bd_pins -of_objects [get_bd_cells $cell] -filter {TYPE == clk}] {
    lappend clks "[get_property NAME $p] (busif: [get_property CONFIG.ASSOCIATED_BUSIF $p], reset: [get_property CONFIG.ASSOCIATED_RESET $p])"
  }
  set rsts {}
  foreach p [get_bd_pins -of_objects [get_bd_cells $cell] -filter {TYPE == rst}] {
    lappend rsts "[get_property NAME $p] ([get_property CONFIG.POLARITY $p])"
  }
  puts "BD CELL $cell ($ref): intf {$intf} clk {$clks} rst {$rsts} [join $cfg { }]"
  if {[string match *axilite* $ref]} {
    if {$intf ne "S_AXI"} { incr errors; puts "ERROR: $cell: no S_AXI interface" }
    set proto [get_property CONFIG.PROTOCOL [get_bd_intf_pins $cell/S_AXI]]
    puts "BD CELL $cell S_AXI protocol $proto"
    if {$proto ne "AXI4LITE"} { incr errors; puts "ERROR: $cell: S_AXI is $proto" }
  } else {
    set yp [get_bd_pins -of_objects [get_bd_cells $cell] -filter {NAME == y}]
    puts "BD CELL $cell pins [lsort [get_property NAME [get_bd_pins -of_objects [get_bd_cells $cell]]]]"
    puts "BD CELL $cell y \[[get_property LEFT $yp]:[get_property RIGHT $yp]\]"
  }
  if {[llength $clks] != 1 || [llength $rsts] != 1} { incr errors; puts "ERROR: $cell: clock/reset not inferred" }
}
puts [expr {$errors == 0 ? "BD CHECK PASS" : "BD CHECK FAIL ($errors errors)"}]
close_project
