# Platform parts

Status: **draft**

The cores in `rtl/` are plain Verilog with no vendor primitives. What needs the FPGA's own I/O hardware sits in `platform/`: one folder for the Xilinx 7-series parts the Next uses, and one with behavioural stand-ins for simulation. Each part has the same module name and ports in both folders, so a machine picks the folder in its build or its testbench and nothing else changes.

| File | Module | What |
|------|--------|------|
| `platform/artix7/hdmi_out.v` | `hdmi_out` | DVI over the HDMI connector: three `tmds_encoder`s, 10:1 serialisers, differential outputs |
| `platform/artix7/oddr.v` | `oddr` | A DDR output register: two values a clock, one per half |
| `platform/sim/oddr.v` | `oddr` | The same in behavioural Verilog, for simulation |
| `platform/artix7/lint_stub.v` | several | Empty stand-ins for the Xilinx primitives, for linting only |

There is no simulation model of `hdmi_out` (open point P1).

## 1. Summary

| Item | `hdmi_out` | `oddr` |
|------|------------|--------|
| Clocks | Pixel clock and 5 × pixel clock | One |
| In | 24-bit RGB, hsync, vsync, data enable | Two values for each clock |
| Out | 4 TMDS pairs: 0 blue, 1 green, 2 red, 3 clock | The pin |
| Primitives | `OSERDESE2` (master and slave per lane), `OBUFDS` | `ODDR` in SAME_EDGE mode, one per bit |
| Parameters | None | W (width), INIT (power-up value) |

## 2. Ports

### 2.1 `hdmi_out`

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk_pix` | in | 1 | Pixel clock (27 MHz for 576p) | – |
| `clk_pix5` | in | 1 | 5 × the pixel clock (135 MHz), from the same MMCM | – |
| `rst` | in | 1 | Serialiser reset, active high | Synchronous to `clk_pix` |
| `rgb` | in | 24 | Bits 23–16 red, 15–8 green, 7–0 blue | Sampled at each `clk_pix` edge |
| `hsync`, `vsync` | in | 1 each | The syncs, at the level to be sent (for 576p both active low) | With `rgb` |
| `de` | in | 1 | 1 = picture, 0 = blanking | With `rgb` |
| `hdmi_on` | in | 1 | With `AUDIO`: 1 sends HDMI with sound, 0 DVI | A level; taken at a frame's start |
| `clk` | in | 1 | With `AUDIO`: the system clock, for the samples | – |
| `aud_l`, `aud_r`, `aud_v` | in | 16, 16, 1 | With `AUDIO`: a signed stereo sample and its strobe | On `clk` |
| `tmds_p`, `tmds_n` | out | 4 each | The four TMDS pairs: 0 blue, 1 green, 2 red, 3 clock | To the pins only |

### 2.2 `oddr`

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | – |
| `d_r` | in | W | The value for the first half of the next clock | Sampled at the rising edge |
| `d_f` | in | W | The value for the second half of the next clock | Sampled at the same rising edge |
| `q` | out | W | The pin | `d_r` from the edge after the sample, `d_f` from half a clock later |

## 3. Parameters

| Part | Name | Default | Meaning |
|------|------|---------|---------|
| `hdmi_out` | AUDIO | 0 | 1: HDMI with stereo sound through `hdmi_packets`; the picture leaves 12 pixel clocks later. 0: DVI only |
| `hdmi_out` | VIC | 17 | With AUDIO: the picture's video code for the AVI InfoFrame |
| `oddr` | W | 1 | Number of bits |
| `oddr` | INIT | 0 | The value of `q` at power-up, before the first clock, per bit. A machine's SRAM controls use 1, so /OE, /WE and the data enable are off from the start |

## 4. Behaviour

### 4.1 `hdmi_out`

- Three `tmds_encoder`s (its spec) on `clk_pix`: blue with control bits {`vsync`, `hsync`}, green and red with control bits 0. So the output is DVI: no data islands, no audio, no InfoFrames. A sink sees a DVI source and takes full-range RGB.
- The clock lane sends the fixed word `0000011111`: five ones then five zeros, one pixel clock period.
- Each lane is a pair of `OSERDESE2` in 10:1 DDR mode: the master takes word bits 0–7, the slave bits 8 and 9 (on its D3 and D4) and passes them to the master through SHIFTOUT/SHIFTIN. CLKDIV is `clk_pix`, CLK is `clk_pix5`, so 10 bits go out a pixel clock, **bit 0 first**: 270 Mbit/s a lane at 27 MHz.
- Each serialiser drives an `OBUFDS` with IOSTANDARD `TMDS_33`.
- Pair order (0 blue, 1 green, 2 red, 3 clock) and bit order (least significant first) are those of the Next's own `hdmi_out_xilinx_a7.vhd`.
- **Latency:** one pixel clock in the encoders plus the serialisers' fixed latency, the same on all four lanes, so the lanes stay in step.
- **Reset:** while `rst` is 1 the serialisers are held (output 0, `INIT_OQ`). Their reset must be released synchronously to CLKDIV, after both clocks run and are stable.

### 4.2 `oddr`

Each bit is one `ODDR` in SAME_EDGE mode, with CE 1 and the set and reset tied off. At a rising edge both `d_r` and `d_f` are sampled; `q` shows `d_r` from that edge and `d_f` from the falling edge after it, until the next rising edge.

So a value a core sets at edge E (as its register output) is sampled by `oddr` at E + 1 clock, and the pin shows `d_r` from E + 1 clock to E + 1.5 clocks, then `d_f` until E + 2 clocks. At 100 MHz: `d_r` at E + 10 to E + 15 ns, `d_f` at E + 15 to E + 20 ns. `sram_ctl`'s pin timing (its spec, section 4.3) rests on this.

### 4.3 `oddr` in simulation

`platform/sim/oddr.v` does the same in behavioural code, with a 1 ns delay for the pad's clock-to-out: at the rising edge `q` takes `d_r` 1 ns later and `d_f` is held; at the falling edge `q` takes the held `d_f` 1 ns later. `q` starts at INIT. The file sets `` `timescale 1ns/1ps ``.

