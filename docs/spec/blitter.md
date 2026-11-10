# Blitter (blitter)

Status: **draft**, revision 2 for review: a redesign. The first design (four channels on one datapath, ADD, LINE, EDGES, port jobs, a second port; [blitter_v1.md](blitter_v1.md), which is what `rtl/blitter.v` implements today) tried to do too much. It becomes three cores: this one for rectangles of pixels, [raster](raster.md) for lines and triangles, and [geom](geom.md) for 3D points. No RTL yet.

The blitter works on rectangles of pixels in memory: it copies, fills, combines and cuts out, one job at a time. Each destination pixel D is a logic function (the minterm) of three inputs: A, a 1-bit mask; B, the source; and C, the destination's old contents. It is the Amiga's blitter in outline. A job can name a next job, so a list of jobs runs with no CPU in between.

The core has no registers a CPU can reach. The machine's wrapper keeps the job registers and their layout, and drives the job as ports; the core reads job descriptors from memory and hands them to the wrapper to store.

## 1. Summary

| Item | Value |
|------|-------|
| Jobs | One at a time. A job may chain to a next descriptor |
| Operation | D = minterm(A, B, C), any of the 256, per bit |
| Pixel depths | 1, 2, 4 and 8 bits, source and destination alike |
| Positions | Any pixel position for source, mask and destination |
| A (the mask) | None (all ones), a 1-bit image (`MASKIMG`), or B compared with a key colour |
| B (the source) | Memory, or a constant word |
| Direction | Left to right, or right to left (`job_rtl`) for overlapping copies; rows in either order, by the sign of the strides |
| Clipping | None: software trims the rectangle |
| Memory | One word port, on the scheduler (`dmac.v`) |
| Byte order | Big- or little-endian memory (`LE`) |
| Registers | None: the wrapper's |

Gone from the first design: ADD, the four channels and their turns, pause, timer and copper starts, job priority, the second port, port (FIFO) jobs, LINE and EDGES (now `raster`), and the address range check.

## 2. Ports

All inputs are sampled on the rising edge of `clk`. "Strobe" means high for one clock.

### 2.1 Clock and control

