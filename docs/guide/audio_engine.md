# Wiring in the audio engine

`audio_engine` plays up to four sample channels from memory and mixes them to one signed 16-bit stereo sample every `rate` clocks. Each channel plays a block of 8- or 16-bit samples at its own pitch and left and right volume, takes its address and length again at the block's end (a loop or a queue), and tells you with an event strobe. The spec, with the exact arithmetic, is `docs/spec/audio_engine.md`.

## What you write

- **The registers.** The core keeps each channel's settings; your wrapper turns a register write into one `set_we` with the channel, the field and byte enables, and a register read into one `rb_re`, with `rb_q` answering in the next clock.
- **Start and stop.** One-clock strobes a channel. Derive them from your enable bits' edges and from start and stop registers. Never give a `start` to a channel that is not enabled.
- **Status and interrupt.** Make `ev` sticky in a status register and raise your interrupt from it; `on` is the live "playing" bit.
- **The rate.** A register or a constant, in clocks per output sample.
- **The DACs.** `out_l` and `out_r` to `sigma_delta2` modulators, or anything else.

## A minimal instantiation

```verilog
audio_engine #(.NCH(4), .AW(21), .LE(0), .INTERP(1), .RDBACK(1)) aud (
    .clk(clk), .rst(rst),
    .rate(aud_rate), .start(ch_start), .stop(ch_stop), .on(ch_on), .ev(ch_ev),
    .set_we(aud_wr), .set_ch(reg_ch), .set_f(reg_field), .set_d(reg_wdata[23:0]), .set_be(reg_be[2:0]),
    .rb_re(aud_rd), .rb_ch(reg_ch), .rb_f(reg_field), .rb_q(aud_q),
    .mem_req(m_req), .mem_addr(m_addr),
    .mem_ack(sched_ack[AUD]), .mem_rvalid(sched_rvalid[AUD]), .mem_rdata(mem_rdata),
    .out_l(out_l), .out_r(out_r), .out_v(out_v)
);

sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(out_l), .y(dac_l));
sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(out_r), .y(dac_r));
```

The memory port is one requester on `dmac.v`, reads only. The core uses one 17×17 signed multiply: a DSP block where the FPGA has one.

## A typical sample

With `rate` 2083 at 100 MHz (48 kHz), every 2083 clocks:

```
clock      0        1..        about 12 a channel, plus its reads      end
engine     begin    channel 0, 1, 2, 3 in turn                          out_v
memory              one read a playing channel, two when it interpolates
                    across two words
```

`ev[n]` strobes while the engine is on channel n: at its first step if a start was waiting, at its last if its block ended.

## Using it

1. Write a channel's CTRL, LC, LEN, STEP and VOL.
2. Strobe `start`. At the next output sample the channel takes LC and LEN and plays; `ev` strobes.
3. To loop, do nothing more. To play an intro and then a loop, or to queue blocks, write the next LC and LEN when `ev` comes.
4. `stop`, or a one-shot's end, silences it.

## Pitfalls

- **The settings are not reset.** After configuration STEP is 0x10000 and everything else 0; after a later `rst` they are whatever was last written. Write VOL (it starts at 0: silence) and the rest before the first start. Pan defaults are yours to write.
- **Write LC and LEN just after an `ev`.** A block's end between two of your writes would take half of the old and half of the new. A block shorter than the time your software needs to write the next cannot be queued this way.
- **CTRL, STEP and VOL apply from the next output sample**, never inside one. They are taken every sample, so a machine that writes STEP a byte at a time can play one sample at a half-written pitch.
- **A stop is immediate for `on`, not for the mix.** A channel the engine is in the middle of still adds to that one output sample.
- **Reads take exactly one clock.** `rb_q` is right in the clock after `rb_re` and holds until the next read. Your bus must capture it then. Make `rb_re` a one-clock strobe: the engine waits for every clock it is high. To read a moving value like POS a byte at a time, latch all of `rb_q` on the first byte.
- **8-bit samples and byte order.** With `LE` 0 the byte at an even address is the word's high byte; with `LE` 1 its low byte. 16-bit samples are the memory's words as they are.
- **`rate` has no floor.** Give the engine time: about 12 clocks a channel plus its reads (200 clocks is plenty for four channels on a quick memory). A rate too small, or a slow memory, delays samples; none is dropped. 0 means 65 536.
- **Loops join smoothly.** At a block's last sample the engine interpolates towards the first sample at LC, so write the next block's LC and LEN just after an `ev` and not near the block's end. A machine that writes LC a byte at a time has the same reason twice over: an LC half written at the block's last sample joins to a wrong sample for that one output sample (a click, not a fault).
- **`AW` is at least 16.**
