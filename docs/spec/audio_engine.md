# Audio engine (audio_engine)

Status: **draft**, revision 3: Jon's decisions are in (U1, U11), and both machines have reviewed and agreed it. It locks when its PR merges, which needs both machines' Vivado builds. `rtl/audio_engine.v` implements it and passes its model test. From retro68k's `fpga/rtl/audio.v` and its spec 6 (branch `live-ctrl`, 6955b38): the same sound but for interpolation across a block's end (4.3), with the registers' bus, the interrupt and the DACs left to the machine.

The audio engine plays sample channels from memory, in the spirit of the Amiga's Paula. Each channel plays a block of 8- or 16-bit samples at any pitch, with its own left and right volume, and needs no CPU work while it plays. At the end of a block a channel takes its address and length again, so a sample loops, or the next one can be queued. Once every output sample the engine visits the channels in turn, reads the one or two words each needs, and puts out one signed stereo sample.

The core has no bus. The machine's wrapper decodes its registers onto a small write port, turns its enables into start and stop strobes, keeps the status and interrupt bits from the core's event strobes, and feeds the output to its DACs ([sigma_delta2](sigma_delta2.md)).

## 1. Summary

| Item | Value |
|------|-------|
| Channels | `NCH`, 1 to 4, all alike |
| Output | One signed 16-bit stereo sample every `rate` clocks |
| Samples | 8-bit or 16-bit signed, per channel |
| Pitch | A step per output sample, 4.16 fixed point: 1/65536 to just under 16 samples per output sample |
| Resampling | Linear interpolation between neighbouring samples (`INTERP`), or nearest, per channel |
| Volume | Left and right per channel, 0 to 64 |
| Blocks | A channel takes its address and length when it starts and at the end of each block, and strobes an event each time. One-shot: it stops at the end of its block instead |
| Mixer | The channels summed; nothing can clip |
| Memory | One word port, reads only, on the scheduler (`dmac.v`): one or two reads per playing channel per output sample |
| Byte order | Big- or little-endian memory (`LE`) |
| Channel settings | Held in the core, written through a small port; read back with `RDBACK` |
| Not in the core | The registers' bus and layout, enables, status and interrupt bits, the DACs |

## 2. Ports

All inputs are sampled on the rising edge of `clk`. "Strobe" means high for one clock.

### 2.1 Clock, rate and channel control

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | |
| `rst` | in | 1 | Reset: every channel stopped, no request, output 0. The channel settings are not changed (4.9) | Synchronous |
| `rate` | in | 16 | Clocks per output sample; 0 is 65 536. There is no floor: a rate shorter than the engine's work makes each sample begin as the one before ends (4.7) | Level; used when each output sample starts |
| `start` | in | `NCH` | Bit n: channel n starts, or starts again, from its settings at the next output sample | Strobe |
| `stop` | in | `NCH` | Bit n: channel n stops (4.2), and a start not yet taken is forgotten. `stop` wins over `start` in the same clock | Strobe |
| `on` | out | `NCH` | Bit n: channel n is playing | Register |
| `ev` | out | `NCH` | Bit n: channel n took its address and length (it started, or reached the end of a block), or its one-shot block ended | Strobe |

### 2.2 Channel settings

Six fields a channel, held in the core.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `set_we` | in | 1 | Write `set_d` to field `set_f` of channel `set_ch` | Strobe |
| `set_ch` | in | 2 | The channel | With `set_we` |
| `set_f` | in | 3 | The field (below) | With `set_we` |
| `set_d` | in | 24 | The value | With `set_we` |
| `set_be` | in | 3 | Which bytes of the field are written: bit 0 is bits 7–0, bit 1 bits 15–8, bit 2 bits 23–16 | With `set_we` |
| `rb_re` | in | 1 | With `RDBACK`: read field `rb_f` of channel `rb_ch` | Strobe |
| `rb_ch`, `rb_f` | in | 2, 3 | The channel and field to read | With `rb_re` |
| `rb_q` | out | 24 | With `RDBACK`: that field, unused bits 0, in the clock after `rb_re` exactly, and held until the next read or `rst`, which clears it. Without: 0 | Register |

| Field | Name | Bits | Meaning |
|-------|------|------|---------|
| 0 | CTRL | 2–0 | Bit 0 `BITS16`: 16-bit samples. Bit 1 `NEAREST`: no interpolation. Bit 2 `ONESHOT`: play one block, then stop |
| 1 | LC | `AW`–0 | The block's address, in bytes. Even for 16-bit samples |
| 2 | LEN | `AW`–0 | The block's length, in samples. 0 stops the channel |
| 3 | STEP | 19–0 | Samples per output sample, 4.16 |
| 4 | VOL | 22–16, 6–0 | Left volume, right volume: 0 to 64; above 64 acts as 64 |
| 5 | POS | `AW`–0 | Read only: the sample the channel is at, in its block |

