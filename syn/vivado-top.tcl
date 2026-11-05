# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Out-of-context Vivado implementation with one of the Verilog/VHDL tops
# (rtl/top/) as the design top, to check that each wrapper elaborates and
# synthesizes in Vivado's mixed-language flow.
#
#   vivado -mode batch -source syn/vivado-top.tcl -tclargs <top> [period_ns] [GEN=VAL ...]
#
# <top>: any of the Verilog/VHDL tops in rtl/top/ (jsm_fp_unit_vhd, jsm_fp_unit_top,
# jsm_fp_unit_axilite_vhd/_top, jsm_fp_unit_axis_vhd/_top).
# GEN=VAL arguments become -generic overrides (W_EXP=8 W_MANT=23 ...).
# The design ports are not registered (unlike syn/vivado-impl.tcl), so the
# timing report covers register-to-register paths only.
# Reports go to syn/out/<top>_<tag>/ (gitignored).

set root   [file normalize [file join [file dirname [info script]] ..]]
set top    [lindex $argv 0]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 5.600}]
set gens   [lrange $argv 2 end]
set part   xcvu9p-flga2104-2L-e
set tag    "${top}_${period}ns[join $gens _]"
set outdir [file join $root syn out $tag]
file mkdir $outdir

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

set sv {}
set v  {}
foreach f [concat [read_list $root filelist.f] [read_list $root filelist_wrappers.f]] {
  if {[file extension $f] eq ".v"} { lappend v $f } else { lappend sv $f }
}
read_verilog -sv $sv
read_verilog $v
read_vhdl [read_list $root filelist_vhdl.f]

set g {}
foreach kv $gens { lappend g -generic $kv }
synth_design -top $top -part $part -mode out_of_context {*}$g
set clk ""
foreach c {clk aclk s_axi_aclk} { if {$clk eq "" && [llength [get_ports -quiet $c]]} { set clk $c } }
create_clock -period $period -name clk [get_ports $clk]
opt_design
place_design
phys_opt_design
route_design
phys_opt_design
report_timing_summary -file [file join $outdir timing_summary.rpt]
report_utilization -file [file join $outdir utilization.rpt]
set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CLB && PRIMITIVE_SUBGROUP == LUT}]]
puts "VIVADO TOP DONE: $tag WNS [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns LUT cells $luts"
