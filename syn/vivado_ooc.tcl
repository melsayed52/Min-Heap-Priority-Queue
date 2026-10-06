# vivado_ooc.tcl - batch OOC synth + place + route
# usage: vivado -mode batch -source syn/vivado_ooc.tcl [-tclargs <part> [<period_ns>]]
set part xc7z020clg400-1
set period 4.000
if { $argc >= 1 } { set part [lindex $argv 0] }
if { $argc >= 2 } { set period [lindex $argv 1] }
set outdir syn/out_[string map {: _} $part]_p[string map {. _} $period]
file mkdir $outdir

read_verilog rtl/ram_dp.v rtl/pheap.v
set xdc [open $outdir/clk.xdc w]
puts $xdc "create_clock -period $period -name clk \[get_ports clk\]"
puts $xdc "set_input_delay  -clock clk 0.200 \[all_inputs\]"
puts $xdc "set_output_delay -clock clk 0.200 \[all_outputs\]"
close $xdc
read_xdc -mode out_of_context $outdir/clk.xdc

synth_design -top pheap -part $part -mode out_of_context
report_timing_summary -file $outdir/post_synth_timing.rpt
report_utilization    -file $outdir/post_synth_util.rpt

# explicit phase list = default minus bram_power_opt (it gates BRAM read
# enables with deep consumer-valid logic, wrecking the read-pipeline timing)
opt_design -retarget -propconst -sweep
place_design
phys_opt_design
route_design

report_timing_summary -file $outdir/post_route_timing.rpt
report_utilization    -file $outdir/post_route_util.rpt
report_timing -max_paths 10 -nworst 1 -file $outdir/post_route_paths.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "RESULT_PART $part"
puts "RESULT_WNS $wns"
puts "RESULT_WHS $whs"
