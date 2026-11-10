# Blitter, first design (blitter, as `rtl/blitter.v` is today)

Status: **being replaced**. This describes `rtl/blitter.v` as it stands (four channels, ADD, LINE, EDGES, port jobs). The redesign splits it into three cores: [blitter.md](blitter.md), [raster.md](raster.md) and [geom.md](geom.md). This file goes when the new blitter's RTL lands.

`rtl/blitter.v` is the blitter: four DMA channels, their scheduler, and one Amiga-style blitter datapath they share. (It was `dmx_core` until November 2026.) It reads and writes memory a word at a time. A machine's wrapper keeps the registers: the job registers and their layout, the descriptor format, the control and status registers and the interrupt flags. The wrapper turns register writes into the core's channel strobes and decodes the running channel's job onto the core's job ports.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, round robin; one at a time on the datapath |
| Turn | A group of up to 16 destination words, 16 pixels of a line, or 8 bytes of a port job |
| A channel alone | Goes straight on to its next group or row: no save, pick or restore |
| Operations | BLIT (any of the 256 minterms of A, B and C), ADD (per pixel, wrapping or saturating, signed or not); optionally LINE (`LINE`) and EDGES (`EDGES`) |
| Pixel depths | 1, 2, 4 and 8 bits |
| A (the mask) | None (all ones), a 1 bpp image, or B against a key colour |
| B (the source) | Memory, with any bit offset, or a constant |
| Direction | Forwards or backwards (for overlapping copies) |
| Port job | Optional (`PORTJOB`): a FIFO to memory or memory to a FIFO, a byte at a time |
| Memory | One word port; an optional second port for addresses past `CHIP_WORDS` (`XPORT`) |
| Byte order | Big- or little-endian memory (`LE`) |
| Clock | One clock domain |
| Registers | None: the wrapper's |

## 2. Ports

All inputs are sampled on the rising edge of `clk`. "Strobe" means high for one clock.

### 2.1 Clock and channels

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | |
| `rst` | in | 1 | Reset: channels idle, no request | Synchronous |
| `enable` | in | 1 | The engine may run; 0 holds every channel | Level |
| `pause` | in | 4 | Channel n waits (its job stays) | Level |
| `start_ld` | in | 4 | Start channel n, loading the descriptor at its descriptor address | Strobe; ignored while busy |
| `start_run` | in | 4 | Start channel n with the job the wrapper already holds | Strobe; ignored while busy; `start_ld` wins |
| `stop` | in | 4 | Stop channel n at the end of its turn | Strobe; ignored while idle |
| `clr_done` | in | 4 | Clear `done[n]` | Strobe |
| `clr_err` | in | 4 | Clear `err[n]` | Strobe |
| `da_we` | in | 4 | Channel n's descriptor address becomes `da_d` | Strobe; ignored while busy |
| `da_d` | in | 24 | The new descriptor address (bytes) | With `da_we` |
| `busy` | out | 4 | Channel n has a job | Register |
| `done` | out | 4 | Channel n finished or stopped | Register |
| `err` | out | 4 | Channel n stopped on an error | Register |
| `da_q` | out | 96 | Descriptor addresses, channel n in bits 24n+23 to 24n | Register |
| `ea_q` | out | 96 | Error addresses, the same way | Register |
| `irq_set` | out | 4 | Channel n's interrupt is due | Strobe |
| `idle` | out | 1 | No channel busy | From `busy` |
| `cur` | out | 2 | The channel being worked on | Register |

### 2.2 The job

