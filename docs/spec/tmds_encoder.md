# TMDS encoder (`tmds_encoder`)

Status: **draft**

The TMDS encoder turns one 8-bit colour component into the 10-bit word that DVI sends on one data lane each pixel clock. During blanking it sends one of the four control words instead. It is the encoder of the DVI 1.0 specification, section 3.2.2: transition minimising, then DC balance with a running disparity. A video output needs three, one per lane (`hdmi_out`, platform spec).

File: `rtl/tmds_encoder.v`.

## 1. Summary

| Item | Value |
|------|-------|
| Clock | The pixel clock (27 MHz for 576p in both machines) |
| In | 8 data bits, 2 control bits, data enable |
| Out | 10 bits a pixel clock, registered |
| Latency | 1 pixel clock |
| Data periods | DVI 1.0 8b/10b: transition minimising (XOR or XNOR chain), DC balance (running disparity, 5 bits signed) |
| Control periods | The four DVI control words; the disparity is cleared |
| HDMI | With `HDMI` = 1: also guard band words and TERC4 words, chosen by `m`, for data islands (`hdmi_packets` drives them). Without: DVI only |
| Parameters | `HDMI` |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | Pixel clock | – |
| `d` | in | 8 | The colour component, 0–255 | Sampled at each edge while `de` is 1 |
| `c` | in | 2 | Control bits C1, C0. On the blue lane {vsync, hsync}; 0 on the others for DVI | Sampled at each edge while `de` is 0 |
| `m` | in | 2 | With `HDMI`: 0 the word `de` says (a pixel or a control word); 1 a guard band word; 2 the TERC4 word of `a`. Without: not used (tie to 0) | Sampled at each edge |
| `g` | in | 1 | With `HDMI`: the guard band word: 0 is 1011001100, 1 is 0100110011 | With `m` = 1 |
| `a` | in | 4 | With `HDMI`: the four bits for TERC4 | With `m` = 2 |
| `de` | in | 1 | 1 = data (active picture), 0 = control (blanking) | Sampled at each edge |
| `q` | out | 10 | The TMDS word. Bit 0 is sent first | Registered: the word for the inputs at edge n is on `q` from edge n |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `HDMI` | 0 | 1: `m`, `g` and `a` are used: guard band and TERC4 words for HDMI's data islands. 0: DVI only, and they are not used |

## 4. Behaviour

### 4.1 Data periods (`de` 1)

Stage 1, transition minimising, is combinational. Let N1(d) be the number of ones in `d`.

| Condition | qm[0] | qm[i], i = 1–7 | qm[8] |
|-----------|-------|----------------|-------|
| N1(d) > 4, or N1(d) = 4 and d[0] = 0 | d[0] | XNOR(qm[i−1], d[i]) | 0 |
| Otherwise | d[0] | XOR(qm[i−1], d[i]) | 1 |

Stage 2, DC balance, sets `q` and the running disparity `cnt` at the edge. N1 and N0 are the ones and zeros in qm[7:0].

| Condition | q[9] | q[8] | q[7:0] | New `cnt` |
|-----------|------|------|--------|-----------|
| `cnt` = 0 or N1 = N0 | ~qm[8] | qm[8] | qm[8] ? qm[7:0] : ~qm[7:0] | qm[8] ? `cnt` + N1 − N0 : `cnt` + N0 − N1 |
| (`cnt` > 0 and N1 > N0) or (`cnt` < 0 and N0 > N1) | 1 | qm[8] | ~qm[7:0] | `cnt` + 2·qm[8] + N0 − N1 |
| Otherwise | 0 | qm[8] | qm[7:0] | `cnt` − 2·(~qm[8]) + N1 − N0 |

This is the DVI 1.0 algorithm as written there.

### 4.2 Control periods (`de` 0)

| C1 C0 | `q` (bit 9 … bit 0) |
|-------|---------------------|
| 00 | `1101010100` |
| 01 | `0010101011` |
| 10 | `0101010100` |
| 11 | `1010101011` |

`cnt` is set to 0 at every control-period edge, so each line's picture starts with no disparity.

### 4.3 Timing

`q` is a register: the word for the `d`, `c` and `de` sampled at edge n is on `q` from edge n until edge n + 1. Stage 1, the ones counts and the choice in stage 2 are one combinational path from `d` to `q` within one pixel clock (about 37 ns at 27 MHz).

### 4.4 Start-up

`cnt` starts at 0 from its initial value (the FPGA's configuration); there is no reset port. `q` has no initial value and is undefined until the first edge. Any control period clears `cnt` again.

## 5. How a machine uses it

- **Three encoders**, one per lane: blue (lane 0) with `c` = {vsync, hsync}, green (lane 1) and red (lane 2) with `c` = 0. All three on the same pixel clock and the same `de`, so their words line up.
- **The video timing** provides `d`, `de`, hsync and vsync on the pixel clock, with `de` 0 through the whole of horizontal and vertical blanking. The syncs go in at the active level the mode needs (576p: both active low); the encoder sends what it is given.
- **A serialiser** sends the 10 bits, bit 0 first, at 10 times the pixel clock (`hdmi_out` does this on the Artix-7).
- **Latency.** Each encoder adds one pixel clock. The syncs pass through the blue encoder, so picture and syncs stay together; anything sent beside the TMDS lanes (a VGA output, say) must add the same delay if it is to line up.

## 6. Test plan

There is no unit test in `test/` yet (open point E1). Neither machine's simulation looks at the TMDS words: the whole-system testbenches check the video timing and the colours before the encoders. The encoder is tested on the board:

| Test | Machine | What it covers |
|------|---------|----------------|
| The KS2 bitstream on an HDMI monitor and the HDMI capture device | retro-z80 | The picture, syncs and every colour of the palette on a real sink, every build |
| The KS3 bitstream on an HDMI monitor | retro68k | The same |

## 7. Open points

| # | Item |
|---|------|
| E1 | Proposed: a unit test `test/tmds_encoder/` with a reference model of DVI 1.0's flow chart (in the testbench, or words from a Python model): all 256 values of `d` from each disparity reached, random runs of data, the four control words, `cnt` cleared by a control period; and a decoder that checks each word decodes back to `d`, that the disparity stays bounded, and that a data word never matches a control word |
| E2 | `cnt` relies on its initial value; there is no reset. This is fine on an FPGA. A reset port could be added if a machine needs one |
| E3 | Done: with `HDMI` = 1 the encoder sends guard band and TERC4 words too (the 16 TERC4 words of HDMI 1.4, table 5-6), and the running disparity is cleared by them as by a control word. `test/hdmi_packets` decodes them |
| E4 | The data path is one pixel clock of logic. At 27 MHz this has a wide margin; a faster mode (720p at 74.25 MHz, say) should be checked, and could need a pipeline stage |
