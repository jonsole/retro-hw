# sprite_fetch.v: two sprites fetched from a memory model, their FIFOs checked
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
BUILD    := build

.PHONY: test clean
test: $(BUILD)/tb_sprite_fetch.vvp
	$(VVP) -n $(BUILD)/tb_sprite_fetch.vvp | tee $(BUILD)/sprites.log
	@grep -q "^TEST PASSED" $(BUILD)/sprites.log

$(BUILD)/tb_sprite_fetch.vvp: tb_sprite_fetch.v $(RTL)/sprite_fetch.v
	mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_sprite_fetch -o $@ tb_sprite_fetch.v $(RTL)/sprite_fetch.v

clean:
	rm -rf $(BUILD)