The wrapper decodes the running channel's job onto these ports. It changes them only in the clocks of `su_v`, and holds them after.

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `su_v` | out | 1 | The core is setting up channel `cur`'s job: 8 clocks running |
| `su_i` | out | 3 | Which of the 8 clocks, 0 to 7 (for a wrapper that reads its job a long word a clock) |
| `job_op` | in | 3 | 0 BLIT, 1 ADD, 2 LINE (with `LINE`), 3 EDGES (with `EDGES`); anything else is an error |
| `job_minterm` | in | 8 | Bit a×4 + b×2 + c is D for those bits of A, B and C |
| `job_sat` | in | 1 | ADD: saturate |
| `job_signed` | in | 1 | ADD: pixels are signed |
| `job_mask` | in | 2 | 0 none, 1 a 1 bpp image at `job_aaddr`, 2 B against the key colour (`job_value` bits 7-0), 3 an error |
| `job_bpp` | in | 2 | Log2 of bits per pixel |
| `job_desc` | in | 1 | Backwards: rows from the last, words from the end |
| `job_irq` | in | 1 | Interrupt at the end of the job |
| `job_bconst` | in | 1 | B is `job_value`, not memory |
| `job_ymaj`, `job_xneg`, `job_yneg` | in | 1 each | LINE: the octant |
| `job_value` | in | 32 | The constant B, the key colour; LINE's pattern and colour |
| `job_bstride` | in | 16 | Signed bytes from row to row, for A and B |
| `job_dstride` | in | 16 | Signed bytes from row to row, for D |
| `job_width` | in | 24 | Pixels per row; LINE: its length; EDGES: the number of edges |
| `job_height` | in | 16 | Rows; LINE: the shorter length |
| `job_aaddr` | in | 24 | A's first byte; LINE: x of the first pixel; EDGES: the points |
| `job_baddr` | in | 24 | B's first byte; LINE: y of the first pixel; EDGES: the edges |
| `job_daddr` | in | 24 | D's first byte |
| `job_abit`, `job_bbit`, `job_dbit` | in | 3 each | The first pixel's place in its byte (A in bits, B and D in pixels) |
| `job_next` | in | 24 | The next descriptor's address; 0 for none |
| `job_bport` | in | 1 | Port job: B from the FIFO (`job_baddr` is not used) |
| `job_dport` | in | 1 | Port job: D to the FIFO (`job_daddr` is not used) |
| `job_bad` | in | 1 | The wrapper rejects the job (a reserved field, say) |
| `clip_xmin` … `clip_ymax` | in | 16 each | LINE's and EDGES' clip rectangle, signed, inclusive |

### 2.3 Descriptor load

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `dl_xok` | in | 1 | The descriptor at `cur`'s address may be read through the other port | Level, looked at as the load starts |
| `dl_v` | out | 1 | A long word of the descriptor is here | Strobe |
| `dl_i` | out | 3 | Which long word, 0 to 7 | With `dl_v` |
| `dl_w0` | out | 16 | Its first word (the lower address), as stored | With `dl_v` |
| `dl_w1` | out | 16 | Its second word, as stored | With `dl_v` |
| `dl_wait` | in | 1 | The wrapper has not stored the last long word yet | Level |

### 2.4 Memory port

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `mem_req` | out | 1 | An access is asked for | Held until `mem_ack` |
| `mem_we` | out | 1 | It is a write | With `mem_req` |
| `mem_addr` | out | 21 | Word address | With `mem_req` |
| `mem_wdata` | out | 16 | Write data, in memory order | With `mem_req` |
| `mem_be` | out | 2 | Byte enables, in memory order; 11 for reads | With `mem_req` |
| `mem_ack` | in | 1 | The access is taken this clock | A request may follow in the same clock |
| `mem_rvalid` | in | 1 | A read's word is back | In order, at most one a clock, any delay |
| `mem_rdata` | in | 16 | The word, in memory order | With `mem_rvalid` |

### 2.5 Other port (XPORT)

The same handshake as the memory port, for word addresses at or past `CHIP_WORDS`.

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `acc_a` | out | 23 | The word address of the access the core wants next |
| `acc_we` | out | 1 | It is a write |
| `xp_ok` | in | 1 | The access at `acc_a` can go to the other port; if not, it is an error. Combinational from `acc_a` and `acc_we` |
| `xp_req`, `xp_we`, `xp_addr` (23), `xp_wdata`, `xp_be` | out | | As `mem_` |
| `xp_ack`, `xp_rvalid`, `xp_rdata` | in | | As `mem_` |

### 2.6 FIFO (PORTJOB)

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `p_rxv` | in | 1 | A byte is waiting in the FIFO towards memory |
| `p_rxd` | in | 8 | That byte |
| `p_rxpop` | out | 1 | Take it (strobe) |
| `p_txr` | in | 1 | The FIFO from memory has room |
| `p_txpush` | out | 1 | Push `p_txd` (strobe) |
| `p_txd` | out | 8 | The byte |

