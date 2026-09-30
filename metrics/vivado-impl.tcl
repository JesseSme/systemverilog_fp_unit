# Single Vivado implementation run for the FPU Fmax work (non-project mode).
# Re-run this script to re-measure after RTL changes; all outputs overwrite in
# the same directory (no new projects are created).
set part xcvu9p-flga2104-2L-e
set outdir /tmp/opencode/vivado
file mkdir $outdir

set rtl [list \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_pkg.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_add.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_add_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_mul.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_mul_core.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_mul_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_div.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_sqrt.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_divsqrt_iter.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_fma.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_fma_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_minmax.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_minmax_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_cmp.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_cmp_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_totalorder.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_totalorder_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_roundint.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_roundint_pipe.sv \
  /home/jesse/Documents/systemverilog_fp_unit/rtl/fp_unit.sv \
  /tmp/opencode/timing/fp_unit_timing.sv]

read_verilog -sv $rtl
synth_design -top fp_unit_timing -part $part -mode out_of_context
create_clock -period 4.000 -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
phys_opt_design
report_timing_summary -file $outdir/timing_summary.rpt
report_timing -max_paths 10 -file $outdir/timing_paths.rpt
report_utilization -file $outdir/utilization.rpt
puts "VIVADO DONE"
