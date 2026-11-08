# Wiring in the sigma-delta modulator

`rtl/sigma_delta2.v` makes a one-bit DAC: give it a 16-bit signed sample every clock, and put its output through an RC low-pass filter to get the sound. The full description is in `docs/spec/sigma_delta2.md`.

## A minimal instantiation

```verilog
wire signed [15:0] left, right;           // your mix, clipped to 16 bits

sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(left),  .y(dac_l));
sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(right), .y(dac_r));

// mono: (left + right) / 2, summed in 17 bits
wire signed [16:0] mono = left + right;
sigma_delta2 sd_m (.clk(clk), .rst(rst), .x(mono[16:1]), .y(dac_m));
```

Drive the pins from flip-flops in the pads, so every bit is the same length.

## What the stream looks like

```
clk   _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
x = 0       y  _/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___   about half ones
x = +16384  y  _/‾‾‾‾‾‾‾‾‾‾‾\___/‾‾‾‾‾‾‾‾‾‾‾\___/‾‾‾‾‾‾   about 5/8 ones
x = -16384  y  _____/‾‾‾\___________/‾‾‾\___________/‾‾   about 3/8 ones
```

The share of ones is 1/2 + x / 2^17. Full scale (±32 768) gives 1/4 to 3/4, not 0 to 1: the modulator uses half its range so it never goes unstable.

## Pitfalls

- **Half range.** The filtered output swings over half the supply at most. Plan the analogue gain for that.
- **Silence is not 0 V.** x = 0 gives half ones: the output sits at mid-supply. Put a capacitor in series if the amplifier needs 0 V.
- **Clip before, not after.** The sum of several sources can wrap past 16 bits; clip to −32 768 … 32 767 before the modulator.
- **Mono is the average**, not the sum: pass the top 16 bits of the 17-bit sum.
- **The clock is the bit rate.** A faster clock pushes the noise higher, where the filter removes it better. At 100 MHz a simple RC filter is enough.