The wrapper picks which FIFO from the job (the port's number is its own field).

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `CHIP_WORDS` | `24'h200000` | Words of memory on the memory port, from address 0. For example 2 M words for 4 MB |
| `LE` | 0 | 1: memory is little-endian (the even byte in bits 7-0). For example 1 for an SRAM a Z80 or 6502 sees bytewise, 0 for a 68000's |
| `MASKIMG` | 1 | 0: no 1 bpp mask image; MASK 1 is an error. Saves about 400 LUTs; for example 0 on a small FPGA |
| `XPORT` | 0 | 1: the other port, for addresses past `CHIP_WORDS`. For example 1 where the engine can reach registers or a ROM |
| `PORTJOB` | 0 | 1: port jobs. For example 1 where a FIFO (SD card, USB serial) is fed by the engine |
| `LINE` | 0 | 1: LINE jobs (OP 2). 0: OP 2 is an error, and LINE's states and registers are left out (unless `EDGES` needs them). For example 1 on a machine whose software draws lines with the engine |
| `EDGES` | 0 | 1: EDGES jobs (OP 3), which step their lines with LINE's machinery (built for either). 0: OP 3 is an error, and EDGES' states and registers are left out |

With `XPORT` or `PORTJOB` at 0, that part's inputs are ignored and its requests and strobes stay 0 (its data outputs are not driven). With `LINE` and `EDGES` at 0, the clip inputs and the octant inputs are ignored.

## 4. Behaviour

### 4.1 Channels

A channel is idle or busy. `start_ld` or `start_run` makes an idle channel busy. A busy channel is runnable while `enable` is set and its `pause` bit is clear. The engine picks the next runnable channel after the last one it picked (round robin), and gives it a turn.

A job ends when its last row (or pixel, edge or byte) is written. Then:

| Case | What happens |
|------|-------------|
| An error | `busy` clears, `err` sets, `irq_set` for the channel; `ea_q` holds the address that failed (or the descriptor address for a bad job or descriptor) |
| End, `job_next` not 0, no stop asked | The descriptor address becomes `job_next`; the channel loads it next turn; `irq_set` if `job_irq` |
| End otherwise | `busy` clears, `done` sets; `irq_set` if `job_irq` |
| A stop asked, at the end of a turn | `busy` clears, `done` sets; no interrupt |

The strobes take effect after the engine's own changes in the same clock: a `clr_done` in the clock a job ends leaves `done` clear; a start or address write is looked at against `busy` as it was before the clock.

### 4.2 A turn

| Step | Clocks |
|------|--------|
| Pick (from idle) | 1 |
| Restore | 1 |
| Descriptor load (start_ld, or after a chain) | 16 word reads, then the set-up |
| Set-up (`su_v`) | 8 |
| Check, then the row start | 1 and 1 for the job, then 3 per row (LINE: 1) |
| A group | Reads (B, then A, then C), then the writes; see below |
| Save | 1 |

The set-up runs when a job starts and whenever a channel comes back after another one had a turn. The core uses the job ports from the clock after the last `su_v` clock until the next set-up. The job's progress (rows left, addresses, the shifter's carried word) is the core's, saved per channel.

A channel running alone (the only runnable one, no stop asked) goes straight from the end of a group to its next group or row, without the save, pick, restore and set-up.

### 4.3 A group

A group is up to 16 destination words of a row.

1. B: the source words needed, up to 17 (one ahead for the shift).
2. A: the mask image's words, when `job_mask` is 1.
3. C: the destination words needed: every one when the result depends on C, else only the row's first and last words when they cover part of a byte.
4. The writes, one a clock when the memory takes them. A word whose pixels are all left alone is not written.

When B is the only read, the writes start as soon as the last B read is asked for, and each waits only for its own source word. The group's counts are registered before anything decides on them (for timing), so the B phase always takes at least a clock: a group with nothing to read starts its writes from there, and a group with only C words to read goes on to them without waiting for a write still held from the last group. The last write of a group may still be waiting when the next group of the same channel starts.

The datapath per destination word:

| Stage | What |
|-------|------|
| B | `{last B word, this B word} << shift`, top 16 bits; or the constant |
| A | The mask image's bits, one per pixel, widened to the pixel; or B against the key colour; or all ones |
| Edge masks | The row's first and last words cover only their pixels |
| Combine | The minterm of A, B and C; or ADD of B to C per pixel |
| Write | The result where the masks are set, C elsewhere; byte enables from the masks |

Backwards jobs reverse each word's bits on the way in and out, so the same shifter serves.

### 4.4 Constant B and byte order

Inside the core a word holds its even byte in bits 15-8. With `LE` set, words are swapped as they come from memory and as they go back. A constant B at 8 bpp gives byte address a the value's byte a mod 4: bits 7-0 first when `LE`, bits 31-24 first when not. At 1, 2 and 4 bpp the constant is the value's low pixel, repeated.

Descriptor words (`dl_w0`, `dl_w1`) and EDGES' point coordinates are taken as stored: a 16-bit number in the memory's own order. An EDGES edge word holds point a's number in its even byte and b's in its odd byte.

### 4.5 LINE and EDGES

These are built only with their parameters set. Without them, a job with OP 2 or OP 3 ends at once with an error, as any bad op does.

LINE draws `job_width` pixels from `job_daddr`/`job_dbit`, stepping one pixel along the longer axis each time and one along the shorter when the error term is above 0 (Bresenham). x and y (`job_aaddr`, `job_baddr` bits 15-0) are counted only to clip. A pixel's A is bit 31 - (n mod 32) of `job_value`, its B the value's bits 7-0. Pixels outside the clip rectangle are left alone. A turn is 16 pixels.

