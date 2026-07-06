# Timing constraints for the DE10-Lite control core.

# 50 MHz board oscillator
create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]

derive_clock_uncertainty

# Asynchronous inputs: encoder channels, buttons, switches. All are
# re-synchronized inside the FPGA (2-flop synchronizers in the decoder;
# quasi-static for SW/KEY), so cut them from timing analysis.
set_false_path -from [get_ports {ENC_A ENC_B}]
set_false_path -from [get_ports {KEY[*] SW[*]}]

# Outputs drive LEDs / a scope / an H-bridge DIR pin — no sampling clock
# on the far end, so no meaningful I/O timing requirement.
set_false_path -to [get_ports {LEDR[*] PWM_OUT MOTOR_DIR}]
