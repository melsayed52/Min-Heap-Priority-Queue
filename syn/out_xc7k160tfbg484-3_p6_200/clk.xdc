create_clock -period 6.200 -name clk [get_ports clk]
set_input_delay  -clock clk 0.200 [all_inputs]
set_output_delay -clock clk 0.200 [all_outputs]