EDGES reads `job_width` edge words from `job_baddr`, each naming two points in the table at `job_aaddr` (x then y, a word each), and draws each edge as a line from its first point. An edge with an end outside -16384 to 16383, or wholly beyond one side of the clip rectangle, is left out.

LINE and EDGES take no DESC or MASK. LINE's width is at most 32,768 and its height at most width - 1.

### 4.6 Port jobs

With `PORTJOB`, a job with `job_bport` or `job_dport` moves `job_width` bytes between a FIFO and memory, up to 8 a turn; a channel whose FIFO is not ready ends its turn. It must be a plain copy: BLIT, minterm `0xCC`, no mask, 8 bpp, one row, forwards, not both ports. Anything else is an error.

### 4.7 Errors

| Error | Address in `ea_q` |
|-------|------------------|
| An access past `CHIP_WORDS` that the other port does not take | The byte address of the access |
| A descriptor address not a multiple of 4, or not wholly reachable | The descriptor address |
| OP 4-7, OP 2 without `LINE`, OP 3 without `EDGES`, MASK 3, MASK 1 without `MASKIMG`, `job_bad`, a bad LINE, EDGES or port job | The descriptor address |

After an error the core waits for every read it asked for to come back, then ends the job.

### 4.8 Memory ports

One request is out at a time on each port; `mem_req` stays up, with the same fields, until `mem_ack`. The core may put up its next request in the clock of `mem_ack`. Reads come back in order, at most one a clock, with any delay. The core does not use one port until the other's reads are back and its request taken.

## 5. How a machine uses it

The wrapper provides:

- Registers for each channel's job, written by the CPU while the channel is idle, and by descriptor loads. While `su_v` is set it puts channel `cur`'s job on the job ports; `su_i` lets it read a RAM a long word a clock. The ports must not change between set-ups.
- A store for loaded descriptors: on `dl_v`, long word `dl_i` of channel `cur` is `dl_w0` and `dl_w1`; `dl_wait` stays up until it is written.
- The control register: start (load or run), stop, pause; clearing `done` and `err`; the descriptor address write, merging bytes against `da_q`.
- The interrupt flags: set from `irq_set`, cleared by the CPU; the enable mask.
- Any checks of its own fields, through `job_bad`.
- With `XPORT`, `xp_ok` and the port's targets (registers, ROM), returning reads in order; `dl_xok` where descriptors may sit there.
- With `PORTJOB`, the FIFO the job names.

Field layouts, register addresses and the descriptor format are the machine's.

## 6. Test plan

`test/blitter` (`make -C test blitter`) runs one testbench three times: with `LE` 0 and 1, the core built with every option (`LINE` and `EDGES` 1); and with `LINE` and `EDGES` 0, where the LINE and EDGES jobs are replaced by checks that OP 2 and OP 3 are errors and write nothing. The testbench acts as the wrapper, keeping each channel's job in arrays. Memory answers after random waits; reads come back in order 2-5 clocks later. Each result is checked byte by byte against a model of the pixels.

| Test | Checks |
|------|--------|
| Fill 8 bpp | Constant B, byte order of the value, edge words |
| Copies at 1, 2, 4 and 8 bpp | Bit offsets, the shifter, edge masks, strides |
| Minterms | XOR (`0x66`), B AND NOT C (`0x0C`), all ones (`0xFF`) |
| Backwards | An overlapping copy in place; 1 bpp with offsets |
| Key colour, mask image | Cookie cut (`0xCA`) by key and by a 1 bpp image |
| ADD | Saturating, 8 bpp |
| Four channels at once | Round robin, set-up again on each return |
| Other port | A copy from the other port to memory |
| LINE | A line with its end clipped |
| EDGES | One edge drawn from a point table, one left out (wholly left of the clip rectangle) |
| LINE and EDGES left out | OP 2 and OP 3 are errors at the descriptor address, nothing written |
| Port jobs | FIFO to memory, memory to FIFO |
| Descriptor chain | A load after a job; `dl_` strobes, the new address, two interrupts |
| Errors | An address past memory; a bad op |

The machines' system tests check their wrappers: register access, descriptors in their layout, timing and random jobs against a model.

## 7. Open points

| # | Point |
|---|-------|
| 1 | The other port's ordering rule (one port's reads back before the other's) is simple and slow for mixed jobs |
| 2 | A group is fixed at 16 words; a smaller one would save buffer space on a small FPGA |
| 3 | The test does not cover signed ADD, EDGES' range check, or a stop and pause mid-job; the machines' tests do |
| 4 | EDGES on its own still builds LINE's stepping, which it uses; only OP 2's check and set-up are then left out |
