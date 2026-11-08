# Unit test for rtl/sigma_delta2.v: pulse density for constant inputs.
IVERILOG ?= iverilog
VVP      ?= vvp
ROOT     := ../..

.PHONY: test clean
test: tb_sigma_delta2.vvp
	$(VVP) -n tb_sigma_delta2.vvp | awk '{ print } /^TEST PASSED/ { ok = 1 } END { exit !ok }'

tb_sigma_delta2.vvp: tb_sigma_delta2.v $(ROOT)/rtl/sigma_delta2.v
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_sigma_delta2 -o $@ $^

clean:
	rm -f tb_sigma_delta2.vvp
