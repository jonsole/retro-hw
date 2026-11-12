# HDMI packets (hdmi_packets)

Status: **draft**, revision 1, Jon's design decisions in (H1), not yet reviewed by the machines or heard on a display. `rtl/hdmi_packets.v` implements it and passes its decoder test.

`hdmi_packets` turns a plain picture stream (pixels, syncs and data enable, as a DVI output takes them) into what three `tmds_encoder`s with `HDMI` = 1 need to send it as HDMI with stereo sound. It adds the lead-in HDMI wants before each line's picture, and in every line's blank it sends a data island: two packets carrying the sound's samples, the numbers a display needs to recover the sample clock, and two information frames that describe the picture and the sound.

It sits between a machine's video output and the encoders (`platform/artix7/hdmi_out.v` with `AUDIO` = 1 wires it in). A level input switches it off: the stream is then DVI, as it was before this core.

## 1. Summary

| Item | Value |
|------|-------|
| Picture | Passed through unchanged, 12 pixel clocks late (13 with the encoder) |
| Sound | Stereo, 16-bit signed samples, sent as 48 kHz linear PCM |
| Sample clock | Not resampled. N = 6144 and a CTS measured from the samples' real rate, so the display plays them at that rate |
| An island | One a line, in every line's blank: two packets |
| First packet | Up to four stereo samples (Audio Sample), or a null packet |
| Second packet | Audio Clock Regeneration when due; once a frame the AVI InfoFrame and the Audio InfoFrame; else a null packet |
| AVI InfoFrame | RGB, full range, 4:3, underscanned, the video code `VIC` |
| Timing it needs | A blank of at least 92 pixels a line. It learns the line's length itself |
| Clocks | The pixel clock; the samples come on the system clock and cross inside |
| Off | `on` low: DVI. No preambles, guard bands or islands |

## 2. Ports

