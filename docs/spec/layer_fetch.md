# Layer fetch (layer_fetch)

Status: **draft**, revision 2: a group's depth, planar flag and scale are taken at the group's start and travel with it to `layer_pix` (`gset`). Agreed by both machines (retro68k #34, retro-z80 design plan branch 26) and implemented (`rtl/layer_fetch.v`, PR #9); retro-z80 runs revision 1. To be locked together with `layer_pix` once both machines have adopted it.

The layer fetch reads each layer's words from memory, one 16-pixel group at a time, into the layer's data registers, where `layer_pix.v` takes them. It is one requester on the memory scheduler (`dmac.v`) for all its layers, and picks which layer asks next by earliest deadline. It counts each layer's pointer on as it reads, and moves it to the next line's start at the end of a line.

It is retro68k's and retro-z80's `bpldma.v` made one core, with no registers a CPU can reach: the machine keeps its own register file and bus, and drives the core's settings as ports. Planar layers, tile layers and data-register writes are build options.

## 1. Summary

| Item | Value |
|------|-------|
| File | `rtl/layer_fetch.v`, module `layer_fetch` |
| Clock | One: the system clock (100 MHz in both machines). `line_t` comes from the pixel clock and is synchronised inside |
| Layers | `NL` (parameter), 1 or more |
| Group | 16 source pixels, 1 to 8 words, into 8 data registers per layer (`layer_pix` spec 4.1) |
| Kinds | Chunky (1, 2, 4, 8 bits a pixel); planar, 1–8 planes (`PLANAR`); tile maps of chunky patterns (`TILES`) |
| Pointers | Inside the core: one per plane (planar) or one per layer, counting on as words are read. The machine loads and reads them through one addressed port |
| Memory | One requester on the scheduler: `req`, `urgent`, `addr`, `ack`, read data with `rvalid` |
| Layer choice | Earliest deadline first; on a tie, round robin after the last layer served |
| Urgent | Registered. Set when the asking layer's deadline is under a mark set by parameters |
| To `layer_pix` | The data registers (`dat`), the tile attributes (`attr`), the group's own depth, planar flag and scale (`gset`, 6 bits), and a fill toggle per layer (`fill_t`, answered by `take_t`) |
| Registers | No bus registers. Inside: pointers, line state, data registers |

## 2. Ports

Layer n's signals are bit n, or field n, of each per-layer port (bits n×W to n×W+W−1 of a W-bit field). A port marked with an option exists only to be used with that option; with the option off it is ignored and costs nothing.

Settings are read at one of three times:

- **Copied at `line_go`:** the value at the line's start holds for the whole line, so a change mid-line (a CPU or copper write) applies from the next line.
- **Taken at a group's start:** the value in the clock before a layer's group starts (4.8, stage A) is the group's, for its words and in `gset` for the pixel side. A change applies from the layer's next group, never inside one. This is deliberate: a copper or CPU write can change a layer's depth or scale mid-line for an effect, and the fetch and `layer_pix` always agree about a group.
- **Read live:** a change applies the next time the core uses the setting, mid-line included.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock | – |
| `rst` | in | 1 | Reset: no request, counts and toggles cleared, data registers 0, deadlines none. Pointers and saved starts are not reset (4.9) | Synchronous |
| `enable` | in | 1 | The fetch may run (video on, and the machine's DMA enables). A line starts with no groups to fetch while it is low | Copied at `line_go`; with `DATWRITE`, also read live (4.6) |
| `line_t` | in | 1 | Toggles at the start of each horizontal blank, in the pixel clock | Any |
| `line_go` | out | 1 | One clock: a new line has started here (`line_t` seen to toggle, through a two-flip-flop synchroniser) | – |
| `line_gen` | out | 1 | Toggles with `line_go` | – |
| `act` | in | NL | The layer shows on the line about to be fetched | Copied at `line_go` |
| `adv` | in | NL | Its pointers move on to the next source line after this line (else back to this line's start: a repeated line of a vertically scaled layer) | Copied at `line_go` |
| `depth` | in | 3×NL | Words per group − 1: planes − 1 for a planar layer; for a chunky layer, bits a pixel − 1 as a word count (0, 1, 3 or 7) | Taken at a group's start, through a one-clock register (the same one as `dma_en`). The urgent count of a map entry's request (the rows still to come in its group) uses the group's depth too. A tile layer's rows are stored with the depth its pattern group took |
| `planar` | in | NL | `PLANAR`: the layer is planar, one pointer per plane | Taken at a group's start, as `depth` |
| `hscale` | in | 2×NL | log2 of the horizontal scale. Sets how long a group lasts (4.4) | Taken at a group's start, as `depth`; the deadline uses the taken group's. A map entry's deadline, a group further on, uses the live value: the next group hasn't started, so it has no taken value yet |
| `wrap` | in | 4×NL | 0: no wrap. n: the layer's pointers wrap within an aligned block of 2^(n+9) bytes | Read live, on every pointer move |
| `stride` | in | 16×NL | Signed byte stride from one source line's start to the next. Bit 0 is ignored | Read live, when each pointer's last word of the line is set up (4.8): a change mid-line applies at that line's end |
| `ngroups` | in | 12×NL | Groups to fetch on the line (whole groups covering the window and fine scroll) | Copied at `line_go` |
| `tile` | in | NL | `TILES`: the layer is a tile map | Copied at `line_go` |
| `mapw` | in | 2×NL | `TILES`: map width, 0: 32, 1: 64, 2 or 3: 128 entries | Copied at `line_go` |
| `ty` | in | 10×NL | `TILES`: the line's map row (bits 9–3) and the row within a tile (bits 2–0) | Copied at `line_go` |
| `tcol` | in | 7×NL | `TILES`: the map column of the line's first group's tile column 0 | Copied at `line_go` |
| `mappt` | in | PW×NL | `TILES`: byte address of the map's first entry | Copied at `line_go` |
| `patpt` | in | PW×NL | `TILES`: byte address of tile 0's first byte | Copied at `line_go` |
| `ptr_sel` | in | LW+3 | The pointer for `ptr_wr` and `ptr_rdata`: {layer, plane}. With `PLANAR` it reaches all 8 pointers of every layer, a chunky layer's too (the fetch itself uses plane 0 of a chunky or tile layer). Without `PLANAR`, plane is ignored | Any |
| `ptr_wr` | in | 1 | Write `ptr_wdata` to that pointer and to its saved line start (4.3). Restarts a fetch being set up, for any layer | One clock a write |
| `ptr_wdata` | in | PW | Byte address; bit 0 is stored as 0 | With `ptr_wr` |
| `ptr_rdata` | out | PW | That pointer's live value | Combinational from `ptr_sel`; a machine whose bus reads a clock later registers it |
| `dat_wr` | in | 1 | `DATWRITE`: write a data register | One clock a write |
| `dat_sel` | in | LW+3 | `DATWRITE`: {layer, data register} | With `dat_wr` |
| `dat_wdata`, `dat_be` | in | 16, 2 | `DATWRITE`: the data, and its byte enables (bit 1 the upper byte) | With `dat_wr` |
| `dma_en` | in | 8×NL | `DATWRITE`: bit p: the fetch fills data register p of the layer. Chunky: bit 0 for the whole layer. Without `DATWRITE` every register is filled | Read live: a group uses the enables registered the clock before it starts (4.6) |
| `dat_rdata` | out | 16 | `DATWRITE`: the data register `dat_sel` names | Combinational from `dat_sel` |
| `dat` | out | 128×NL | The data registers to `layer_pix`: layer n register r in bits 128n + 16r to 128n + 16r + 15 | Stable while the layer is full |
| `attr` | out | 10×NL | `TILES`: the group's {PRI, PAL} for tile column 1 (bits 9–5) and column 0 (bits 4–0) | With `dat` |
| `gset` | out | 6×NL | The group's settings for `layer_pix`, as taken at its start: bit 0 `planar`, bits 3–1 `depth`, bits 5–4 `hscale` (`layer_pix` spec, section 2) | With `dat` |
| `fill_t` | out | NL | Toggles when the layer's next group is complete in its data registers | – |
| `take_t` | in | NL | From `layer_pix`: toggles when the layer's group is taken. Synchronised inside | Any |
| `req` | out | 1 | Read one word. Held until `ack` | – |
| `urgent` | out | 1 | The request must not wait (4.4). Registered | With `req` |
| `addr` | out | AW | Word address of the read | With `req` |
| `ack` | in | 1 | The scheduler gave the read a cycle | One clock |
| `rvalid`, `rdata` | in | 1, 16 | Read data for this requester, in the order the reads were given | One clock |

## 3. Parameters

| Name | Default | Meaning | retro68k | retro-z80 |
|------|---------|---------|----------|-----------|
| `NL` | 3 | Layers, 1 or more | 3 | 3 |
| `AW` | 21 | Word address width (`addr`) | 21 | 21 |
| `PW` | 22 | Pointer width in bits, byte address (`ptr_*`, `mappt`, `patpt`). At least AW + 1; bits above AW + 1 count, but don't reach `addr` | 23 | 22 |
| `PLANAR` | 1 | Planar layers: a pointer per plane, `planar` used | 1 | 0 |
| `TILES` | 0 | Tile layers: `tile`, `mapw`, `ty`, `tcol`, `mappt`, `patpt` used, `attr` driven | 0 | 1 |
| `DATWRITE` | 0 | Data-register writes and per-register fetch enables: `dat_*`, `dma_en` used | 1 | 0 |
| `LITTLE` | 0 | Memory byte order. 1: the even byte of a word is its low byte, and holds the pixels further left, so the fetch swaps a word's bytes into the data register | 0 | 1 |
| `URG_BASE` | 15 | Urgent mark: clocks, before any words still to come (4.4) | 15 | 17 |
| `URG_WORD` | 5 | Urgent mark: clocks per word still to come | 5 | 5 |
| `LW` | clog2(NL), at least 1 | Width of the layer part of `ptr_sel` and `dat_sel`. Leave it to the default | | |

`PLANAR` and `TILES` both on is not supported: tile patterns are chunky (`layer_pix` open point L1). The two `URG_*` values in the table are the machines' old marks plus 1, for the registered `urgent` (4.4); each machine must check its own (section 5).

## 4. Behaviour

### 4.1 A line

| When | What happens |
|------|--------------|
| `line_t` toggles | It passes a two-flip-flop synchroniser, then `line_go` is high for one clock. (Both machines' `bpldma.v` used one flip-flop; the core's `line_go` is one clock later than theirs, which is harmless in the blank) |
| `line_go` | The line starts. For each layer: if `enable` and `act` and `ngroups` > 0, it has `ngroups` groups to fetch (a tile layer one more, 4.5), else none. Any request not yet given is dropped, reads on their way are ignored when they come back (4.7), and the fill toggle is set equal to the take toggle seen, so a spare group from the last line is dropped. Deadlines go to none. The line settings are taken |
| Then | The layers ask for their groups, words in turn (4.2, 4.4). A layer starts a group when it has groups left, its last group has all come back, and its data registers are not full (`layer_pix` hasn't taken the last group yet) |
| A group's last word comes back | `fill_t` toggles |
| `layer_pix` takes it (`take_t` toggles) | The layer may start its next group; its deadline is loaded (4.4) |

The first group of a line is fetched ahead of the window, in the blank.

### 4.2 Words of a group

A group's depth and planar flag are those in the clock before it starts (stage A of 4.8), through a one-clock register, and go out with it in `gset`. The words of a group go to data registers high to low. Chunky with 2^k words: registers 2^k − 1 down to 0, all from the layer's pointer. Planar with p planes: register j from plane j's pointer, planes p − 1 down to 0. With `DATWRITE`, only the registers whose `dma_en` bit is set are fetched; the others keep what was last written to them, and `layer_pix` takes that value with every group. A layer whose `dma_en` fills no register fetches nothing (4.6).

With `LITTLE`, a word's two bytes are swapped as it is stored in a data register. A tile layer's map entries are not swapped (4.5).

### 4.3 Pointers

Each pointer (one a plane with `PLANAR`, else one a layer) is a byte address, `PW` bits, bit 0 always 0. Each has a saved line start.

- Each word read from a pointer moves it on by 2.
- The first word a pointer gives on a line saves its value as the line's start.
- The last word it gives on the line sets it to the line's start + `stride` (if `adv`), or back to the line's start (if not).
- With `wrap` = n > 0, the bits from 9 + n up don't change on any of these moves: the pointer stays in its aligned block.
- A `ptr_wr` sets both the pointer and its saved start, and wins over the fetch's own move in that clock. A fetch being set up in that clock starts again (4.8), whichever layer it is for.

So how many words a line reads (whole groups, fine scroll) never matters to where the next line starts, as long as the line's last word is asked for before the next `line_go`. If it isn't (a starved fetch, or `dma_en` cleared mid-line), the pointer stays where it stopped, with no stride. A `ptr_wr` with any byte of the pointer counts as a write and sets the saved start too; a machine merging a partial write gives the whole merged value. A tile layer's pointer doesn't move (4.5).

### 4.4 Deadlines and the layer choice

Each layer has a deadline: system clocks until the group it took last is used up, so the next one must be in by then.

- At `line_go` every deadline is none (10'h3FF).
- When `layer_pix` takes a group (seen when the take toggle has passed its synchroniser, about 3 clocks after `take_t` toggles), the deadline loads 59 × 2^hs clocks, hs the `hscale` that group took at its start (the value in its `gset`), (a group of 16 source pixels at about 3.7 system clocks a screen pixel; a tile group is 16 source pixels too), except for the line's first take, the group loaded ahead of the window, which leaves it none.
- It counts down by 1 a clock, to 0, and stays there. None stays none.

**Which layer asks next:** of the layers with a group being fetched or ready to start one, the one with the smallest deadline; on a tie, the next after the last layer served, in round-robin order. The deadlines are compared a clock before they are used (for timing): a decision can be a clock late, never wrong in a way that matters.

**Urgent:** a request is urgent when its layer's deadline is under the mark:

  mark = `URG_BASE` + `URG_WORD` × (words of the layer's group not yet through stage B (4.8), plus 1)

A word waiting in the holding place has already passed B, so it isn't counted.

`urgent` is a register. In each clock that `req` is high, it is the comparison for that request, with the words left as of this clock and the deadline of the clock before. A deadline drops by at most 1 a clock, so `urgent` is at most one clock later than a combinational compare would be; `URG_BASE` is one higher than a combinational mark to allow for it. In its first clock, a new request's `urgent` is worked out for that request, not the one before; that includes a new request put up in the clock after an `ack`, when `req` stays high. It is 0 while `req` is 0.

### 4.5 Tile layers (`TILES`)

A tile layer's group is two tile columns of 8 source pixels. Its words are, high to low: the two columns' pattern rows (into the data registers, laid out as a chunky group of the same depth, column 0 in the higher registers), then the next group's two map entries (column 0 then column 1, into the layer's entry registers). So entries are read one group ahead:

- The line starts with a group of entries only, for its first group; so a tile layer has `ngroups` + 1 groups to fetch.
- Its last group reads no entries.
- A group is complete (`fill_t`) with its last pattern word; the next group can start once its entries are in.
- A tile group's rows are stored (and its entries' pattern addresses worked out) with the depth the group took at its start; a depth change applies from the next pattern group.
- At 1 bit a pixel a column's row is one byte, so a group makes two pattern reads, one a column. Each keeps the byte its address names (with `LITTLE`, an odd address is the word's high byte): column 0's in the high half of data register 0, column 1's in the low half.

Addresses, all byte addresses (the word read is the one holding the byte):

| Read | Address |
|------|---------|
| Map entry | `mappt` + 2 × (map row × map width + column). The column starts at `tcol` and counts on by 1 an entry (two entries a group, one a tile column), wrapping at the map width |
| Pattern row word j of a column | `patpt` + tile × 2^(3+lb) + row × 2^lb + 2j. lb is log2 of the bits a pixel (0–3), which is also log2 of the bytes in one 8-pixel row; tile is the entry's bits 8–0; row is the row within the tile from `ty`, or 7 − it with YFLIP |

A map entry is the word's value as read, not byte-swapped: bits 8–0 tile, bits 12–9 PAL, bit 13 XFLIP, bit 14 YFLIP, bit 15 PRI. A group's `attr` is set from the two entries it uses, when it starts.

**XFLIP** reverses the row: the order of its words and the pixels in each. A column has k = max(1, 2^lb / 2) data registers, column 0's starting at register base k, column 1's at base 0. Word j of the row (j = 0 at the lowest address) goes to register base + k − 1 − j, or with XFLIP to base + j, and with XFLIP each word's pixels are reversed as it is stored (at 8 bits a pixel, its two bytes swap; at 1 bit a pixel, the 8 bits of the byte reverse). Map and pattern addresses don't wrap, and the tile layer's pointer doesn't move.

A map entry's request is due a group later than the layer's deadline (the next group's pattern rows need it), and its words still to come count the next group's pattern words.

### 4.6 Data-register writes (`DATWRITE`)

- `dat_wr` writes a data register, byte by byte (`dat_be`). Against a word arriving for the same register in that clock it wins byte by byte: a one-byte write keeps the arriving word's other byte.
- With no register of the layer fetched, judged live (`enable` low, or `dma_en` filling none of the layer's registers), a write of register 0's low byte makes the group complete: `fill_t` is set so that the layer is full. So software or a copper can drive a layer's pixels with no memory reads.
- A group uses the `dma_en` bits registered the clock before it starts, and keeps its own list of words to fetch. A change mid-group applies from the layer's next group; it doesn't restart a fetch.

### 4.7 Reads on their way

Up to four reads can be on their way. Each carries the layer, the register (or entry), whether it completes the group, and the line it belongs to. A read from the previous line coming back after `line_go` is dropped. Reads come back in the order they were given, which the scheduler guarantees for one requester.

### 4.8 How a fetch is set up

A fetch takes two clocks: A picks the layer and its register, and reads its pointer and saved start; B works out the address and the pointer's next value, writes it, moves the group counts on, and puts up the request (or holds it in a one-entry holding place while `req` waits for its `ack`, so the next request is ready when the scheduler takes this one). Memory cycles are two clocks apart, so this costs no bandwidth. A doesn't start in a clock with `line_go` or a `ptr_wr`. B waits while the holding place is full and `req` has not been taken, and a group start in B waits until the layer still has groups left. `line_go` or a `ptr_wr` in B sends it back to A, whichever layer it concerns.

### 4.9 Size

Yosys 0.33, `synth_xilinx` for 7-series, the core alone with the machine's build, beside the machine's own `bpldma.v`:

| Build | LUTs | Flip-flops | LUT RAM |
|-------|------|------------|---------|
| retro68k's (`PLANAR`, `DATWRITE`, PW 23) | 1850 | 915 | 13 |
| retro68k's `bpldma.v` | 1753 | 870 | 12 |
| retro-z80's (`TILES`, `LITTLE`) | 1918 | 1377 | 13 |
| retro-z80's `bpldma.v` | 2123 | 1754 | 1 |

Most of the flip-flops are the 384 data registers. Revision 2 (the per-group settings, `gset`) cost retro-z80's build about 100 LUTs and 30 flip-flops, retro68k's 10 and 30. The core is a little larger than retro68k's fetch (the generic widths, the second synchroniser flop, the registered `urgent`) and smaller than retro-z80's, whose bus registers and pointer capture are now the machine's, and whose pointers were flip-flops where the core uses LUT RAM. The machines' Vivado builds are the ones that count.

### 4.10 Reset

`rst` clears every count, deadline and toggle, the data registers and the request, and sets the round-robin's last layer served to NL − 1. It does **not** clear the pointers or their saved starts (retro68k keeps them in LUT RAM; clearing them would cost about 1,100 flip-flops in a planar build), nor the synchronisers. Software loads the pointers before use. Nothing is fetched until a line starts.

## 5. How a machine uses it

- **Register file.** The machine keeps its registers and bus. It loads pointers with `ptr_wr` (merging bytes from `ptr_rdata` for a partial write) and reads them with `ptr_rdata`, and holds stride, wrap, the tile pointers and the rest, driving them as ports.
- **Line settings.** Its video unit works out each layer's `act`, `adv`, `ngroups` and the tile row and column for the next line, ready at `line_go`. The settings taken at a group's start (`depth`, `planar`, `hscale`) and those read live (`wrap`, `stride`) come straight from the machine's registers: no once-a-line copy of them is needed, and that is the point of revision 2.
- **`layer_pix`.** One per layer: `dat`, `attr`, `gset`, `fill_t` to it, `take_t` back. Its `ready` comes from `line_gen` through a synchroniser. The machine's depth, planar and scale registers drive this core; `layer_pix` gets them per group in `gset`.
- **The scheduler.** One requester: `req`, `urgent`, `addr`, `ack`, and `rvalid_o` of that requester as `rvalid`. `rdata` from the memory controller.
- **The urgent mark.** Set `URG_BASE` and `URG_WORD` from the scheduler's worst-case wait for this requester (scheduler spec 4.6) in every slot plan the machine uses, plus one clock for the registered `urgent`. For example, on retro-z80's plan (slots 0 and 2 locked) the layers' worst case is 8 clocks, which its mark covers. `URG_WORD` is the clocks between this requester's words when it has the cycles it owns: 5 for two owned slots in a 5-slot, 100 ns round.
- **Byte order.** `LITTLE` = 1 for a little-endian machine.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/layer_fetch`, `tb_lock68k` and `tb_lockz80` | The core beside frozen copies of retro68k's and retro-z80's `bpldma.v` (`ref/`), each built to match (retro68k: `PLANAR`, `DATWRITE`, PW 23; retro-z80: `TILES`, `LITTLE`), on the same random settings, register writes, takes and a memory that is busy or quiet by spells, for 600,000 clocks each. Every clock: `dat`, `attr`, `fill_t`, `req`, `addr`, `line_go`, `line_gen` and every pointer equal. `urgent` against the reference's compare with the words left now, the deadline of the clock before and the mark + 1. The reference's `deadline` is not compared. Allowed for: `line_t` reaches the reference a clock later (the core has one more synchroniser flop); retro68k's BPLDMA writes are made only in `line_go` clocks (it restarted a fetch on them, the core does not); pointers are loaded before the first line. The register-file side of each machine is modelled in the test bench. Revision 2: depth, planar and scale change only in the line's first clock (the references read them live, the core takes them per group), and `urgent` is not compared in the `line_go` clock (the reference marks the request that `line_go` is dropping with the new line's depth, the core with its group's) |
| `test/layer_fetch`, `tb_model` | Builds the machines don't have, against a model of the data path and the pointer rules: one tile layer, little-endian (retro-z80's KS2 shape); four chunky layers; two layers with `PLANAR`, little-endian. Memory is a hash of the address, so every group's words follow from the pointer rules: each group that fills is checked word by word (tiles: the rows the entries pick, and `attr`), and at each line start every pointer is checked against start + stride (or the start) within the wrap block. A stride written just after the line start applies at its end; `ngroups` and `act` changed mid-line leave the line alone. Depth and scale written early in the line: every group's `gset` is the line's settings or, from some group on, the new ones (never back), with the planar flag as set, and the group's words are checked at the depth its `gset` says |
| `test/layer_pix` | Each group shown with its own `gset` (`layer_pix` spec, section 6) |
| The machines' system tests | Each machine's video tests, with the core in place of its `bpldma.v` |

## 7. Open points

| # | Point |
|---|-------|
| F1 | The register-bus side of retro68k's `bpldma.v` (BPLDMA set/clear, byte merging) and retro-z80's (the pointer capture for the CPU) move into each machine's register file. They are not part of this core |
| F2 | Closed: retro68k restarted a fetch being set up on any write to BPLDMA, which achieved nothing (the enables are a registered copy, and a group keeps its own word list). The core has no restart for `dma_en`; nothing in retro68k relied on it. The lockstep test allows for the difference |
| F3 | `sprite_fetch.v` has the same unused deadline output and a combinational urgent; it could get the same treatment |
| F4 | The deadline's 59 clocks a group assumes about 3.7 system clocks a screen pixel (576p at 100 MHz). A machine with another pixel clock needs it as a parameter |
| F5 | retro-z80's planned attribute layer (its video spec 7.1) needs no core change: it is a fourth layer (`NL` = 4) set up as 1-bit chunky, one word (two cells) a group, with its own pointer through `ptr_wr`, its own stride, wrap 0, the target layer's `hscale`, `adv` only on a cell row's last line, and its own `ngroups`. Its `fill_t` and `take_t` go to an attribute shifter in place of `layer_pix`. retro-z80 will confirm when it builds it on the KS3. With revision 2 each layer takes its scale at its own group starts, and the attribute layer's group starts are not the target's, so a mid-line scale change on the target is not followed exactly by its attribute layer: retro-z80 will either forbid it or take the attribute layer's scale from the target's `gset` |
| F6 | Closed: revision 2 (per-group settings, `gset`) is implemented in `rtl/layer_fetch.v` and `rtl/layer_pix.v` with the tests of section 6 (PR #9). The machines adopt it when they take the new cores: `gset` must be wired through, and `layer_pix` no longer has `planar`, `lb`, `planes` and `hs` inputs |
