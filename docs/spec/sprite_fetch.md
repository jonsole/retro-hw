# sprite_fetch: the sprites' memory side

Status: **draft**

`rtl/sprite_fetch.v` fetches the image words of up to eight sprites from memory, a line at a time, into a 32-word FIFO per sprite. The pixel units (`sprite_pix.v`, one per sprite) take the words from the other end of each FIFO in the pixel clock domain. The core also works out each sprite's line settings for the pixel side, the deadlines for the memory scheduler, and gathers the sprite collisions.

The core holds no registers of the machine. The machine keeps each sprite's settings and hands them in, a sprite a clock. Only the line start (the pointer into the image) lives in the core, because the core moves it on from line to line.

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 8 ports; `NS` (1–8) built |
| Clock | The system clock (100 MHz). The FIFOs' read side is in the pixel clock domain |
| FIFO | 32 words of 16 bits per sprite, distributed RAM; the write pointers cross Gray-coded, the read pointers as registered binary taken when two samples agree |
| Bits per pixel | 2, 4 or 8 |
| Scaling | XSTEP and YSTEP, 5.11 fixed point source pixels per screen pixel, limited to `0x0080`–`0x8000` (0 is taken as 1:1) |
| Window | HSTART, HSTOP in beam pixels (0–864); VSTART, VSTOP in beam lines (0–625) |
| Memory | One word at a time on a request / acknowledge / read-valid channel, with a deadline and an urgent flag; up to 4 reads on their way |
| Pointer | `PW` bits; the memory address is bits 21–1 |
| Collisions | 32 bits gathered from the pixel side a line at a time; cleared bit by bit |
| Feeding by hand | With `MANUAL`: words written into a sprite's FIFO while its DMA is off |

## 2. Ports

