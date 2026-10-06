# 250 MHz target clock for out-of-context synthesis/implementation
create_clock -period 4.000 -name clk [get_ports clk]

# Modest boundary budgets so port paths are timed honestly in OOC mode
set_input_delay  -clock clk 0.200 [all_inputs]
set_output_delay -clock clk 0.200 [all_outputs]
