# Copper engine (`copper_engine`)

Status: **draft**

`copper_engine` is the part of a copper that does not depend on its instruction words. It fetches a list of 16-bit words from memory into a small buffer, runs one instruction at a time, waits for beam positions, and handles jumps, skips, calls and returns, starts, the frame restart, resume and errors. The machine decodes the words: for the instruction at the front of the buffer it says how many words it needs and takes up, and what it does (an op code). The machine also keeps the registers, makes the register write's address and data, and does anything else an instruction changes (an index register's step, an ALU).

File: `rtl/copper_engine.v`.

## 1. Summary

| Item | Value |
|------|-------|
| Clock | One (the system clock) |
| Words | 16 bits, fetched one at a time |
| Buffer | Up to 3 words. The engine fetches until it holds 2, or as many as the instruction at the front needs (up to 3) |
| Instructions | 1 or 2 words long; up to 3 words needed before one runs (a skip that reads the next instruction's length) |
| Ops | NEXT, WRITE, WAIT, SKIP, SKIPC, JUMP, CALL, RET, STOP, ERR, MORE (section 4.2) |
| Rate | One instruction a clock at best; a write is followed by a spare clock |
| Stack | 8 places, for CALL and RET |
| Lists | Two start places, `list1` and `list2`, held by the machine |
| Beam compare | Line and pixel, 11 bits each, against `VTOT` and `HTOT` |
| Memory | A request / acknowledge / read-valid channel, one word on its way at a time |
| Places | Word addresses, bits `AW` to 1 of a byte address |
| Parameters | `AW`, `VTOT`, `HTOT`, `WR_HANDSHAKE` |

## 2. Ports

"Edge t" is the rising edge at which an input is sampled. A strobe is high for one clock. "Combinational" outputs follow the engine's state and the inputs in the same clock.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | – |
| `rst` | in | 1 | Synchronous reset, active high: stopped, buffer empty, stack empty, no request | Sampled at each edge |
| `run` | in | 1 | The copper may run. Low stops it, as STOP does, and forgets that it was in list 2 | Level; sampled at each edge |
| `frame` | in | 1 | Strobe: the frame starts. Start at `list1` | Acts only with `run` high |
| `start1` | in | 1 | Strobe: start at `list1` | Acts only with `run` high |
| `start2` | in | 1 | Strobe: start at `list2`; the engine is then in list 2 | Acts only with `run` high |
| `list1`, `list2` | in | `AW` | The two lists' first places | Read at the edge of a start or frame |
| `resume` | in | 1 | Keep list 2's place over a frame start (`save2`) | Read in the `frame` clock |
| `stack_keep` | in | 1 | Keep the stack over a frame start; 0 empties it | Read in the `frame` clock |
| `stack_clear` | in | 1 | Strobe: empty the stack. Wins over everything else that clock | Any time |
| `save2` | out | 1 | Strobe: write `save2_at` into the machine's list 2 pointer | Combinational: `frame` and `run` and `resume` and in list 2 |
| `save2_at` | out | `AW` | List 2's place to go back to (section 4.6) | Combinational, with `save2` |
| `word0`, `word1`, `word2` | out | 16 | The buffer: the instruction's first word, then the next two | Registered; valid as far as the buffer holds words (`need` of them when `exec` is high) |
| `need` | in | 2 | Words the instruction needs in the buffer before it runs, 1 to 3 | Combinational from `word0` (and the machine's state) |
| `len` | in | 2 | Words the instruction takes up, 1 or 2 | As `need` |
| `skip_len` | in | 2 | Words the next instruction takes up, for a SKIP or SKIPC that skips it | Read when a skip is taken; the words it is made from must be among the `need` |
| `op` | in | 4 | What the instruction does (section 4.2) | As `need` |
| `target` | in | `AW` | JUMP and CALL: the place to go to | Read in the `exec` clock |
| `pos_line`, `pos_px` | in | 11 | WAIT and SKIP: the beam position | Read in the `exec` clock |
| `pos_rel` | in | 1 | WAIT and SKIP: compare the pixel only, on this line (section 4.4) | Read in the `exec` clock |
| `wait_blt` | in | 1 | WAIT: wait for `blt_idle` as well | Read in the `exec` clock |
| `cc` | in | 4 | SKIPC: the condition (section 4.5) | Read in the `exec` clock |
| `flags` | in | 3 | SKIPC: C (bit 2), N (bit 1), Z (bit 0), from the machine | Read in the `exec` clock |
| `exec` | out | 1 | The instruction in the buffer runs at the end of this clock | Combinational |
| `more` | out | 1 | An OP_MORE instruction's second clock runs at the end of this clock | Combinational |
| `error` | out | 1 | Strobe: the instruction running stops the copper with an error (OP_ERR, an unknown op, CALL with the stack full, RET with it empty) | Combinational, in the `exec` clock |
| `wr_req` | out | 1 | A register write: the machine's write is on the bus | Registered; see section 4.3 |
| `wr_go` | in | 1 | With `WR_HANDSHAKE` = 1: the write is on the bus this clock | Sampled while `wr_req` is high; unused when `WR_HANDSHAKE` = 0 |
| `stopped` | out | 1 | The copper is stopped | Registered state |
| `waiting` | out | 1 | A WAIT is waiting | Registered state |
| `pc` | out | `AW` | The next instruction to run, while running; else the instruction running (a WAIT, a write, the STOP, the instruction that failed) | Combinational from registers |
| `sp` | out | 4 | Places on the stack, 0 to 8 | Registered |
| `mem_req` | out | 1 | A word is wanted | Held until `mem_ack` |
| `mem_addr` | out | `AW` | Its place | Steady while `mem_req` |
| `mem_ack` | in | 1 | The request is taken | May come in the clock `mem_req` first shows |
| `mem_rvalid` | in | 1 | Strobe: the word is on `mem_rdata` | At least a clock after `mem_ack` |
| `mem_rdata` | in | 16 | The word | With `mem_rvalid` |
| `beam_v` | in | 11 | The beam's line, 0 to `VTOT` − 1, counting from the frame start | Any time |
| `beam_h` | in | 11 | The beam's pixel, 0 to `HTOT` − 1 | Any time |
| `blt_idle` | in | 1 | The DMA engine has nothing to do | Any time |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `AW` | 21 | Place width: places are bits `AW` to 1 of a byte address. For example 21 (a 4 MB memory) with byte-wide places in the lists; 22 where the machine's list pointers keep one more bit than the memory |
| `VTOT` | 625 | Lines in a frame. A position at or past it is never reached |
| `HTOT` | 864 | Pixels in a line. A pixel at or past it is never reached |
| `WR_HANDSHAKE` | 0 | 0: a write is on the bus in the clock after the instruction runs, for one clock. 1: it stays requested until `wr_go` (for a bus that may hold the copper's write back). For example 0 on a machine where the copper goes first on the register bus, 1 where the CPU's access already on the bus goes first |

`mem_addr` is `AW` bits. A machine whose memory is narrower uses the low bits.

## 4. Behaviour

### 4.1 States

| State | Meaning | Leaves |
|-------|---------|--------|
| Stopped | Not running: after reset, STOP, an error, or `run` low | A start or frame with `run` high |
| Run | Ready for the next instruction | When it runs (`exec`) |
| Wait | A WAIT is waiting | The edge at which the beam is at or past the position (and `blt_idle`, if asked) |
| Write | A write not yet on the bus (`WR_HANDSHAKE` = 1 only) | The edge at which `wr_go` is high |
| Gap | The spare clock after a write | The next edge |
| More | The second clock of an OP_MORE instruction | The next edge |

`exec` is high when the engine is in Run, the buffer holds at least `need` words (and at least one), and no start or frame acts in this clock. At that edge the instruction's `len` words leave the buffer, and `pc` moves past it.

A clock with a start or a frame (and `run` high) runs nothing: neither `exec` nor `more` is high. So an instruction is never cut off half done.

### 4.2 Ops

| Code | Op | What the engine does at the `exec` edge |
|------|----|-------------------------------------------|
| 0 | NEXT | Nothing: on to the next instruction |
| 1 | WRITE | A register write (section 4.3). The machine takes the address and data at this edge |
| 2 | WAIT | Waits for the beam (section 4.4) |
| 3 | SKIP | If the beam is at or past the position, skips the next instruction (`skip_len` words) |
| 4 | SKIPC | If `cc` holds on `flags` (section 4.5), skips the next instruction |
| 5 | JUMP | Goes to `target` |
| 6 | CALL | Puts the place after this instruction on the stack and goes to `target`. With 8 places on the stack: error |
| 7 | RET | Takes the last place off the stack and goes there. With the stack empty: error |
| 8 | STOP | Stops. `pc` stays at the STOP |
| 9 | ERR | Stops, with `error` high |
| 10 | MORE | Goes to More for one clock; `more` is high in that clock. The machine does the instruction's work then (an ALU) |
| 11–15 | – | As ERR |

A jump, a taken skip, a CALL and a RET throw the buffer away and fetch from the new place. A machine's "end of list" (a WAIT for a position that is never reached, for example) is decoded by the machine as STOP if it wants the copper stopped rather than waiting.

### 4.3 Writes

With `WR_HANDSHAKE` = 0:

| Clock | State | `exec` | `wr_req` |
|-------|-------|--------|----------|
| t | Run | 1 (WRITE) | 0 |
| t + 1 | Gap | 0 | 1 |
| t + 2 | Run | the next instruction, if its words are in | 0 |

So a copper writes at most every second clock. The spare clock lets a write to the copper's own registers (a start strobe, a register a later instruction reads) take effect before the next instruction runs.

With `WR_HANDSHAKE` = 1, `wr_req` rises after edge t and stays high until the edge at which `wr_go` is high (that clock is the write on the bus). Gap follows, then Run. A start, a frame, or `run` low drops a write still waiting.

If `run` falls in the clock an instruction runs, the instruction still runs. With `WR_HANDSHAKE` = 0 its write still goes out; with 1 it is dropped.

### 4.4 Positions

A position is reached when `beam_v` > `pos_line`, or `beam_v` = `pos_line` and `beam_h` ≥ `pos_px`. A position with `pos_line` ≥ `VTOT` or `pos_px` ≥ `HTOT` is never reached.

With `pos_rel`:

- WAIT waits for pixel `pos_px` on this line if the beam has not reached it yet, else on the next line. The line is taken when the WAIT runs. On the last line, "the next line" is `VTOT`: it is never reached, and the frame start ends the WAIT. A `pos_px` ≥ `HTOT` never ends.
- SKIP compares the pixel only: `beam_h` ≥ `pos_px` (and `pos_px` < `HTOT`).

A WAIT with `wait_blt` also waits for `blt_idle`. The WAIT ends at the first edge at which both hold; the next instruction can run in the next clock.

### 4.5 Conditions

| `cc` | Holds when |
|------|------------|
| 0 | Z |
| 1 | not Z |
| 2 | C |
| 3 | not C |
| 4 | N |
| 5 | not N |
| 6 | not C and not Z (higher, unsigned) |
| 7 | C or Z (lower or same) |
| 8–15 | Never |

### 4.6 Starts, frames and resume

At the edge of a start or a frame (with `run` high), the engine throws the buffer away, drops a write still waiting, goes to Run and fetches from the list's first place.

| Strobe | Starts at | In list 2 after | Stack |
|--------|-----------|-----------------|-------|
| `start1` | `list1` | No | Kept |
| `start2` | `list2` | Yes | Kept |
| `frame` | `list1` | No | Emptied unless `stack_keep` |

If more than one acts in the same clock, `frame` wins over `start2`, and `start2` over `start1`.

With `resume`, a frame start while in list 2 raises `save2` in the same clock, with `save2_at` the place list 2 should go on from:

| Engine state in the frame clock | `save2_at` |
|---------------------------------|------------|
| Wait, More, or Write without `wr_go` | The instruction running: it runs again from the start |
| Run, Gap, Write with `wr_go` | The next instruction. After a taken skip, that is past the skipped one |

The machine writes `save2_at` into its list 2 pointer, so a later `start2` (or the frame's own list) picks up from there. STOP, an error and `run` low end list 2: a later frame saves nothing.

### 4.7 Fetch

- The engine asks for one word at a time. `mem_req` rises after an edge at which no word is asked for or on its way, the engine is not stopped, nothing is thrown away in that edge, and the buffer holds fewer than 2 words or fewer than `need`.
- `mem_req` stays high, with `mem_addr` steady, until `mem_ack`. The word comes with `mem_rvalid`. A new request can rise only after the edge at which the word came.
- When the buffer is thrown away (a jump, a start, a frame, `run` low while running), a request still waiting or a word on its way is marked stale. Its word is dropped when it comes, and the next request waits for it. A stale request is not withdrawn: it stays up until acknowledged.
- With a 1-clock acknowledge and the word one clock later, a word comes every 3 clocks.

### 4.8 Reset

`rst` stops the engine, empties the buffer and the stack, clears the in-list-2 flag and any request and write. The buffer's words and a WAIT's position keep their values; they are never used before they are loaded.

## 5. How a machine uses it

A machine's copper is a thin wrapper round the engine. The wrapper must:

- **Hold the registers**: the control bits (on, interrupt, resume, stack keep, priority), the two list pointers, status, the index and general registers and the flags. Drive `run` from its own on bit and any DMA enables; `resume` and `stack_keep` from its control bits; `list1` and `list2` from its pointers.
- **Turn bus writes into strobes**: the "start list 1", "start list 2" and "empty the stack" registers drive `start1`, `start2` and `stack_clear` for one clock; `frame` comes from the video's frame start.
- **Take `save2`**: write `save2_at` into the list 2 pointer, before the bus's own write in the same clock (the bus wins).
- **Decode the words**: from `word0` (and `word1`, `word2` when needed), drive `need`, `len`, `skip_len`, `op`, `target`, `pos_line`, `pos_px`, `pos_rel`, `wait_blt` and `cc`. Reserved patterns decode as ERR. These must be combinational from the buffer and the wrapper's registers, never from `exec` or `more`.
- **Act on `exec`**: for a WRITE, latch the write's address and data at that edge (the bus sees them with `wr_req`); step an index register; latch what an OP_MORE instruction needs for its second clock.
- **Act on `more`**: the ALU, or whatever the second clock does.
- **Act on `error`**: set the error status bit.
- **Report state**: status from `stopped` and `waiting`; the program counter from `pc`; the stack depth from `sp`.
- **Put the write on the bus**: with `WR_HANDSHAKE` = 0 the write is on the bus in the clock `wr_req` is high, so the bus must take it at once. With 1, the bus says when with `wr_go`.
- **Connect memory**: `mem_req`, `mem_addr` to the scheduler's copper channel (with the wrapper's priority bits beside them), and `mem_ack`, `mem_rvalid`, `mem_rdata` back.

A fixed-length instruction set (always two words) uses `need` = `len` = `skip_len` = 2. A variable-length one tells the engine each instruction's length; a skip then needs one word more than its length, so that `skip_len` can be read from the next instruction's first word.

## 6. Test plan

`test/copper/` runs the engine with a made-up instruction set decoded in the testbench, lists in a memory model, and a short frame (`VTOT` 20, `HTOT` 30). It is built twice, with `WR_HANDSHAKE` 0 and 1. At every `exec` it checks that the buffer holds the words at `pc`.

| Test | What it checks |
|------|----------------|
| 1 | Writes in a row, then STOP: the places run, `wr_req` the clock after `exec`, `pc` at the STOP |
| 2 | A WAIT on the beam; then two writes 2 clocks apart (3 with the handshake) |
| 3 | A WAIT held by `blt_idle`; a WAIT for a line past `VTOT` never ends |
| 4 | JUMP; SKIP taken over a two-word instruction and not taken; SKIPC taken and not |
| 5 | CALL and RET; RET with the stack empty and CALL with it full are errors; `stack_clear` |
| 6 | ERR and an unknown op stop with `error`; MORE gives one `more` |
| 7 | A RET while the next word is on its way: the word is dropped |
| 8 | Resume: a frame while list 2 waits saves the WAIT's place; `stack_keep`; no save after list 2 ended or without `resume` |
| 9 | `run` low stops the engine and forgets list 2; a start with `run` low does nothing |
| 10 | With the handshake: the write waits for `wr_go`; a frame while it waits saves the write's place and drops it |
| 11 | Random acknowledge delays over a long list with skips |

Each machine's own copper test checks its wrapper and the engine together: every instruction of its set, its registers, and its frame timing. The whole-system tests run real lists.

## 7. Open points

| # | Item |
|---|------|
| C1 | The engine takes the frame start at beam (0, 0). A machine whose frame starts elsewhere must count `beam_v` from its frame start |
| C2 | One word on its way at a time. A memory with a long latency slows the copper; more words in flight would need a deeper buffer and more stale counting |
| C3 | A stale request is not withdrawn when the buffer is thrown away (section 4.7). Withdrawing it would save a memory cycle, but both machines' timing depends on the present behaviour |
| C4 | The stack is 8 places. A parameter could size it if a machine needs more |
