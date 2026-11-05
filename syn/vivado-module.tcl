# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Out-of-context Vivado implementation of ONE datapath module (register-to-
# register timing only: the module's input ports have no input delay, so the
# unregistered setup logic of a pipeline is not timed; its pipeline stages and
# output stage are).
#
#   vivado -mode batch -source syn/vivado-module.tcl -tclargs <module> [period_ns] [W_EXP W_MANT] [K=V ...]
#
# Extra K=V arguments become -generic overrides (e.g. DPS=1).
# Reports and the routed checkpoint go to syn/out/<module>_<tag>/ (gitignored).

set root   [file normalize [file join [file dirname [info script]] ..]]
set top    [lindex $argv 0]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4.000}]
set wexp   [expr {[llength $argv] > 3 ? [lindex $argv 2] : 8}]
set wmant  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 23}]
set extra  [lrange $argv 4 end]
set part   xcvu9p-flga2104-2L-e
set tag    "${top}_w${wexp}x${wmant}_${period}ns[join $extra _]"
set outdir [file join $root syn out $tag]
file mkdir $outdir

set rtl {}
set fh [open [file join $root rtl filelist.f] r]
foreach line [split [read $fh] "\n"] {
  set line [string trim [lindex [split $line "#"] 0]]
  if {$line ne ""} { lappend rtl [file join $root $line] }
}
close $fh

set gen [list -generic W_EXP=$wexp -generic W_MANT=$wmant]
foreach kv $extra { lappend gen -generic $kv }
read_verilog -sv $rtl
synth_design -top $top -part $part -mode out_of_context {*}$gen
create_clock -period $period -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $outdir routed.dcp]
report_timing_summary -file [file join $outdir timing_summary.rpt]
report_timing -max_paths 20 -nworst 1 -unique_pins -file [file join $outdir timing_paths.rpt]
report_utilization -file [file join $outdir utilization.rpt]
puts "VIVADO DONE: $tag WNS [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns"
