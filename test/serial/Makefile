# serial_link.v and ft232h_if.v with the FT232H model
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl
SRC      := tb_serial_link.v $(RTL)/serial_link.v $(RTL)/slip_rx.v $(RTL)/ft232h_if.v $(RTL)/fifo8.v ../../sim/ft232h_model.v

.PHONY: test clean
test: build/tb_serial_link.vvp
	cd build && $(VVP) -n tb_serial_link.vvp | tee serial.log
	@grep -q "^TEST PASSED" build/serial.log

build/tb_serial_link.vvp: $(SRC)
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_serial_link -o $@ $(SRC)

clean:
	rm -rf build
