# sprite_fetch.v: the unit test (two sprites from a memory model, their FIFOs
# checked), and the core in lockstep with a frozen copy of its earlier self
# (ref/) in both machines' builds. Passes when every log says TEST PASSED.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
BUILD    := build
LOGS     := $(BUILD)/sprites.log $(BUILD)/lock68k.log $(BUILD)/lockz80.log

.PHONY: test clean
test: $(LOGS)
	@for f in $(LOGS); do grep -q "^TEST PASSED" $$f || { echo "FAILED: $$f"; exit 1; }; done
	@echo "sprites: all passed"

$(BUILD)/sprites.log: $(BUILD)/tb_sprite_fetch.vvp
	$(VVP) -n $< | tee $@
$(BUILD)/lock68k.log: $(BUILD)/tb_lock68k.vvp
	$(VVP) -n $< | tee $@
$(BUILD)/lockz80.log: $(BUILD)/tb_lockz80.vvp
	$(VVP) -n $< | tee $@

$(BUILD)/tb_sprite_fetch.vvp: tb_sprite_fetch.v $(RTL)/sprite_fetch.v
	mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_sprite_fetch -o $@ tb_sprite_fetch.v $(RTL)/sprite_fetch.v

# retro68k's build: 8 sprites, 23-bit pointers, big-endian, URGENT 5, MANUAL
$(BUILD)/tb_lock68k.vvp: tb_lock_sprite.v ref/sprite_fetch_ref.v $(RTL)/sprite_fetch.v
	mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_lock_sprite -o $@ tb_lock_sprite.v ref/sprite_fetch_ref.v $(RTL)/sprite_fetch.v
# retro-z80's: 4 sprites, 22-bit pointers, little-endian, URGENT 6, no MANUAL
$(BUILD)/tb_lockz80.vvp: tb_lock_sprite.v ref/sprite_fetch_ref.v $(RTL)/sprite_fetch.v
	mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_lock_sprite -o $@ \
	    -Ptb_lock_sprite.NS=4 -Ptb_lock_sprite.PW=22 -Ptb_lock_sprite.LITTLE=1 -Ptb_lock_sprite.URGENT=6 -Ptb_lock_sprite.MANUAL=0 \
	    tb_lock_sprite.v ref/sprite_fetch_ref.v $(RTL)/sprite_fetch.v

clean:
	rm -rf $(BUILD)
