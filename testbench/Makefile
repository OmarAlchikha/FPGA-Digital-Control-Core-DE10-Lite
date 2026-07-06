# Run the self-checking testbenches with Icarus Verilog.
#
#   make          - run both testbenches
#   make pwm      - PWM generator testbench only
#   make quad     - quadrature decoder testbench only
#   make waves    - run both and open the VCDs in GTKWave
#   make clean

IVERILOG ?= iverilog -g2012
VVP      ?= vvp
RTL      := ../rtl

.PHONY: all pwm quad waves clean

all: pwm quad

pwm: tb_pwm
	$(VVP) tb_pwm

quad: tb_quad
	$(VVP) tb_quad

tb_pwm: $(RTL)/pwm_generator.v tb_pwm_generator.v
	$(IVERILOG) -o $@ $^

tb_quad: $(RTL)/quadrature_decoder.v tb_quadrature_decoder.v
	$(IVERILOG) -o $@ $^

waves: all
	gtkwave tb_pwm_generator.vcd &
	gtkwave tb_quadrature_decoder.vcd &

clean:
	rm -f tb_pwm tb_quad *.vcd
