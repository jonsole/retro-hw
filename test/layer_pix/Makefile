# The layer_pix unit test (Icarus Verilog): passes when the log says TEST PASSED.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl

.PHONY: test
test: build/tb_layer_pix.vvp
	$(VVP) -n build/tb_layer_pix.vvp | tee build/tb_layer_pix.log
	grep -q '^TEST PASSED' build/tb_layer_pix.log

build/tb_layer_pix.vvp: tb_layer_pix.v $(RTL)/layer_pix.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_layer_pix tb_layer_pix.v $(RTL)/layer_pix.v
