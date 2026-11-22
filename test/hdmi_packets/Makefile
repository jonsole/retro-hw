# hdmi_packets.v and three tmds_encoders (HDMI = 1) against a decoder of the
# 10-bit words: the picture and syncs unchanged, every data period's
# preamble and guard band, every packet's check bytes and contents, every
# sample once and in order, and DVI when switched off
IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := ../../rtl

.PHONY: test
test: build/hdmi.log
	@grep -q '^TEST PASSED' $< || { echo "FAILED: $<"; exit 1; }
	@echo "hdmi_packets: passed"

build/hdmi.log: build/hdmi.vvp
	$(VVP) -n $< | tee $@

build/hdmi.vvp: tb_hdmi_packets.v $(RTL)/hdmi_packets.v $(RTL)/tmds_encoder.v
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -Wno-timescale -s tb_hdmi_packets -o $@ $^