All ports are in the system clock domain unless the table says otherwise. A strobe is high for one clock.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock | |
| `rst` | in | 1 | Reset, synchronous | Held for at least a clock |
| `set_sel` | out | 3 | The sprite whose settings the core takes in this clock. The core registers them and works on them in the next clock, so `set_sel` runs one sprite ahead of its calculator | Counts 0–7, one a clock, from reset |
| `set_hstart`, `set_hstop` | in | 11 | Sprite `set_sel`'s window across, beam pixels | Same clock as `set_sel` (combinational read) |
| `set_vstart`, `set_vstop` | in | 11 | ... down, beam lines (VSTOP is the first line not shown) | Same clock |
| `set_bpp` | in | 2 | 0: 2 bits, 1: 4 bits, 2: 8 bits a pixel. 3 is not allowed | Same clock |
| `set_depth` | in | 2 | Passed through to `p_depth` | Same clock |
| `set_pal` | in | 4 | Passed through to `p_pal` | Same clock |
| `set_xstep`, `set_ystep` | in | 16 | The steps as the machine holds them (limited inside) | Same clock |
| `dma_on` | in | 1 | The sprites' DMA as a whole | Any time |
| `dma_mask` | in | 8 | Each sprite's DMA | Any time |
| `start` | in | 8 | Strobe: these sprites start (FIFO emptied, fetching from the next line in the window) | 1 clock |
| `sel` | in | 3 | The sprite that `lst_cur`, `lst_wr`, `fifo_count` and `dat_wr` refer to | |
| `lst_cur` | out | `PW` | Sprite `sel`'s line start: the start of the line being drawn, or the value last written | Combinational from `sel` |
| `lst_wr` | in | 1 | Strobe: sprite `sel`'s line start becomes `lst_new` | 1 clock |
| `lst_new` | in | `PW` | The new line start. Bit 0 is taken as 0 | With `lst_wr` |
| `fifo_count` | out | 6 | Words in sprite `sel`'s FIFO (0–32). Only meaningful with `MANUAL` | Combinational |
| `dat_wr` | in | 1 | Strobe: `dat` into sprite `sel`'s FIFO (only with `MANUAL`; see 4.7) | 1 clock |
| `dat` | in | 16 | The word, first pixels in the high half | With `dat_wr` |
| `vblank` | in | 1 | Strobe: the vertical blank starts; every sprite stops | 1 clock a frame |
| `beam_v`, `beam_h` | in | 11 | The beam, as seen in the system clock domain: line 0–624, pixel 0–863 (0 = the start of the horizontal blank) | Changes no faster than once every 3 clocks |
| `mem_req` | out | 1 | A word is wanted | Held until `mem_ack` |
| `mem_addr` | out | AW | Its word address (pointer bits AW–1) | Steady while `mem_req` |
| `mem_urgent` | out | 1 | The request must not wait: the sprite's deadline is under `URGENT` × 8 clocks. Registered: the compare for the request `mem_req` carries in this clock, with the deadline of the clock before (4.6) | With `mem_req` |
| `mem_ack` | in | 1 | Strobe: the request is taken | A new request may be made in the same clock |
| `mem_rvalid` | in | 1 | Strobe: the word of the oldest request still open is on `mem_rdata` | In request order; at most 4 open |
| `mem_rdata` | in | 16 | The word | With `mem_rvalid` |
| `p_hs`, `p_xe` | out | 8 × 10 | Each sprite's first pixel, and the pixel after its last shown one, beam pixels | Change only in beam pixels 840–847 |
| `p_act` | out | 8 | The sprite shows on this line | Set by the line-start pass, beam pixel 0 plus about 12 clocks |
| `p_lb` | out | 8 × 2 | log2 of bits per pixel (1–3) | As `p_hs` |
| `p_xstep` | out | 8 × 16 | XSTEP, limited | As `p_hs` |
| `p_depth`, `p_pal` | out | 8 × 2, 8 × 4 | Passed through | As `p_hs` |
| `p_dma` | out | 8 | The sprite is fed by the DMA (`dma_on` and its `dma_mask` bit, and built) | Combinational |
| `fifo_ra` | in | 8 × 5 | Pixel side: read addresses | Pixel clock |
| `fifo_rd` | out | 8 × 16 | The words there (asynchronous read) | |
| `wp_g` | out | 8 × 6 | Write pointers, Gray-coded, straight from registers | System clock; synchronise on the pixel side |
| `rp` | in | 8 × 6 | Read pointers, binary, straight from `sprite_pix`'s registers | Pixel clock; synchronised here (2 flops), and a value is used only when two successive samples agree, because a read pointer can move several words in one step. The pixel clock must be at most a third of the system clock, and the skew between a pointer's bits on their way across well under one system clock (true of any sane placement; a machine may bound it with a max delay) |
| `flush_t` | out | 8 | Toggles: the sprite's FIFO was emptied | |
| `flush_ack_t` | in | 8 | Toggles back: the pixel side has emptied its end | Pixel clock; synchronised here |
| `coll_line` | in | 32 | Collisions found on a line | Steady from before `coll_t` toggles until the next toggle |
| `coll_t` | in | 1 | Toggles: `coll_line` is ready | Pixel clock; synchronised here (3 flops) |
| `coll_clr` | in | 32 | Strobe: clear these bits of `coll` | 1 clock |
| `coll` | out | 32 | Collisions gathered since cleared | Registered |

## 3. Parameters

| Name | Default | Meaning | For example |
|------|---------|---------|-------------|
| `NS` | 8 | Sprites built (1–8). The others have no FIFO, never start, fetch or show | A small FPGA may build 4 |
| `PW` | 23 | Bits of the line start and pointer (22 or more). Only bits 21–1 reach memory; the rest is read back | One machine uses 22, another 23 |
| `AW` | 21 | Width of `mem_addr`: a word address, pointer bits AW–1. 21 with `sram_ctl.v` | 21 |
| `LITTLE` | 0 | 1: a memory word's low byte goes to the FIFO word's high half. Set it where memory is little-endian, so that the byte at the even address holds the first pixels | 1 on a machine with an 8-bit CPU and little-endian SRAM |
| `URGENT` | 5 | A fetch is urgent when its deadline is under this many units of 8 clocks. Set it from the scheduler's worst-case wait for the sprites (scheduler spec 4.6); the registered `mem_urgent` is at most a clock later than the compare, well inside a unit | 5 (retro68k), 6 (retro-z80) |
| `MANUAL` | 1 | 1: feeding by hand (`dat_wr`) and `fifo_count`. 0: `dat_wr` is ignored | 0 on a machine without feeding by hand |

## 4. Behaviour

### 4.1 Settings

