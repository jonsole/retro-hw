# The timebase unit test (Icarus Verilog): passes when the log says TEST PASSED.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl

.PHONY: test
test: build/tb_timebase.vvp
	$(VVP) -n build/tb_timebase.vvp | tee build/tb_timebase.log
	grep -q '^TEST PASSED' build/tb_timebase.log

build/tb_timebase.vvp: tb_timebase.v $(RTL)/timebase.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_timebase tb_timebase.v $(RTL)/timebase.v
