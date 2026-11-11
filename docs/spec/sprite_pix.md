# sprite_pix: one sprite's pixel side

Status: **locked**, revision 1 (11 November 2026; both machines build it in Vivado and their own sprite tests give no differences, PR #17): the read pointer leaves as its register (no `rp_g` output), and the span is a set/clear flag, so `hs` must not be after `xe` and must be 16 or more. Changes from here are a revision 2, by request from a machine.

`rtl/sprite_pix.v` draws one sprite in the pixel clock domain. It takes words from the front of the sprite's FIFO, which `sprite_fetch.v` fills from memory in the system clock domain, and gives a pixel each clock: opaque or not, and its colour index. A machine builds one per sprite.

## 1. Summary

| Item | Value |
|------|-------|
| Clock | The pixel clock |
| Line | 864 places, `t` = 0–863: from pixel 720 of the line before (in the horizontal blank) to pixel 719 of the sprite's own line. `t` = 144 is the picture's first pixel |
| Bits per pixel | 2, 4 or 8 |
| Scaling | XSTEP, 5.11 source pixels per screen pixel: screen pixel i shows source pixel floor(i × XSTEP / 2048) |
| Colour index | 8 bits: the 8-bit value, or PAL in bits 7–4 and the 2- or 4-bit value below |
| Transparent | Value 0, and every place before `t` = 144 |
| FIFO | Read side: an asynchronous read at `rp`, 6-bit pointers (5 address, 1 lap); the write pointer arrives Gray-coded, the read pointer leaves as it is |
| Underrun | A DMA sprite whose FIFO is empty when a word is needed shows nothing more until it is flushed |
| Pipeline | One stage: `opaque` and `idx` are registered |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk_pix` | in | 1 | Pixel clock | |
| `en` | in | 1 | Video on. 0 empties the unit's state and answers any flush | |
| `t` | in | 10 | The place on the sprite's line | Steps by one each clock |
| `act` | in | 1 | The sprite shows on this line | Steady for the line; taken at `t` = 12 |
| `hs` | in | 10 | First pixel, as `t` (0–864) | As `act` |
| `xe` | in | 10 | The pixel after the last shown, as `t` | As `act` |
| `lb` | in | 2 | log2 of bits per pixel: 1, 2 or 3 | As `act` |
| `xstep` | in | 16 | XSTEP, limited to `0x0080`–`0x8000` | As `act` |
| `pal` | in | 4 | Palette bits for 2- and 4-bit pixels | As `act` |
| `dma` | in | 1 | Fed by the DMA: an empty FIFO is an underrun | As `act` |
| `head` | in | 16 | The FIFO word at `rp` | Combinational from `rp` |
| `rp` | out | 6 | Read pointer; also wired to `sprite_fetch`'s `rp` as it is | Registered |
| `wp_g` | in | 6 | Write pointer, Gray-coded, from the system clock side | Synchronised here (2 flops) |
| `flush_t` | in | 1 | Toggles: the FIFO was emptied | Synchronised here (2 flops) |
| `flush_ack_t` | out | 1 | Toggles back once this end is emptied | |
| `opaque` | out | 1 | This pixel shows | Registered |
| `idx` | out | 8 | Its colour index | Registered; meaningful when `opaque` |
| `underrun_t` | out | 1 | Toggles on an underrun | |

## 3. Parameters

None.

## 4. Behaviour

- **Span.** The sprite draws while `act`, `hs` ≤ `t` < `xe`, and it was not flushed during this line. Outside the span `opaque` is 0. The span is kept as a flag, set as `t` comes to `hs` and cleared as it comes to `xe`, so `hs` must not be after `xe`, and `hs` must be 16 or more (`sprite_fetch`'s `p_hs` and `p_xe` keep the first; HSTART the second). With `hs` = `xe` the span is empty.
- **Pixels in a word.** The word's high bits are the first pixel: 8 pixels of 2 bits, 4 of 4 bits, 2 of 8 bits.
- **Stepping.** The unit keeps a pixel in the front word and an 11-bit fraction. Each clock in the span it adds `xstep`; the words passed go (`rp` moves on, by more than one when the sprite is shrunk).
- **End of span.** At the span's last pixel the word in use goes too, used up or not, and the place goes back to the start of a word. So each line takes exactly the words `sprite_fetch` fetched for it.
- **Empty FIFO.** If a word is needed and the FIFO is empty: a DMA sprite underruns (`underrun_t` toggles; nothing more is drawn until the next flush); a sprite fed by hand shows nothing until a word comes.
- **Flush.** When `flush_t` (synchronised) differs from `flush_ack_t`, the unit sets `rp` to 0, clears its place and its underrun, answers on `flush_ack_t`, and draws nothing more on this line. It draws again from `t` = 12 of the next line.
- **Video off.** While `en` is 0 the unit is held empty, and any flush is answered at once.
- **Opaque.** A pixel is opaque when its value is not 0 and `t` ≥ 144.

## 5. How a machine uses it

- Build one per sprite, all on the pixel clock, with `t` counting the sprite's line as above.
- Take each sprite's settings from `sprite_fetch` (`p_act`, `p_hs`, `p_xe`, `p_lb`, `p_xstep`, `p_pal`, `p_dma`) into pixel clock registers at `t` = 12, and hold them for the line. HSTART must therefore be 16 or more.
- Wire `rp`'s low 5 bits to the sprite's `fifo_ra`, `head` to its `fifo_rd`, and `rp`, `wp_g` and the flush toggles to `sprite_fetch`.
- Put the pixels through the machine's own priority and palette; gather collisions between `opaque` outputs over a line and hand them to `sprite_fetch` with a toggle.

## 6. Test plan

`test/sprites`' `tb_lock_pix` runs the core in lockstep with a frozen copy of its earlier self (`ref/sprite_pix_ref.v`, from before the span became a flag) for 3 million clocks: random legal settings a line (the earliest start, the line's end, empty and one-pixel spans), every bits-per-pixel value and step, a FIFO that fills by spells so underruns come up, flushes, video off. Every output is compared every clock. There is no model test of its own yet. The machines' video tests check it with whole frames against a model: every bits-per-pixel value, scaling up and down, sprites partly left of the screen, flushes while drawn, and underruns.

## 7. Open points

| # | Point |
|---|-------|
| P1 | A unit test in `test/sprite_pix`, with a FIFO model and a few lines checked pixel by pixel |
| P2 | The line length (864) and the first shown place (144) are fixed |
