# The fifo8 unit test (Icarus Verilog): passes when every log says TEST PASSED.
# It runs at AW = 1 (the smallest), 2 and 3, so that full is reached often.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
AWS      := 1 2 3

.PHONY: test
test: $(foreach a,$(AWS),build/tb_fifo8_aw$(a).vvp)
	@set -e; for a in $(AWS); do \
	    $(VVP) -n build/tb_fifo8_aw$$a.vvp | tee build/tb_fifo8_aw$$a.log; \
	    grep -q '^TEST PASSED' build/tb_fifo8_aw$$a.log; \
	done

build/tb_fifo8_aw%.vvp: tb_fifo8.v $(RTL)/fifo8.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -P tb_fifo8.AW=$* -o $@ -s tb_fifo8 tb_fifo8.v $(RTL)/fifo8.v
