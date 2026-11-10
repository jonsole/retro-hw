# The audio engine against a bit-exact model of its spec (4.6), on random
# settings, starts, stops, read-backs and memory speeds: four channels with
# the memory big- and little-endian, and a small build (two channels, no
# interpolation, no read-back)
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
TBS      := be le small

.PHONY: test
test: $(TBS:%=build/%.log)
	@for f in $^; do grep -q '^TEST PASSED' $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "audio_engine: all passed"

build/%.log: build/%.vvp
	$(VVP) -n $< | tee $@

build/be.vvp: tb_audio_engine.v $(RTL)/audio_engine.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_audio_engine -o $@ $^
build/le.vvp: tb_audio_engine.v $(RTL)/audio_engine.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_audio_engine.LE=1 -Ptb_audio_engine.AW=18 -s tb_audio_engine -o $@ $^
build/small.vvp: tb_audio_engine.v $(RTL)/audio_engine.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Ptb_audio_engine.NCH=2 -Ptb_audio_engine.INTERP=0 -Ptb_audio_engine.RDBACK=0 -s tb_audio_engine -o $@ $^
