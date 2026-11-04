# Out-of-context Vivado implementation run of fp_unit (non-project mode).
#
#   vivado -mode batch -source syn/vivado-impl.tcl -tclargs [period_ns] [W_EXP W_MANT] [DIVSQRT_IMPL]
#
# Defaults: 5.600 ns, binary32 (8 23), DIVSQRT_IMPL 1 (SRT pipelines).
# The 250 MHz configuration is: -tclargs 4.000 8 23 2
# Reports and the routed checkpoint go to syn/out/<tag>/ (gitignored);
# rerunning overwrites them.
# The RTL list comes from rtl/filelist.f plus the I/O-registering wrapper
# syn/fp_unit_timing.sv.

set root   [file normalize [file join [file dirname [info script]] ..]]
set period [expr {[llength $argv] > 0 ? [lindex $argv 0] : 5.600}]
set wexp   [expr {[llength $argv] > 2 ? [lindex $argv 1] : 8}]
set wmant  [expr {[llength $argv] > 2 ? [lindex $argv 2] : 23}]
set impl   [expr {[llength $argv] > 3 ? [lindex $argv 3] : 1}]
set part   xcvu9p-flga2104-2L-e
set tag    "w${wexp}x${wmant}_ds${impl}_${period}ns"
set outdir [file join $root syn out $tag]
file mkdir $outdir

set rtl {}
set fh [open [file join $root rtl filelist.f] r]
foreach line [split [read $fh] "\n"] {
  set line [string trim [lindex [split $line "#"] 0]]
  if {$line ne ""} { lappend rtl [file join $root $line] }
}
close $fh
lappend rtl [file join $root syn fp_unit_timing.sv]

read_verilog -sv $rtl
synth_design -top fp_unit_timing -part $part -mode out_of_context \
  -generic W_EXP=$wexp -generic W_MANT=$wmant -generic DIVSQRT_IMPL=$impl
create_clock -period $period -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
phys_opt_design
write_checkpoint -force [file join $outdir routed.dcp]
report_timing_summary -file [file join $outdir timing_summary.rpt]
report_timing -max_paths 10 -file [file join $outdir timing_paths.rpt]
report_utilization -file [file join $outdir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir utilization_hier.rpt]
puts "VIVADO DONE: $tag WNS [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns"