Everything is on `clk_pix` unless said.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk_pix` | in | 1 | The pixel clock | |
| `rst` | in | 1 | Reset: no islands until a line's length is learnt again | Synchronous |
| `rgb` | in | 24 | The pixel: 23–16 red, 15–8 green, 7–0 blue | Every clock |
| `hsync`, `vsync` | in | 1 each | The syncs, at the level to be sent | With `rgb` |
| `de` | in | 1 | 1: picture. 0: blank | With `rgb` |
| `on` | in | 1 | 1: HDMI with sound. 0: DVI | A level from any clock; taken at each frame's start (4.6) |
| `clk` | in | 1 | The system clock, for the samples | |
| `aud_l`, `aud_r` | in | 16 each | A stereo sample, signed | On `clk`, with `aud_v` |
| `aud_v` | in | 1 | Strobe: a new sample | On `clk`. At least 16 `clk_pix` clocks between two |
| `o_rgb`, `o_de` | out | 24, 1 | The picture, late | To the encoders' `d` and `de` |
| `o_c0`, `o_c1`, `o_c2` | out | 2 each | The lanes' control bits: lane 0 {vsync, hsync}; lane 1 {CTL1, CTL0}; lane 2 {CTL3, CTL2} | To the encoders' `c` |
| `o_m0`, `o_m1`, `o_m2` | out | 2 each | Each lane's word this clock: 0 as `o_de` says (a pixel or a control word), 1 a guard band word, 2 the TERC4 word of its `o_a` | To the encoders' `m` |
| `o_g2` | out | 1 | Lane 2's guard band word (lane 0's is always pattern 0 and lane 1's pattern 1) | To lane 2's `g` |
| `o_a0`, `o_a1`, `o_a2` | out | 4 each | Each lane's four bits for TERC4 | To the encoders' `a` |

Lane 0 is blue, 1 green, 2 red.

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `VIC` | 17 | The AVI InfoFrame's video identification code. 17 is 720 × 576 at 50 Hz, 4:3 |

## 4. Behaviour

### 4.1 The picture's lead-in

With HDMI on, each line's picture is preceded by a preamble of 8 clocks (CTL0 = 1, the other CTL bits 0) and then a guard band of 2 clocks (the fixed words 1011001100, 0100110011, 1011001100 on lanes 0, 1, 2). The core delays the picture 12 clocks so that it sees `de` rise in time. The picture itself, its syncs and `de` are not changed.

### 4.2 The place in the line

x counts pixels from the blank's first pixel (x = 0 in the clock after the picture's last pixel). The core takes a line's length from one picture line's end to the next, and uses it to keep counting through the lines with no picture. It sends no island until it has seen two picture lines end after a reset.

In every line's blank, with HDMI on:

| x | What is sent |
|---|--------------|
| 0–3 | Control words |
| 4–11 | The island's preamble: CTL0 = 1 and CTL2 = 1 |
| 12, 13 | Guard band: lanes 1 and 2 the word 0100110011; lane 0 TERC4 of {1, 1, vsync, hsync} |
| 14–45 | The first packet |
| 46–77 | The second packet |
| 78, 79 | Guard band, as at 12 |
| 80 on | Control words, then the picture's lead-in if a picture line follows |

So the blank must be at least 80 + 12 = 92 pixels: HDMI wants 12 control words or more between two data periods. The syncs go on through the island in lane 0's TERC4 bits 0 and 1.

### 4.3 A packet

32 clocks. Lane 0 carries {bit 3, a header bit, vsync, hsync}: bit 3 is 0 in the island's very first packet clock and 1 after. The header is 3 bytes and a check byte, a bit a clock, the low bit first. Lanes 1 and 2 carry four subpackets side by side, each 7 bytes and a check byte: subpacket i's even bits on lane 1's bit i, its odd bits on lane 2's bit i, low bits first. A check byte is the BCH remainder for x^8 + x^7 + x^6 + 1 over the bytes before it.

### 4.4 The packets sent

| Packet | Header (bytes 0, 1, 2) | Subpackets |
|--------|------------------------|------------|
| Null | 0, 0, 0 | All 0 |
| Audio Sample | 0x02; the samples present in bits 3–0; bits 7–4 mark a sample that begins a block of 192 | One a sample, from subpacket 0 up: bytes 0–2 the left sample in 24 bits (the 16 bits in the top), 3–5 the right, byte 6 the left then right {parity, channel status, user 0, valid 0} |
| Audio Clock Regeneration | 0x01, 0, 0 | All four the same: byte 0 0; bytes 1–3 CTS, 20 bits, high first; bytes 4–6 N = 6144 |
| AVI InfoFrame | 0x82, 0x02, 0x0D | Subpacket 0: the checksum, then 0x02 (RGB, underscanned), 0x18 (4:3, active picture as the picture), 0x08 (full range), `VIC`, 0, 0. The rest 0 |
| Audio InfoFrame | 0x84, 0x01, 0x0A | Subpacket 0: the checksum, then 0x01 (two channels; the rest as the stream says). The rest 0 |

- **Samples.** A sample crosses from `clk` and waits in a FIFO of 8. As a line's blank begins, up to four waiting samples are taken for that line's first packet; with none waiting the packet is a null packet. Samples go out in the order they came, each once. With the FIFO full a new sample is dropped (only with HDMI off, or with no islands yet).
- **Channel status** (IEC 60958, a bit a sample, a block of 192): consumer, linear PCM, copy allowed, 48 kHz, 16 bits; the left channel is number 1 and the right 2. Bits 2, 25 and 33 are 1 on both; bit 20 on the left, bit 21 on the right.
- **Parity** is even over the sample's 24 bits and its valid, user and channel status bits.
- **CTS** is the number of pixel clocks in 48 samples (N / 128), counted afresh for each 48. An Audio Clock Regeneration packet is due after each count, so about every millisecond; none is sent before the first count. If no sample comes for 4,096 pixel clocks the count starts afresh at the next sample, so a pause in the samples gives no false CTS.
- **The second packet** is, in this order of need: Audio Clock Regeneration if one is due; else the AVI InfoFrame if this frame's has not gone; else the Audio InfoFrame likewise; else a null packet. A frame starts at `vsync`'s rising edge.

### 4.5 The sample rate

The stream says 48 kHz, and the samples are sent as they come. The display's sample clock is 128 × the pixel clock × N / CTS, so with CTS measured it follows the machine's real rate: 48.008 kHz for a sample every 2,083 clocks of 100 MHz, 160 parts in a million from 48 kHz. A machine whose rate is far from 48 kHz would need another N and channel status, which this revision does not have.

### 4.6 Off: DVI

`on` is taken at each frame's start. A frame with it low is sent as DVI: every blank clock a control word with CTL0–3 at 0, no guard bands, no islands, the picture 12 clocks late as ever. Samples that come meanwhile fill the FIFO and the rest are dropped. After a reset the stream is DVI until the first frame start.

### 4.7 Reset

`rst` forgets the line's length, the waiting samples and what is due. The picture path is not reset.

## 5. How a machine uses it

- Through `hdmi_out` with `AUDIO` = 1 on an Artix-7, or with three `tmds_encoder`s with `HDMI` = 1 wired as section 2 says.
- The picture and syncs as for DVI. The blank must be 92 pixels or more a line (576p's is 144).
- `aud_l`, `aud_r` and `aud_v` from the machine's sound: `audio_engine`'s `out_l`, `out_r` and `out_v`, or the machine's own mix with a strobe.
- `on` from a register, 1 after reset, so that software can fall back to DVI for a display that will not take HDMI.
- The picture leaves 12 clocks later than without the core. Nothing else in a machine sees that.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/hdmi_packets` | The core and three encoders against a decoder of the 10-bit words, on a small picture with random pixels and random samples from another clock, 600 frames. The picture, `de` and the syncs come out as they went in (the syncs inside islands too). Every data period has its preamble of 8 and guard band of 2, with 12 control words or more between two. Every header and subpacket divides by the BCH polynomial (a long division, not the core's shift register). Every sample sent arrives once, in order, with its parity, channel status and block starts. N is 6144 and CTS what the two clocks give. The InfoFrames come once a frame, sum to zero and hold the values of 4.4. With `on` low the stream is control words and pixels only. Thirteen deliberate faults in the core and the encoder are each caught |
| A board and a display | Sound from a real HDMI display with the picture unchanged, on at least one machine, before this merges. Then other displays and retro-z80's capture device |
| `drivers.sh`, the machines | As for the other cores |

## 7. Open points

| # | Point |
|---|-------|
| H1 | Jon's decisions (12 November 2026): both machines, behind `hdmi_out`'s `AUDIO` parameter; stereo 16-bit; sent as 48 kHz with a measured CTS and no resampling; 4:3 and full-range RGB in the AVI InfoFrame; a new packet core with the encoder extended; the samples cross inside the core; a switch to DVI, HDMI on after reset; merged only when heard on a real display |
| H2 | Not yet tried on a display. A simulation shows the packets are well formed, not that a display accepts them |
| H3 | Size, Yosys for 7-series: 454 logic cells, 26 shift registers, 6 RAM32M and 602 flip-flops, and 16 more cells in each encoder. The KS2 may not have the room |
| H4 | One sample rate and one picture format are described. Other rates (N, the channel status) and a 16:9 picture would be parameters or inputs in a later revision |
| H5 | The channel status says copy allowed and gives no category. No display is known to mind |
