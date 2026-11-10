# Sigma-delta modulator (`rtl/sigma_delta2.v`)

Status: **draft**

`sigma_delta2` turns a 16-bit signed sample into a one-bit stream whose average follows the sample. An RC filter on the pin turns the stream back into a voltage: it is a DAC for a board without one. A machine uses one per audio output.

## 1. Summary

| Item | Value |
|------|-------|
| Order | Second; first with `ORDER` 1 |
| Input | 16 bits signed, taken every clock |
| Output | 1 bit, registered, one per clock |
| Scale | The feedback is ±2^16, twice the input's full scale, so the loop is stable for every input |
| Average of the output | 1/2 + x / 2^17: from 1/4 (x = −32 768) to just under 3/4 (x = 32 767) |
| Internal state | Two 24-bit signed integrators (one with `ORDER` 1) |
| Clock | Any; one domain |
| Parameters | `ORDER`, `DSP` |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock; the bit rate | – |
| `rst` | in | 1 | Synchronous reset | Integrators 0, `y` 0 |
| `x` | in | 16, signed | The sample | Taken at every edge; hold it between samples |
| `y` | out | 1 | The bit stream | Registered |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `ORDER` | 2 | 1: a first-order modulator: `y` is 1 when the new `i1` is 0 or more, and there is no `i2`. About a quarter of the size, with more noise left in the audio band: for an output where quality matters less (a small internal speaker). The average of the output is the same |
| `DSP` | 0 | 1: the adders carry the Xilinx `use_dsp` attribute, so Vivado builds them in DSP blocks (about 4 a unit) in place of about 70 LUTs. The stream is the same bit for bit. The two adds are in series in one clock: a machine that sets it checks its own timing. Other tools ignore it |

The width (16 bits in, 24-bit integrators, feedback ±65 536) is fixed. A machine drives it at its system clock (for example 100 MHz).

## 4. Behaviour

At every edge (not in reset), with `fb` = +65 536 when `y` is 1 and −65 536 when it is 0:

| Value | New value |
|-------|-----------|
| `i1` | `i1 + x − fb` |
| `i2` | `i2 + (i1 + x − fb) − fb` |
| `y` | 1 when the new `i2` is 0 or more |

- The new `i2` uses the new `i1` (both from the same clock's sums), so `y` answers a change of `x` on the next edge.
- Over a long run, the number of ones in N clocks is N × (1/2 + x / 2^17), within a few counts.
- x = 0 gives an even stream (a pattern near 0101…), the middle of the output's range.
- The stream's noise is pushed to high frequencies; the RC filter on the pin removes it.

## 5. How a machine uses it

- One instance per output: for stereo, left and right; a mono output from (left + right) / 2, with the sum taken in 17 bits and the top 16 bits passed in.
- Mix and clip the sources before the modulator: `x` must be a 16-bit signed sample.
- Use the pin's output flip-flop (an IOB register), so that every bit has the same length.
- The machine's own test checks its mix.

## 6. Test plan

`test/sigma_delta2` (`tb_sigma_delta2.v`) checks:

| Check | How |
|-------|-----|
| After reset | `y` is 0 or 1, not unknown |
| Pulse density | For x = 0, ±8 192, 32 767, −32 768 and 1 234: after 4 096 clocks to settle, the ones in 2^17 clocks are 65 536 + x, within 4. The same for a unit with `ORDER` 1 |
| `DSP` | A unit with `DSP` 1 gives the same stream as one without, every clock |

A machine's audio test checks its streams at its own levels (for example a beeper at a quarter of full scale).

## 7. Open points

| # | Point |
|---|-------|
| S1 | There is no dither. A constant input gives a repeating pattern, which can be heard as a faint tone after a poor filter. |
| S2 | Only half the stream's range is used (1/4 to 3/4), for stability. A higher order or a larger range would need new scaling. |