- `set_sel` counts 0, 1, … 7, 0, … one a clock, from power-on. The machine puts sprite `set_sel`'s settings on the `set_` inputs in the same clock, read straight from its registers (a distributed RAM read is fine: it has the whole clock, as the core registers the inputs). The core works on sprite n's settings in the clock after it took them, which is why `set_sel` is one ahead. A write to a sprite's settings that lands in the very clock they are handed over is seen at the sprite's next visit: 8 clocks later, or on the next line if that visit was the one in the update window (4.2). The machine may use `set_sel` to clear its registers during reset, one a clock.
- A size calculator takes them in three stages. It writes its results only while `beam_h` is 840–847. Each sprite is visited at least once in that window, so the next line uses settings from that window, and the fetcher and the pixel side always agree.
- Clamps: HSTART and HSTOP to 864; HSTOP below HSTART to HSTART; VSTOP to 625. Steps: 0 is `0x0800`; under `0x0080` is `0x0080`; over `0x8000` is `0x8000`.
- Words per image line, `wf` = ceil(ceil((HSTOP − HSTART) × XSTEP / 2048) × bits / 16), using the window as written. Words per shown line, `wv`, the same over the clamped window, never more than `wf`. Both at most 4095.

### 4.2 Starting and stopping

- A `start` bit starts that sprite; `vblank` stops every built sprite. Both empty its FIFO: the write pointer goes to 0, `flush_t` toggles, and the sprite fetches nothing until `flush_ack_t` matches `flush_t` again. Reads still on their way for it are dropped (each read carries the sprite's epoch, which a start flips).
- A start and `vblank` in the same clock: the sprite stays stopped.
- A started sprite runs until the next `vblank`.

### 4.3 The line-start pass

- At beam pixel 0 of each line except line 0, a pass visits the sprites, one a clock, in three stages (about 11 clocks in all).
- A running sprite shows on the line if VSTART ≤ `beam_v` < VSTOP and `wv` is not 0. Then `p_act` is set for it, and its words are fetched from the line start.
- Its line start moves on by k × `wf` words first, where k is the whole source lines YSTEP moves on (its fraction is kept). k is 0 on the sprite's first shown line after a start or a line-start write: that line starts exactly at the value written.
- A `lst_wr` holds the pass still for that clock (they share the line-start RAM). No word is asked for while the pass runs.

### 4.4 Fetching

- A sprite wants a word when its DMA is on, it is not being flushed, the line's words are not all asked for, and its FIFO holds fewer than 30 words with those on their way. (30, not 32: the pick is a clock ahead.)
- Of the sprites that want a word, the one with the nearest deadline asks next; the lower number wins a tie. The want flags and the pick are both registered, so a request goes out three clocks after a sprite comes to want a word.
- One request is open at a time: `mem_req` stays up until `mem_ack`. In the clock of `mem_ack` the next request may already be made.
- Words come back in order on `mem_rvalid`, up to 4 on their way. Each goes into its sprite's FIFO, its bytes swapped if `LITTLE`.

### 4.5 Deadlines

- A calculator visits a sprite a clock (`set_sel`). From the beam it works out the pixels until the sprite's span (0 if the beam is in it; to the next line's span if past it), adds the pixels its words in hand will last, and turns that into units of 8 clocks at 3.5 clocks a pixel, less 2 units. 292 pixels or more is the largest deadline, 127 units.
- `mem_urgent` is a register: in each clock that `mem_req` is high, it says whether the deadline of the sprite that request is for was under `URGENT` in the clock before (for a request put up in this clock, the deadline the sprite had as it was picked). The deadline changes only when the calculator visits the sprite, every 8 clocks, so this is at most one clock later than a combinational compare. There is no deadline output: the scheduler (`dmac.v`) orders requesters by number, not by deadline.

### 4.6 Collisions

- `coll_t` is synchronised with 3 flops. On a change, `coll_line` is ORed into `coll`.
- `coll_clr` clears its bits in the same clock. A clear and a new line in the same clock: both take effect (bits in both are set).

### 4.7 Feeding by hand (`MANUAL`)

- With `MANUAL` 1, a `dat_wr` takes `dat` and `sel`, and the word is written at the back of that sprite's FIFO on the first later clock in which no word comes back from memory (`mem_rvalid` 0): usually the next clock. It is written if the sprite is built, its DMA is off (`p_dma` 0), it is not being flushed, and the FIFO holds fewer than 32 words at that clock. Otherwise the word is dropped.
- **Limitation: one word waits at a time.** A `dat_wr` while an earlier word still waits replaces it, and the earlier word is lost with no sign. A word waits only while memory words come back, so one writer whose writes are several clocks apart (a CPU) is safe. Two writers that can strobe `dat_wr` in successive clocks (a CPU and a copper, say) must not both feed sprites by hand at the same time: the core has no busy signal to hold the second.
- `fifo_count` is the words in sprite `sel`'s FIFO, from a read pointer a few clocks old.

