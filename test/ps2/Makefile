# Unit test for rtl/ps2_core.v, against the keyboard model sim/ps2_model.v.
IVERILOG ?= iverilog
VVP      ?= vvp
ROOT     := ../..

.PHONY: test clean
test: tb_ps2_core.vvp
	$(VVP) -n tb_ps2_core.vvp | awk '{ print } /^TEST PASSED/ { ok = 1 } END { exit !ok }'

tb_ps2_core.vvp: tb_ps2_core.v $(ROOT)/rtl/ps2_core.v $(ROOT)/sim/ps2_model.v
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_ps2_core -o $@ $^

clean:
	rm -f tb_ps2_core.vvp
