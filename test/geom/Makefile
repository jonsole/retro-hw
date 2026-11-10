# The geometry engine against a bit-exact model of its spec (4.4), on random
# and directed jobs, with the memory big- and little-endian
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
TBS      := be le

.PHONY: test
test: $(TBS:%=build/%.log)
	@for f in $^; do grep -q '^TEST PASSED' $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "geom: all passed"

build/%.log: build/%.vvp
	$(VVP) -n $< | tee $@

build/be.vvp: tb_geom.v $(RTL)/geom.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_geom -o $@ $^
build/le.vvp: tb_geom.v $(RTL)/geom.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_geom.LE=1 -s tb_geom -o $@ $^