### 4.8 Reset

- `rst` clears the fetch state, the FIFOs' pointers, `coll`, `flush_t`, and sets every deadline to the largest. The line-start RAM is not cleared (it starts at 0 at power-on).

## 5. How a machine uses it

A wrapper must provide:

- The registers for each sprite's window, steps, bits per pixel, depth and palette, readable at `set_sel` in the same clock. A distributed RAM with one write a clock is enough, read combinationally: the core registers what it reads. If the machine has a fourth bits-per-pixel value, it maps it before `set_bpp`.
- The line start's register: reads come from `lst_cur` with `sel` set to the sprite; a write of part of it merges into `lst_cur` and is written whole with `lst_wr`.
- A start strobe when the program starts a sprite (for example on a write of its control register).
- The per-sprite DMA enables (`dma_mask`) and the master enable (`dma_on`).
- The collision register: reads from `coll`; clearing writes as `coll_clr` masks.
- With `MANUAL`: the data register's writes as `dat_wr`, and `fifo_count` for its count register.
- The `vblank` strobe and the beam, in the system clock domain.
- A sprite channel on the memory scheduler: request, acknowledge, read valid in order, the deadline and the urgent flag.
- One `sprite_pix` per built sprite in the pixel clock domain, wired to `fifo_ra`, `fifo_rd`, `wp_g`, `rp`, `flush_t`, `flush_ack_t`, and given the `p_` settings, which it must take at beam pixel 12 (after the line-start pass). A sprite not built needs `flush_ack_t` tied to its `flush_t`.

## 6. Test plan

`test/sprites` (Icarus Verilog) has two tests. `tb_sprite_fetch` runs two cores side by side on one memory model, one with `LITTLE` 0 and `MANUAL` 1, one with `LITTLE` 1 and `MANUAL` 0. The beam moves a pixel every 4 clocks; the FIFOs are never read. It checks:

`tb_lock_sprite` runs the core in lockstep with a frozen copy of its earlier self (`ref/sprite_fetch_ref.v`, from before the scheduler side changed: a `mem_deadline` output and a combinational `mem_urgent`), in retro68k's build (8 sprites, PW 23, `URGENT` 5, `MANUAL`) and retro-z80's (4 sprites, PW 22, `LITTLE`, `URGENT` 6), for 1.2 million clocks each: random settings handed over by `set_sel`, starts, line-start writes, hand-fed words, a 3.7-clock beam, a pixel side that consumes words and acknowledges flushes, and a memory that is busy or quiet by spells. Every clock, every output must be equal; `mem_urgent` is checked against the reference's compare with the deadline of the clock before, and `set_sel` against the reference's plus one. The bench never writes a sprite's settings in the clock they are handed over, the one case where the core would see the write a visit later than the reference did.

| Check | What |
|-------|------|
| Line start | `lst_wr` and `lst_cur`; bit 0 written as 1 reads 0 |
| Window | No words fetched before VSTART; `p_act` on lines 2 and 3 only; `p_hs` |
| Words per line | 4 words at 4 bits and 1:1, 8 words at 8 bits and XSTEP ½ |
| YSTEP | 1:1 moves the line start on by `wf`; ½ shows a line twice |
| FIFO contents | Every word, in order, at its address; swapped in the second core |
| Both cores ask alike | The same requests, clock by clock |
| Feeding by hand | Three words into a sprite with its DMA off, `fifo_count`; dropped for a sprite with its DMA on, and without `MANUAL` |
| Start | Empties the FIFO |
| Collisions | Gathered; cleared and added in the same clock |

The machines' system tests check the rest: the sprite screens of their video tests compare whole frames, pixel by pixel, against a model, with sprites scaled, overlapping, started again and changed while drawn.

## 7. Open points

| # | Point |
|---|-------|
| S1 | The deadline assumes 3.5 system clocks a pixel (576p at 100 MHz is 3.7). A machine with another pixel clock needs a parameter for it |
| S2 | The beam timing (864 pixels, 625 lines, settings at pixels 840–847, the pass at pixel 0) is fixed. A machine with another video mode needs parameters |
| S3 | `fifo_count` reads a pointer a few clocks old: a count read just after the pixel side takes a word may be one high |