A write may come at any time, a byte at a time if the machine likes. The engine takes a channel's CTRL, STEP and VOL once in each output sample, when it begins that channel; LC and LEN only when the channel takes a block (4.2).

A read shares the engine's own way into the settings: the engine gives up that clock and carries on in the next, so a read is always answered in one clock and costs no second read port.

- **Writing LC and LEN.** A machine that writes them in several steps (bytes, or LC then LEN) must not be caught half way by a block's end, which would take a mix of old and new. The safe time is just after an `ev`: the channel has just taken them and will not again before its block ends. A block shorter than the time software needs to write the next one cannot be queued this way.

### 2.3 Memory

One requester on the scheduler, as the blitter's port but reads only.

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `mem_req` | out | 1 | A read is wanted; held until `mem_ack` |
| `mem_addr` | out | `AW` | Its word address |
| `mem_ack` | in | 1 | The read is taken |
| `mem_rvalid` | in | 1 | The word is on `mem_rdata`, a clock or more after `mem_ack` |
| `mem_rdata` | in | 16 | The word, a number in the machine's own byte order |

### 2.4 Output

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `out_l`, `out_r` | out | 16 each | The last output sample, signed | Registers |
| `out_v` | out | 1 | `out_l` and `out_r` are new | Strobe |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `NCH` | 4 | Channels, 1 to 4 |
| `AW` | 21 | Word address width, 16 to 23 |
| `LE` | 0 | 1: little-endian memory: of an 8-bit sample pair in a word, the first is the low byte |
| `INTERP` | 1 | 0: no interpolation is built; every channel plays as with `NEAREST`, and one read a channel is enough |
| `RDBACK` | 1 | 0: no read port (`rb_q` is 0) |

## 4. Behaviour

### 4.1 An output sample

Every `rate` clocks the engine makes one output sample:

1. The channels are worked on in order, 0 first. As the engine begins a channel, a start waiting for it is taken (4.2).
2. A playing channel's sample is read and interpolated (4.3, 4.4), multiplied by its two volumes and added to the left and right sums; then its position moves on (4.5). A channel not playing adds nothing.
3. The sums, divided by 256, go to `out_l` and `out_r`, and `out_v` strobes.

A channel's sample is 16 bits signed and a volume at most 64, so a product fits in 22 bits and four of them in 24: the sums always fit in 16 bits after the divide. One channel at full volume uses a quarter of the output range, as on the Amiga.

### 4.2 Blocks: starting, looping, queuing

- A `start` strobe is remembered until the engine next begins that channel, in the next output sample. The channel then takes LC and LEN as its block, goes to the block's first sample with a fraction of 0, strobes `ev`, and plays if LEN is not 0. This happens whether or not it was playing.
- When a playing channel's position passes the end of its block, it takes LC and LEN again, carries on into that block by the amount it overshot (4.5), and strobes `ev`. If LEN is then 0 it stops. With `ONESHOT` it stops instead of taking them, and strobes `ev`.
- A `stop` strobe clears `on` and forgets a start that was waiting, even one that would have been taken in that same clock (no `ev`, nothing taken). If the engine has already begun the channel in this output sample, it finishes it as if playing: its sample is in the sum, its position moves, and a block's end still takes LC and LEN and strobes `ev`; the channel is stopped all the same. From the next output sample it adds nothing.

So software loops a sample by writing LC and LEN once; plays a sample with a loop by writing the loop's LC and LEN after the first `ev`; and queues blocks by writing the next one at each `ev`.

### 4.3 Reading samples