### 4.4 Lint stubs

`platform/artix7/lint_stub.v` has empty modules with the ports and parameters the machines use of `BUFG`, `OBUFDS`, `MMCME2_BASE`, `OSERDESE2`, `ODDR` and `IOBUF`, so Verilator can lint a board build without Vivado's libraries. They are never simulated or built: `OSERDESE2` outputs 0, `ODDR` passes `D1`, `MMCME2_BASE` copies its input clock to every output.

## 5. How a machine uses them

**`hdmi_out`:**

- One MMCM gives both clocks: `clk_pix` and `clk_pix5` = exactly 5 × `clk_pix`, each through a `BUFG`. (Both machines: 50 MHz in, 27 and 135 MHz out, as examples.)
- The reset: held while the MMCM is not locked (or at power-on), then released through a few flip-flops on `clk_pix`. Both machines use a 3-stage shift register on `clk_pix`; one releases it on the MMCM's lock, the other on the power-on reset.
- The video timing on `clk_pix` drives `rgb`, `hsync`, `vsync` and `de`.
- The board constraints: the pins of `tmds_p`; `tmds_n` follows. IOSTANDARD `TMDS_33` on all eight.

**`oddr`:**

- Use it for any pin that must change in the middle of a clock: the SRAM's /OE, /WE and data enable, with INIT 1.
- A board build lists `platform/artix7/oddr.v`; a testbench lists `platform/sim/oddr.v`; a lint lists the Artix-7 file with `lint_stub.v`.
- The pin it drives must have no other register between `oddr` and the pad; the `ODDR` is in the pad already.

## 6. Test plan

There are no unit tests in `test/` for these yet.

| Test | Machine | What it covers |
|------|---------|----------------|
| Whole-system testbenches, SRAM model with timing checks | Both | The behavioural `oddr` on /OE, /WE and the data enable, every memory cycle |
| The board, every boot | Both | The Artix-7 `oddr` driving the real SRAM; `hdmi_out` on a real HDMI monitor (and, for retro-z80, the HDMI capture device) |
| Lint (`lint.sh`) | Here | Every platform file against the lint stubs |

The Artix-7 files are not simulated anywhere: neither machine's testbench has the Xilinx simulation library.

## 7. Open points

| # | Item |
|---|------|
| P1 | Proposed: a behavioural `platform/sim/hdmi_out.v` that serialises the words bit 0 first on `clk_pix5`'s both edges, and a unit test `test/hdmi_out/` that deserialises the four lanes, finds the word boundary from the clock lane, decodes TMDS and checks the pixels, syncs and `de` against the input |
| P2 | Proposed: a unit test `test/oddr/` that checks the behavioural `oddr` against its spec (`d_r` then `d_f`, INIT before the first clock), and, if the Xilinx library is to hand, against `ODDR` in the unisim model |
| P3 | `hdmi_out`'s header says "on the KS3", but the KS2 uses it too; its spec reference ("spec 4, section 3.3") is a machine's. Proposed: point to this spec |
| P4 | `lint_stub.v`'s header refers to `fpga/lint.sh`, a machine's path; here it is `lint.sh` at the top |
| P5 | `platform/sim/oddr.v` holds `d_f` in a register with no initial value. If a testbench's clock starts with a falling edge, `q` is X for half a clock. Harmless in both machines' testbenches |
| P6 | Done: `hdmi_out` with `AUDIO` = 1 puts `hdmi_packets` in front of the encoders (its spec); `VIC` is the picture's code for the AVI InfoFrame. With `AUDIO` = 0 it is the DVI output as before and the new inputs are not used |