`raster` and `geom` use the same control ports with the same meaning.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | |
| `rst` | in | 1 | Reset: idle, no request | Synchronous |
| `enable` | in | 1 | The core may run; 0 holds it between memory accesses (its job stays) | Level |
| `start_ld` | in | 1 | Start: load the descriptor at the descriptor address, then run it | Strobe; ignored while busy |
| `start_run` | in | 1 | Start with the job the wrapper already holds | Strobe; ignored while busy; `start_ld` wins |
| `stop` | in | 1 | Stop after the destination word in hand | Strobe; ignored while idle |
| `da_we` | in | 1 | The descriptor address becomes `da_d` | Strobe; ignored while busy |
| `da_d` | in | 24 | The new descriptor address (bytes; bit 0 ignored) | With `da_we` |
| `da_q` | out | 24 | The descriptor address: the job running or last run, when it came from a descriptor | Register |
| `busy` | out | 1 | A job or a chain is running | Register |
| `done` | out | 1 | A job with `job_irq` set has ended, or the core has stopped (the chain's end, `stop`, an error) | Strobe |
| `err` | out | 1 | The last job stopped on an error (4.6). Cleared by the next start | Register |

### 2.2 The job

The wrapper decodes its job registers onto these ports. It changes them only while the core is idle or in the clocks of `su_v`, and holds them otherwise.

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `su_v` | out | 1 | The core is about to use the job: 8 clocks running, at the start of each job |
| `su_i` | out | 3 | Which of the 8 clocks, 0 to 7 (for a wrapper that reads its job from a RAM, a long word a clock) |
| `job_minterm` | in | 8 | Bit a×4 + b×2 + c is D for those values of A, B and C |
| `job_mask` | in | 2 | A: 0 none (all ones), 1 the 1-bit image at `job_aaddr` (with `MASKIMG`), 2 B against `job_key` (A is 1 where B differs from the key), 3 an error |
| `job_bpp` | in | 2 | Log2 of the bits per pixel: 0 to 3 |
| `job_rtl` | in | 1 | Work each row right to left (4.4) |
| `job_bconst` | in | 1 | B is `job_value`, not memory |
| `job_irq` | in | 1 | Strobe `done` when this job ends |
| `job_value` | in | 16 | The constant B: one destination word of pixels, the leftmost in the top bits |
| `job_key` | in | 8 | The key colour, in its low `bpp` bits |
| `job_astride` | in | 16 | Signed bytes from one row's start to the next, for A (a 1-bit mask's rows are shorter than an 8-bit source's) |
| `job_bstride` | in | 16 | The same for B |
| `job_dstride` | in | 16 | The same for D |
| `job_width` | in | 16 | Pixels per row; 0 is an empty job |
| `job_height` | in | 16 | Rows; 0 is an empty job |
| `job_aaddr`, `job_baddr`, `job_daddr` | in | 24 each | The byte holding the first row's first pixel (with `job_rtl`, its last pixel: the first one worked on) |
| `job_abit` | in | 3 | That pixel's place in its byte for A, in bits from the left |
| `job_bbit`, `job_dbit` | in | 3 each | The same for B and D, in pixels from the left (0 to 8/bits per pixel − 1) |
| `job_next` | in | 24 | The next descriptor's address; 0 for none |
| `job_bad` | in | 1 | The wrapper rejects the job (a reserved field set, say) |

### 2.3 Descriptor load

A descriptor is 8 long words (32 bytes) of memory at an even address, in the wrapper's own format. The core reads them and hands each to the wrapper, which stores it as the job. `raster` and `geom` load their descriptors the same way.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `dl_v` | out | 1 | A long word of the descriptor is here | Strobe |
| `dl_i` | out | 3 | Which long word, 0 to 7 | With `dl_v` |
| `dl_w0` | out | 16 | Its first word (the lower address), as stored | With `dl_v` |
| `dl_w1` | out | 16 | Its second word, as stored | With `dl_v` |
| `dl_wait` | in | 1 | The wrapper has not stored the last long word yet | Level |

### 2.4 Memory port

One requester on the scheduler. `raster` and `geom` have the same port.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `mem_req` | out | 1 | An access is asked for | Held until `mem_ack` |
| `mem_we` | out | 1 | It is a write | With `mem_req` |
| `mem_addr` | out | AW | Word address | With `mem_req` |
| `mem_wdata` | out | 16 | Write data, in memory order | With `mem_req` |
| `mem_be` | out | 2 | Byte enables, in memory order; 11 for reads | With `mem_req` |
| `mem_ack` | in | 1 | The access is taken this clock | A request may follow in the next clock |
| `mem_rvalid` | in | 1 | A read's word is back | In order, at most one a clock, any delay |
| `mem_rdata` | in | 16 | The word, in memory order | With `mem_rvalid` |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `AW` | 21 | Word address width. A job's byte addresses are cut to AW + 1 bits: there is no range check, and an address past the memory wraps. The machine's memory map keeps jobs in bounds |
| `LE` | 0 | 1: memory is little-endian (the even byte in bits 7–0) |
| `MASKIMG` | 1 | 0: no 1-bit mask image; `job_mask` 1 is an error. For example 0 on a small FPGA |

## 4. Behaviour

### 4.1 Pixels in memory

A row is a run of pixels packed from the left: in each byte the leftmost pixel is in the top bits, and bytes follow in address order. `LE` only says which half of a 16-bit memory word holds the even byte. A is always 1 bit a pixel, packed the same way.

### 4.2 A job

| Step | What happens |
|------|--------------|
| Start | `start_run`, or `start_ld` after the descriptor load (16 word reads). `busy` sets, `err` clears |
| Set-up | 8 clocks of `su_v`, then the job ports are checked (4.6) |
| Each row | The row's destination words, one after another (4.3) |
| Row end | A's row address moves by `job_astride`, B's by `job_bstride`, D's by `job_dstride` |
| Job end | After the last row: `done` strobes if `job_irq`. If `job_next` is not 0 and no stop was asked, the descriptor address becomes `job_next` and that descriptor is loaded and run. Otherwise `busy` clears and `done` strobes |

A width or height of 0 is an empty job: it ends at once, chaining as any other.

### 4.3 A destination word

Each destination word of a row takes these memory accesses, in this order:

| Access | When |
|--------|------|
| Read B | B is memory, and the minterm depends on B or the mask is the key colour. One word for each 16 source bits used: sometimes two for the row's first word, none for a word the last read still covers |
| Read A | The mask is the image and the minterm depends on A: one word for every 16 pixels |
| Read C | The minterm depends on C, or the word is the row's first or last and a byte of it is only partly inside the row |
| Write D | Always, with byte enables off for bytes wholly outside the row |

So a fill with a constant is one access a word; a plain copy two; a cookie-cut with a key colour three. The core puts up one request at a time and the next no later than the clock after `mem_ack`; it does not wait for a read to come back before asking for the next. How fast a job runs is then the memory cycles the scheduler gives it.

The datapath for a word:

| Stage | What |
|-------|------|
| B | The source bits for this word, lined up to the destination by a barrel shifter over the last and the current source word; or `job_value` |
| A | The image's bits, one a pixel, widened to the pixel; or 1 where B's pixel differs from `job_key`; or all ones |
| Combine | The minterm of A, B and C, bit by bit |
| Edges | In the row's first and last words, pixels outside the row keep C |

"Depends on" is read from `job_minterm` alone: it depends on C when bits 7, 5, 3, 1 differ from bits 6, 4, 2, 0; on B when bits 7, 6, 3, 2 differ from 5, 4, 1, 0; on A when bits 7–4 differ from bits 3–0. With the mask "none", A is all ones and only bits 7–4 matter.

### 4.4 Direction

A copy whose source and destination overlap must not overwrite source pixels it has yet to read.

- **Rows.** The core always goes from the row the addresses name to the next by adding the strides. To work from the bottom row up, software gives the bottom row's addresses and negative strides.
- **Within a row.** With `job_rtl` the core works each row from its last pixel to its first: the addresses and bit positions name the row's last pixel, and words are taken in falling address order. Use it when the destination is to the right of the source in the same rows.

The result of a job is the same in either direction when source and destination don't overlap.

### 4.5 Stop and enable

`stop` takes effect after the destination word in hand is written: `busy` clears and `done` strobes; no chain is followed. The job is not resumable. `enable` low holds the core before its next memory request; reads on their way are still taken.

### 4.6 Errors

Checked after the set-up: `job_bad`; `job_mask` 3; `job_mask` 1 without `MASKIMG`. An error ends the job and the chain: `busy` clears, `err` sets, `done` strobes, and nothing is written. `da_q` still names the descriptor.

### 4.7 Reset

`rst` makes the core idle with no request, `err` clear and the descriptor address 0.

### 4.8 The exact result

This is the definition the test model follows. A bit position n means bit 7 − (n mod 8) of the byte at address n div 8, so positions run left to right through a row. All byte addresses are taken modulo 2^(AW + 1).

```
bits = 1 << job_bpp
for r = 0 .. job_height − 1:                              # rows in the order given
    pd = 8 × (job_daddr + r × job_dstride) + job_dbit × bits
    pb = 8 × (job_baddr + r × job_bstride) + job_bbit × bits
    pa = 8 × (job_aaddr + r × job_astride) + job_abit
    for i = 0 .. job_width − 1:                           # pixels in the order worked
        k = −i if job_rtl else i
        C = the pixel at bit position pd + k × bits       # bits wide
        B = the pixel of job_value over C's place (below)   if job_bconst
            the pixel at bit position pb + k × bits       otherwise
        A = 1                                             if job_mask = 0
            the bit at bit position pa + k                if job_mask = 1
            1 if B ≠ job_key's low bits, else 0           if job_mask = 2
        for each bit j of the pixel:
            D[j] = job_minterm[4 × A + 2 × B[j] + C[j]]
        the pixel at pd + k × bits becomes D
```

- **The constant.** `job_value` lies over every destination memory word (the two bytes at an even address, in address order): a pixel takes the bits of `job_value` at its own place in its word. So a pattern in `job_value` lines up with memory words, not with the rectangle's left edge, and a plain colour is the pixel value repeated to fill 16 bits (0x5555 for colour 1 at 2 bits, 0x0707 for colour 7 at 8).
- **What is written.** Only bytes that hold at least one pixel of the row are written. In such a byte, pixels outside the row keep their value, which is why the row's first and last words may need C read (4.3).
- **Overlap.** The result above is what the core gives whenever no memory word is written before it is read as A or B for a later pixel. Reads happen a word at a time, a destination word's reads before its write, and a B word is read only when its first bit is needed. So: a destination to the left of or above the source is safe as given; a destination to the right in the same rows needs `job_rtl`; one below needs the rows bottom-up (negative strides, 4.4). With an overlap worked the wrong way the result is not specified.
- **Nothing else changes.** No word outside the destination rows is written, and A and B are never written.

### 4.9 Worked examples

Minterms: bit a×4 + b×2 + c gives D. The three every program uses:

| Minterm | D | Use |
|---------|---|-----|
| 0xCC | B | Copy, or fill with a constant B |
| 0xCA | B where A is 1, else C | Cut out: copy through a mask |
| 0x66 | B xor C | Invert with a constant; draw and undraw |

A 320-pixel-wide, 8-bit bitmap at byte address 0x10000 (stride 320) in each case.

| Job | Ports |
|-----|-------|
| Fill the 32×16 rectangle at (40, 20) with colour 7 | `minterm` 0xCC, `mask` 0, `bpp` 3, `bconst` 1, `value` 0x0707, `width` 32, `height` 16, `daddr` 0x10000 + 20 × 320 + 40, `dbit` 0, `dstride` 320. One write a word: 16 words a row |
| Copy a 32×32 image at 0x20000 (stride 32) to (100, 50) | `minterm` 0xCC, `mask` 0, `bconst` 0, `baddr` 0x20000, `bstride` 32, `daddr` 0x10000 + 50 × 320 + 100, `dstride` 320, `width` 32, `height` 32. A read and a write a word |
| The same, with colour 0 transparent | As the copy, with `minterm` 0xCA, `mask` 2, `key` 0. A B read, a C read and a write a word |
| An 8×8 character from a 1-bit font at 0x30000 (one byte a row) in colour 15 at (8, 8) | `minterm` 0xCA, `mask` 1, `aaddr` 0x30000 + 8 × character, `abit` 0, `astride` 1, `bconst` 1, `value` 0x0F0F, `daddr` 0x10000 + 8 × 320 + 8, `dstride` 320, `width` 8, `height` 8 |
| Scroll the whole 320×200 picture down 8 rows | A copy with the rows bottom-up: `baddr` 0x10000 + 191 × 320, `daddr` 0x10000 + 199 × 320, `bstride` −320, `dstride` −320, `width` 320, `height` 192, `rtl` 0 |
| Scroll it right 4 pixels | A copy right to left: `rtl` 1, `baddr` 0x10000 + 315 (the last source pixel of row 0), `daddr` 0x10000 + 319, strides 320, `width` 316, `height` 200 |

At 4 bits a pixel, an object at an odd x has `dbit` 1: a 16-pixel-wide row then spans five bytes, the first and last half covered, so its first and last words are read as C and merged even for a plain copy.

### 4.10 Sequences

**A descriptor load** (`start_ld`, or a chain). The core reads the 16 words at the descriptor address in rising order, one request after another. As each pair comes back it strobes `dl_v` with `dl_i` 0 to 7 and the two words as read from memory (`dl_w0` the lower address). While `dl_wait` is high it holds the next strobe. After the eighth, the set-up starts.

**The set-up.** `su_v` is high for 8 clocks with `su_i` counting 0 to 7. A wrapper with its job in a RAM reads long word `su_i` each clock and latches its fields; a wrapper with the job in flip-flops ignores it. From the clock after, the job ports must be steady until the job ends.

**A two-word fill** (no reads), with the scheduler granting every other clock:

```
 clk       0    1    2    3    4    5    6
 su_v      ...1  0
 mem_req        1    1    1    1    0
 mem_we         1    1    1    1
 mem_addr       w0   w0   w1   w1
 mem_ack             1         1
 busy      1    1    1    1    1    0
 done                               1        (the job has job_irq, or the chain ends)
```

**A chain.** When a job ends with `job_next` not 0, `da_q` becomes `job_next` and the load, set-up and job follow at once, with `busy` high throughout. `done` strobes at each job's end that has `job_irq`, and once more when the chain ends.

**Strobes while busy.** `start_ld`, `start_run` and `da_we` are ignored. `stop` during a descriptor load or set-up ends the chain before the job starts.

## 5. How a machine uses it

- A wrapper with the job registers (a small RAM of 8 long words is cheapest), which decodes the job onto the ports in the clocks of `su_v`, stores descriptor long words on `dl_v`, and turns register writes into `start_ld`, `start_run`, `stop` and `da_we`.
- One requester on `dmac.v` for the memory port.
- `done` to an interrupt flag, if wanted; `busy` and `err` in a status register.
- Software clips rectangles to the bitmap, and keeps jobs inside the memory.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/blitter`, random | The core against a pixel-exact model, on random jobs: every depth, bit position, mask kind, minterm, direction and stride sign, constant and memory B, widths from 1 pixel, chains, a memory that answers after random waits. Every memory write (address, data, byte enables) and the final memory are compared, and that no word outside the destination rows is written |
| `test/blitter`, directed | Overlapping copies in all four directions; the three access counts of 4.3; stop mid-job; `enable` held low mid-job; each error; an empty job in a chain; both byte orders |
| `drivers.sh` | One driver a register, in each build |
| The machines | Each machine's Vivado build and screens, as the gate before a pull request goes up |

## 7. Open points

| # | Point |
|---|-------|
| B1 | Choices made in this draft that were not in the grilling, for review: rows backwards by negative strides instead of a core mode; no address range check; every destination word is written (the first design skipped words left unchanged); `job_value` is one 16-bit word; `stop` is not resumable |
| B2 | Size and speed are not targets (Jon: simple first, measure after). The first design is about 3,200 LUTs in retro-z80's KS2 build with LINE and EDGES |
| B3 | A FIFO mover for retro68k's SD card and serial jobs is decided later; the second port (palette and register loads) is dropped |
| B5 | Both machines reviewed revision 2 at 6793fd9 and agree. Their one change is in: A has its own stride (`job_astride`), since a 1-bit mask beside an 8-bit source would otherwise need its rows padded eightfold |
| B4 | `rtl/blitter.v` is still the first design. The new blitter and `raster` are built on one branch and land together, and the first design is deleted with them, so main never lacks lines (Jon, at retro-z80's request). `geom` follows |
