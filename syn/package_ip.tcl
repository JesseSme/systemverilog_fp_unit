# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Package the floating-point unit as Vivado IP (IP catalog / IP integrator).
#
#   vivado -mode batch -source syn/package_ip.tcl [-tclargs <ip_repo_dir>]
#   (make ip)
#
# Creates three self-contained IP cores (sources copied in) under
# <ip_repo_dir> (default: ip_repo/ in the repository, gitignored):
#   jsm:fpu:jsm_fp_unit_axilite:1.0   AXI4-Lite register interface
#   jsm:fpu:jsm_fp_unit_axis:1.0      AXI4-Stream, full backpressure, in order
#   jsm:fpu:jsm_fp_unit:1.0           native valid/ready + tag interface
# Add the directory to the IP repositories (Settings > IP > Repository, or
# set_property ip_repo_paths <dir> [current_project]; update_ip_catalog).

set root [file normalize [file join [file dirname [info script]] ..]]
set repo [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : [file join $root ip_repo]}]
set work [file join $root syn out package_ip]
set version 1.0

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
set core_files [read_list $root filelist.f]

# user parameter: display name, description, validation
proc param {core name disp desc args} {
  set p [ipx::get_user_parameters $name -of_objects $core]
  set_property display_name $disp $p
  set_property description $desc $p
  if {[llength $args] == 2} {
    set_property value_format long $p
    set_property value_validation_type range_long $p
    set_property value_validation_range_minimum [lindex $args 0] $p
    set_property value_validation_range_maximum [lindex $args 1] $p
  } elseif {[llength $args] == 1} {
    set_property value_validation_type pairs $p
    set_property value_validation_pairs [lindex $args 0] $p
  }
}

set ips {
  jsm_fp_unit_axilite jsm_fp_unit_axilite_top {rtl/jsm_fp_unit_axilite.sv rtl/top/jsm_fp_unit_axilite_top.v}
    "FPU (AXI4-Lite)" "IEEE 754-2019 floating-point unit, AXI4-Lite register interface"
  jsm_fp_unit_axis jsm_fp_unit_axis_top {rtl/jsm_fp_unit_axis.sv rtl/top/jsm_fp_unit_axis_top.v}
    "FPU (AXI4-Stream)" "IEEE 754-2019 floating-point unit, AXI4-Stream requests and results (in order, full backpressure)"
  jsm_fp_unit jsm_fp_unit_top {rtl/top/jsm_fp_unit_flat.sv rtl/top/jsm_fp_unit_top.v}
    "FPU (native)" "IEEE 754-2019 floating-point unit, native valid/ready interface with request tags"
}

file mkdir $repo
foreach {name top extra disp desc} $ips {
  set dir [file join $repo $name]
  file delete -force $dir [file join $work $name]
  create_project -force pkg_$name [file join $work $name] -part xcvu9p-flga2104-2L-e
  add_files -norecurse [concat $core_files [lmap f $extra {file join $root $f}]]
  foreach f [get_files *.sv] { set_property FILE_TYPE SystemVerilog $f }
  set_property top $top [current_fileset]
  update_compile_order -fileset sources_1

  ipx::package_project -root_dir $dir -vendor jsm -library fpu -taxonomy /UserIP \
    -import_files -set_current true
  set core [ipx::current_core]
  set_property name $name $core
  set_property display_name $disp $core
  set_property description $desc $core
  set_property version $version $core
  set_property core_revision 1 $core
  # all device families (what AMD's own IP declares)
  set_property auto_family_support_level level_2 $core

  param $core W_EXP "Exponent bits" "Exponent field width W_EXP (8 for binary32, 11 for binary64, 5 for binary16; verified up to 11)" 1 11
  param $core W_MANT "Fraction bits" "Fraction field width W_MANT (23 for binary32, 52 for binary64, 10 for binary16; 0 = power-of-two format)" 0 52
  param $core DIVSQRT_IMPL "Div/sqrt implementation" "1: SRT pipelines (5.6 ns on VU9P-2L), 3: SRT 4.0 ns form, 2: iterative (4.0 ns, one div/sqrt in flight), 0: combinational reference" \
    {"SRT pipelines (5.6 ns)" 1 "SRT pipelines, 4.0 ns form" 3 "Iterative engine (small)" 2 "Combinational reference" 0}
  switch $name {
    jsm_fp_unit_axilite {
      param $core ADDR_WIDTH "AXI address width" "AXI4-Lite address width (5 is enough for formats up to 32 bits, 6 up to 64)" 5 16
      # 4 KB address block for the register map
      set mm [ipx::get_memory_maps S_AXI -of_objects $core]
      if {$mm eq ""} {
        set mm [ipx::add_memory_map S_AXI $core]
        set_property slave_memory_map_ref S_AXI [ipx::get_bus_interfaces S_AXI -of_objects $core]
      }
      if {[ipx::get_address_blocks -of_objects $mm] eq ""} {
        set ab [ipx::add_address_block reg0 $mm]
        set_property range 4096 $ab
        set_property width 32 $ab
        set_property usage register $ab
      }
    }
    jsm_fp_unit_axis {
      param $core OPS_EN "Operation enable mask" "Bit i enables opcode i (0xFFFF: all); disabled operations are not built" 0 65535
      param $core TUSER_W "TUSER width" "S_AXIS / M_AXIS TUSER width, passed through with each result" 1 256
      param $core DEPTH "Reorder buffer depth" "Results buffered in flight; 0 = automatic (full throughput)" 0 1024
    }
    jsm_fp_unit {
      param $core OPS_EN "Operation enable mask" "Bit i enables opcode i (0xFFFF: all); disabled operations are not built" 0 65535
      param $core TAG_W "Tag width" "in_tag / out_tag width" 1 32
    }
  }

  ipx::create_xgui_files $core
  ipx::update_checksums $core
  ipx::check_integrity $core
  ipx::save_core $core
  close_project
  puts "PACKAGED IP: jsm:fpu:$name:$version -> $dir"
}
