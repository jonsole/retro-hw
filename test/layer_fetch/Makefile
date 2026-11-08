# The layer_fetch tests (Icarus Verilog): the core in lockstep with each
# machine's bpldma.v (ref/), and a model test. Passes when every log says
# TEST PASSED.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
TBS      := tb_lock68k tb_lockz80 tb_model_1t tb_model_4c tb_model_2p

.PHONY: test
test: $(TBS:%=build/%.log)
	@for f in $^; do grep -q '^TEST PASSED' $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "layer_fetch: all passed"

build/%.log: build/%.vvp
	$(VVP) -n $< | tee $@

build/tb_lock68k.vvp: tb_lock68k.v ref/bpldma_68k.v $(RTL)/layer_fetch.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_lock68k tb_lock68k.v ref/bpldma_68k.v $(RTL)/layer_fetch.v

build/tb_lockz80.vvp: tb_lockz80.v ref/bpldma_z80.v $(RTL)/layer_fetch.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_lockz80 tb_lockz80.v ref/bpldma_z80.v $(RTL)/layer_fetch.v

# The model test, three builds: one tile layer (little-endian, retro-z80's
# KS2 shape), four chunky layers, two layers with planar (little-endian)
build/tb_model_1t.vvp: tb_model.v $(RTL)/layer_fetch.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_model -Ptb_model.NL=1 -Ptb_model.TILES=1 -Ptb_model.LITTLE=1 tb_model.v $(RTL)/layer_fetch.v
build/tb_model_4c.vvp: tb_model.v $(RTL)/layer_fetch.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_model -Ptb_model.NL=4 tb_model.v $(RTL)/layer_fetch.v
build/tb_model_2p.vvp: tb_model.v $(RTL)/layer_fetch.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_model -Ptb_model.NL=2 -Ptb_model.PLANAR=1 -Ptb_model.LITTLE=1 tb_model.v $(RTL)/layer_fetch.v
