# The dmac unit test (Icarus Verilog): passes when the log says TEST PASSED.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl

.PHONY: test
test: build/tb_dmac.vvp
	$(VVP) -n build/tb_dmac.vvp | tee build/tb_dmac.log
	grep -q '^TEST PASSED' build/tb_dmac.log

build/tb_dmac.vvp: tb_dmac.v $(RTL)/dmac.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_dmac tb_dmac.v $(RTL)/dmac.v
