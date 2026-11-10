# The rasteriser against a pixel-exact model of its spec (4.5), on random and
# directed jobs: big- and little-endian memory, and lines only (TRI 0)
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
TBS      := be le notri

.PHONY: test
test: $(TBS:%=build/%.log)
	@for f in $^; do grep -q '^TEST PASSED' $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "raster: all passed"

build/%.log: build/%.vvp
	$(VVP) -n $< | tee $@

build/be.vvp: tb_raster.v $(RTL)/raster.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_raster -o $@ $^
build/le.vvp: tb_raster.v $(RTL)/raster.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_raster.LE=1 -s tb_raster -o $@ $^
build/notri.vvp: tb_raster.v $(RTL)/raster.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_raster.TRI=0 -s tb_raster -o $@ $^
