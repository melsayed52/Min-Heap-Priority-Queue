# vivado_ooc_fp.tcl - OOC flow with a floorplan pblock compacting the core.
# usage: -tclargs <part> [<period_ns>] [<pblock_region>]
# The refill gather and insert-address paths are ~75% routing because each
# pipeline level's 4 BRAM banks land in 4 different BRAM columns spread across
# the full die width. Compacting the core into fewer BRAM columns shortens the
# horizontal span of every cross-level net.
set part xc7a100tcsg324-1
set period 4.000
set region CLOCKREGION_X0Y0:CLOCKREGION_X0Y3
if { $argc >= 1 } { set part [lindex $argv 0] }
if { $argc >= 2 } { set period [lindex $argv 1] }
if { $argc >= 3 } { set region [lindex $argv 2] }
set outdir syn/out_fp_[string map {: _} $part]_p[string map {. _} $period]
file mkdir $outdir

read_verilog rtl/ram_dp.v rtl/pheap.v
set xdc [open $outdir/clk.xdc w]
puts $xdc "create_clock -period $period -name clk \[get_ports clk\]"
puts $xdc "set_input_delay  -clock clk 0.200 \[all_inputs\]"
puts $xdc "set_output_delay -clock clk 0.200 \[all_outputs\]"
close $xdc
read_xdc -mode out_of_context $outdir/clk.xdc

synth_design -top pheap -part $part -mode out_of_context
report_utilization -file $outdir/post_synth_util.rpt

opt_design -retarget -propconst -sweep

# floorplan: pull the whole core into the chosen region
create_pblock pb_core
resize_pblock pb_core -add $region
add_cells_to_pblock pb_core [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE==1}]
set_property CONTAIN_ROUTING 0 [get_pblocks pb_core]

place_design
phys_opt_design
route_design

report_timing_summary -file $outdir/post_route_timing.rpt
report_utilization    -file $outdir/post_route_util.rpt
report_timing -max_paths 10 -nworst 1 -file $outdir/post_route_paths.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "RESULT_PART $part"
puts "RESULT_REGION $region"
puts "RESULT_WNS $wns"
puts "RESULT_WHS $whs"
