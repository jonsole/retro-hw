# The dmac unit test (Icarus Verilog), run for several sizes of N
# (requesters) and S (slots): passes when every log says TEST PASSED.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl

# N_S pairs: the two machines' size, the smallest, a power of 2 and odd sizes
CONFIGS  := 7_5 1_1 8_8 3_6 5_3

.PHONY: test
test: $(CONFIGS:%=build/tb_dmac_%.log)
	@for f in $^; do grep -q '^TEST PASSED' $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "dmac: all sizes passed"

build/tb_dmac_%.log: build/tb_dmac_%.vvp
	$(VVP) -n $< | tee $@

build/tb_dmac_%.vvp: tb_dmac.v $(RTL)/dmac.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o $@ -s tb_dmac \
	    -Ptb_dmac.N=$(word 1,$(subst _, ,$*)) -Ptb_dmac.S=$(word 2,$(subst _, ,$*)) tb_dmac.v $(RTL)/dmac.v
