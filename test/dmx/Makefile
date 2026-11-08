# dmx_core: directed jobs against a memory model, with the memory big- and
# little-endian, LINE and EDGES built; and once with them left out
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl

.PHONY: test
test: tb_be.vvp tb_le.vvp tb_nol.vvp
	$(VVP) -n tb_be.vvp | tee be.log
	@grep -q "^TEST PASSED" be.log
	$(VVP) -n tb_le.vvp | tee le.log
	@grep -q "^TEST PASSED" le.log
	$(VVP) -n tb_nol.vvp | tee nol.log
	@grep -q "^TEST PASSED" nol.log

tb_be.vvp: tb_dmx_core.v $(RTL)/dmx_core.v
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_dmx_core -o $@ $^

tb_le.vvp: tb_dmx_core.v $(RTL)/dmx_core.v
	$(IVERILOG) -g2005 -Wall -Wno-timescale -DLE=1 -s tb_dmx_core -o $@ $^

tb_nol.vvp: tb_dmx_core.v $(RTL)/dmx_core.v
	$(IVERILOG) -g2005 -Wall -Wno-timescale -DLINES=0 -s tb_dmx_core -o $@ $^

clean:
	rm -f *.vvp *.log
