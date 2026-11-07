# Wiring in the platform parts

The platform parts are the bits that need the FPGA's own I/O hardware: `hdmi_out` (DVI on the HDMI connector) and `oddr` (a pin that changes twice a clock). The Artix-7 versions are in `platform/artix7/`, the simulation versions in `platform/sim/`, with the same module names and ports. The full details are in [the spec](../spec/platform.md).

## Which files go where

| Build | Files |
|-------|-------|
| Board (Vivado) | `platform/artix7/hdmi_out.v`, `platform/artix7/oddr.v`, `rtl/tmds_encoder.v` |
| Testbench (Icarus, Verilator) | `platform/sim/oddr.v`; leave `hdmi_out` out of the testbench's top level |
| Lint of a board top level (Verilator) | The Artix-7 files plus `platform/artix7/lint_stub.v` |

## `hdmi_out`

```verilog
// Both clocks from one MMCM, each through a BUFG: 27 MHz and 135 MHz for 576p
// Serialiser reset: held until the MMCM locks, released on clk_pix
reg [2:0] prst = 3'b111;
always @(posedge clk_pix) prst <= {prst[1:0], !mmcm_locked};

hdmi_out hdmi (
    .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rst(prst[2]),
    .rgb({red, green, blue}), .hsync(hs), .vsync(vs), .de(de),
    .tmds_p(hdmi_p_o), .tmds_n(hdmi_n_o)
);
```

```tcl
# Pins: pair 0 blue, 1 green, 2 red, 3 clock; the N pins follow
set_property -dict {PACKAGE_PIN ... IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[0]}]
...
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_n_o[*]}]
```

Two pixels on the wire, bit 0 first. Each bit is half a `clk_pix5` period (3.7 ns at 135 MHz), ten a pixel clock. The words come out a few pixel clocks after they were sampled, the same on every lane:

```
clk_pix   ‾‾‾‾‾_____‾‾‾‾‾_____
clk_pix5  ‾_‾_‾_‾_‾_‾_‾_‾_‾_‾_
lane 0    01234567890123456789   bits 0-9 of one blue word, then the next
lane 3    11111000001111100000   the clock lane: 0000011111, bit 0 first
```

## `oddr`

```verilog
// /WE: d_r for the first half of the next clock, d_f for the second
oddr #(.INIT(1'b1)) o_we (.clk(clk100), .d_r(we_r), .d_f(we_f), .q(ram_we_n_o));
```

```
clk       ‾‾‾‾‾_____‾‾‾‾‾_____‾‾‾‾‾_____‾‾‾‾‾
d_r, d_f  <1, 0=====<0, 1=====<1, 1=====
q         ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾__________‾‾‾‾‾‾‾‾‾‾
```

`q` starts at INIT (1). The values set at one edge appear on the pin from the next edge: `d_r` for the high half of that clock, `d_f` for the low half. Here the pin is 1 then 0 in the second clock, 0 then 1 in the third.

## Pitfalls

- **Two clocks from two MMCMs.** `clk_pix5` must come from the same MMCM as `clk_pix`, at exactly 5 times its frequency, or the serialisers lose the word boundary.
- **Releasing the reset too early.** Hold `rst` until both clocks are stable, and release it on `clk_pix`.
- **Bit order.** The words go out bit 0 first. A sink shows nothing if this is reversed.
- **Expecting HDMI.** It is DVI: no audio, no InfoFrames. HDMI sinks take DVI; there is just no sound over the cable.
- **`oddr` with logic after it.** Its output goes straight to the pad (or the T of an `IOBUF`). Nothing else may sit between.
- **INIT.** Use INIT 1 for active-low strobes, so they are off from configuration until the first clock.
- **`timescale` in simulation.** `platform/sim/oddr.v` sets `1ns/1ps` for its 1 ns pad delay. Give the testbench the same, or a finer one.
- **Lint stubs are not models.** They only make Verilator see the ports; never put `lint_stub.v` in a simulation.
