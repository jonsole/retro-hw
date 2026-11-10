# The blitter against a pixel-exact model of its spec (4.8), on random and
# directed jobs: big- and little-endian memory, and without the mask image
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
TBS      := be le nomask

.PHONY: test
test: $(TBS:%=build/%.log)
	@for f in $^; do grep -q '^TEST PASSED' $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "blitter: all passed"

build/%.log: build/%.vvp
	$(VVP) -n $< | tee $@

build/be.vvp: tb_blitter.v $(RTL)/blitter.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_blitter -o $@ $^
build/le.vvp: tb_blitter.v $(RTL)/blitter.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_blitter.LE=1 -s tb_blitter -o $@ $^
build/nomask.vvp: tb_blitter.v $(RTL)/blitter.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_blitter.MASKIMG=0 -s tb_blitter -o $@ $^