A channel at sample i of its block (the position's whole part) needs s0, sample i, and s1, sample i + 1. With `NEAREST` (or without `INTERP`) only s0 is needed.

At the block's last sample, s1 is the first sample of the block to come: the sample at LC as the register stands when the engine reads this channel's samples, in the channel's format. So a loop interpolates round its join, and a queued block is joined to the one before. A one-shot channel, or one whose LEN register is 0 then, has no block to come: its s1 is s0. If software writes LC between that output sample and the block's real end, the block taken is the new one; the safe time to write is just after an `ev` (2.2).

- **8-bit** (`BITS16` 0): sample i is the byte at LC + i, shifted up by 8. In the word at byte address a & ~1, the byte at an even address is the high byte with `LE` 0 and the low byte with `LE` 1.
- **16-bit** (`BITS16` 1): sample i is the word at LC + 2i. LC's bit 0 is ignored.

The engine reads the word holding s0, then the word holding s1 if it is a different word and s1 is needed (not with `NEAREST`): one or two reads a channel. Reads are asked for one at a time; the engine waits for each.

### 4.4 Interpolation

```
s = s0 + floor((s1 − s0) × frac / 65536)
```

frac is the position's 16-bit fraction. With `NEAREST`, s = s0.

### 4.5 Moving on

The position (whole part and 16-bit fraction) grows by STEP. If its whole part is then at or past the block's length:

- with `ONESHOT` the channel stops;
- otherwise the old block's length is taken off, LC and LEN are taken as the new block, and if the whole part is at or past the new length too, it becomes 0 (the fraction stays).

### 4.6 The exact result

This is the definition the test model follows. Volumes are min(the field, 64). `>>` is an arithmetic shift.

```
when an output sample begins:
    L = R = 0
    for n = 0 .. NCH − 1:
      if a start is waiting for n (and no stop comes in this clock):
        blk_lc[n] = LC[n];  blk_len[n] = LEN[n];  pos[n] = 0
        on[n] = (LEN[n] ≠ 0);  ev[n]
      if on[n]:
        i  = pos[n] >> 16;   frac = pos[n] & 0xFFFF
        s0 = sample(n, i)
        if i + 1 < blk_len[n]:             s1 = sample(n, i + 1)
        else if ONESHOT[n] or LEN[n] = 0:  s1 = s0
        else:                              s1 = the first sample at LC[n] (BITS16[n]: the word at LC[n]; else the byte at LC[n], << 8)
        s  = (NEAREST[n] or not INTERP) ? s0 : s0 + (((s1 − s0) × frac) >> 16)
        L += s × VOLL[n];    R += s × VOLR[n]
        p = pos[n] + STEP[n]
        if (p >> 16) ≥ blk_len[n]:
            if ONESHOT[n]:  on[n] = 0;  ev[n]
            else:
                p = p − (blk_len[n] << 16)
                blk_lc[n] = LC[n];  blk_len[n] = LEN[n];  ev[n]
                if (p >> 16) ≥ LEN[n]:  p = p & 0xFFFF
                if LEN[n] = 0:  on[n] = 0
                pos[n] = p
        else:  pos[n] = p
    out_l = L >> 8;  out_r = R >> 8;  out_v

sample(n, i) = BITS16[n] ? the word at blk_lc[n] + 2i  :  the byte at blk_lc[n] + i, << 8
```

- CTRL (`BITS16`, `NEAREST`, `ONESHOT`), STEP and VOL above are the values taken when the engine began channel n in this output sample; LC and LEN are the values in the core in the clock the block is taken, and, for s1 at a block's last sample, in the clock the engine works out the channel's addresses (after it began the channel, before its first read).
- "if on[n]" is `on` as it stood when the engine began channel n: a stop after that does not undo the channel's work in this output sample, but `on` stays 0 whatever the work does.
- POS reads `pos[n] >> 16`.
- Addresses and positions are `AW` + 1 bits and wrap.

### 4.7 Time

Each output sample takes about 12 clocks a playing channel besides its reads. With four channels and a memory that answers within about 20 clocks, 200 clocks are enough; a machine sets `rate` to at least what its memory needs. If the engine has not finished when the next output sample is due, that sample begins when it has, and the one after it `rate` clocks later: so a `rate` too small for the engine gives samples as fast as it can make them, at a rate that depends on the memory. (retro68k's unit had a floor of 200 and dropped a late sample.)

### 4.8 Sequence

`ev` for a start strobes in the clock after the engine begins the channel; `ev` for a block's end in the clock after the channel's position moves. `out_v` strobes once per output sample, after the last channel. `on` is a register: it falls in the clock after a `stop`, and otherwise changes with the `ev`.

### 4.9 Reset and the settings

`rst` stops every channel, forgets waiting starts, drops any request and clears the output and `rb_q`. A word that comes back for a read asked before the reset is ignored, unless a new read has been asked by then: reset the scheduler with the core. The channel settings are kept in a small RAM and are not reset: after configuration they are CTRL 0, LC 0, LEN 0, STEP 0x10000, VOL 0 and POS 0, and after a later reset whatever was last written. Software writes a channel's settings before it starts it.

## 5. How a machine uses it

- A wrapper with the machine's registers: each channel register write becomes a `set_we` with its byte enables; reads use `rb_q`.
- `start` from the wrapper's start register and from its enables rising; `stop` from its stop register and its enables falling. A channel that is not enabled is never given a `start`.
- Status bits set by `ev`, cleared by software; an interrupt from them.
- `rate` from a register, or a constant.
- One requester on `dmac.v`.
- `out_l` and `out_r` to `sigma_delta2` modulators (scaled as the machine's DAC needs), or to any other output.
- Pan defaults, if the machine wants the Amiga's, are written by its start-up code.
- The machine's register bus must give `rb_q` a clock after its read strobe, as both machines' do.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/audio_engine`, random | The core against a bit-exact model of 4.6: random settings, blocks, steps below and above 1, 8- and 16-bit, odd addresses, nearest and interpolated, one-shots, queued blocks written at `ev`, starts while playing, stops at every point of the engine's work (the bench watches where the engine is), writes and reads during an output sample, rates down to 1, the join at a block's end for loops, queues, one-shots and a length of 0, a memory that is quick or slow. Every output sample, every `ev` and `on` are compared. Both byte orders, `NCH` 4 and 2, `INTERP` 0 |
| `test/audio_engine`, targeted | A stop in the very clock the engine begins a channel, with a start waiting and without; a reset. Twelve deliberate faults in the core are each caught |
| retro68k's own audio test | Its golden case (`sim/atest`: four channels at once with queued blocks, a one-shot, a restart and an enable turned off and on) runs against the core once its wrapper is ported |
| `drivers.sh`, the machines | As for the other cores |

## 7. Open points

| # | Point |
|---|-------|
| U1 | Choices made in this draft, agreed by Jon (10 November 2026): the channel settings live in the core (so they can be a small RAM and one shared datapath: retro68k's trial saved about 370 LUTs this way) and are written through a port with byte enables; they are not reset; no pan defaults in the core; status, interrupt enables, the enables' edges and the DACs are the wrapper's; `rate` is a port |
| U2 | 8-bit samples are a per-channel setting, as on retro68k, not a build parameter. A build of 8-bit only would save little |
| U3 | LC, LEN and POS are `AW` + 1 bits (the byte address space). retro68k's registers are 23 bits with `AW` 21: its top bit would read 0 |
| U4 | Read-back is a parameter. With the one-clock registered read it shares the engine's read of the settings, so it should cost far less than the 138 LUTs of retro68k's trial; to be measured. Without it POS cannot be read |
| U5 | The multiplies: retro68k's unit uses three (interpolation, left, right). The core uses one in turn, as `geom` does: about 12 clocks a channel besides its reads |
| U6 | Done in revision 3: interpolation across a block's end (retro68k's open point A2). retro68k's golden test numbers change at block ends; its model takes the same rule |
| U7 | More than 4 channels would need a wider sum, and a different shift or a limiter: four full-scale channels at volume 64 just fill 16 bits. Not in this revision |
| U8 | From the machines' review of revision 1: settings taken once a channel a sample; a one-clock registered read (both buses answer a clock after the strobe); one exact rule for a stop during the engine's work, the simplest to build, not retro68k's; the second read only when needed; a late engine delays the sample; the note on writing LC and LEN |
| U9 | retro68k's spec 6 gives reset values for VOL and STEP; with this core its start-up code writes them. Jon's call for retro68k |
| U11 | Jon's decisions for revision 3: interpolation across block ends, always; `rate` with no floor, 0 meaning 65 536; no loop registers, no gain input or limiter, no volume smoothing, 4.16 steps, one `ev` a channel, plain reads with no cache or urgent mark; a start restarts a playing channel; enables stay in the wrapper; `out_l`, `out_r` and `out_v` are the hook for a later HDMI audio block; the spec locks at merge |
| U12 | From the first Vivado gates (376c378): the move-on step read the position, added the step, compared and wrote back in one clock, which missed 100 MHz on the KS2's part, and the two sums were each built into a DSP block of their own. Now the sums for the move are made in the clocks of the volume multiplies, the second sample's address a clock after the first's, and the left and right sums are kept out of the multiplier's block. No behaviour changes |
| U10 | Size (of revision 2; revision 3 adds one address choice, about 18 cells), Yosys for 7-series (logic cells; besides them 35 RAM32M, about 140 LUTs, and one DSP block in every build): defaults 436 and 332 flip-flops; `RDBACK` 0: 384; `INTERP` 0: 327; `NCH` 2: 425; `NCH` 2 with `INTERP` 0 and `RDBACK` 0: 243. Vivado figures from the machines' gates to come. retro68k's unit is 1,228 LUTs in Vivado |
