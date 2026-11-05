# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Check the packaged IP (syn/package_ip.tcl): instantiate each core from the
# IP catalog in a block design, set parameters, make its ports external,
# validate the design, generate it and synthesize it out of context.
#
#   vivado -mode batch -source syn/ip_check.tcl [-tclargs <ip_repo_dir> [<part>]]

set root [file normalize [file join [file dirname [info script]] ..]]
set repo [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : [file join $root ip_repo]}]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu9p-flga2104-2L-e"}]
set chkdir [file join $root syn out ip_check_$part]
file delete -force $chkdir
create_project ip_check $chkdir -part $part
set_property ip_repo_paths $repo [current_project]
update_ip_catalog

create_bd_design fpu_ip
set errors 0
foreach {cell vlnv cfg} {
  u_axil jsm:fpu:jsm_fp_unit_axilite:1.0 {CONFIG.W_EXP 8 CONFIG.W_MANT 23}
  u_axis jsm:fpu:jsm_fp_unit_axis:1.0    {CONFIG.W_EXP 5 CONFIG.W_MANT 10 CONFIG.TUSER_W 8}
  u_nat  jsm:fpu:jsm_fp_unit:1.0         {CONFIG.W_EXP 8 CONFIG.W_MANT 7 CONFIG.OPS_EN 39}
} {
  create_bd_cell -type ip -vlnv $vlnv $cell
  set_property -dict $cfg [get_bd_cells $cell]
  set ip [get_bd_intf_pins -quiet -of_objects [get_bd_cells $cell]]
  puts "IP CELL $cell: intf {[expr {[llength $ip] ? [lsort [get_property NAME $ip]] : {}}]}"
  foreach p [get_bd_intf_pins -quiet -of_objects [get_bd_cells $cell]] { make_bd_intf_pins_external $p }
  foreach p [get_bd_pins -of_objects [get_bd_cells $cell] -filter {INTF != TRUE}] { make_bd_pins_external $p }
}
# address segment for the AXI4-Lite slave
assign_bd_address
validate_bd_design
save_bd_design
set bd [get_files fpu_ip.bd]
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]
set_property top fpu_ip_wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "IP CHECK ($part) synth_1: $st"
if {![string match "*Complete*" $st]} { incr errors }
puts [expr {$errors == 0 ? "IP CHECK PASS" : "IP CHECK FAIL"}]
close_project
