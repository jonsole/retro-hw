# copper_engine.v: lists from a memory model, decoded by a made-up
# instruction set; built twice, without and with the write handshake
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
BUILD    := build

.PHONY: test clean
test: $(BUILD)/tb_hs0.vvp $(BUILD)/tb_hs1.vvp
	$(VVP) -n $(BUILD)/tb_hs0.vvp | tee $(BUILD)/copper_hs0.log
	@grep -q "^TEST PASSED" $(BUILD)/copper_hs0.log
	$(VVP) -n $(BUILD)/tb_hs1.vvp | tee $(BUILD)/copper_hs1.log
	@grep -q "^TEST PASSED" $(BUILD)/copper_hs1.log

$(BUILD)/tb_hs0.vvp: tb_copper_engine.v $(RTL)/copper_engine.v
	mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_copper_engine -o $@ tb_copper_engine.v $(RTL)/copper_engine.v

$(BUILD)/tb_hs1.vvp: tb_copper_engine.v $(RTL)/copper_engine.v
	mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -DHS=1 -s tb_copper_engine -o $@ tb_copper_engine.v $(RTL)/copper_engine.v

clean:
	rm -rf $(BUILD)
