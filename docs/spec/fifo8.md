# Byte FIFO (`fifo8`)

Status: **draft**

`fifo8` is a synchronous first-in first-out queue of bytes in block RAM, with one clock for both sides. It is first-word-fall-through: whenever it holds a byte, the oldest one is already on `rdata`, and `pop` takes it away. Both machines use two, as the receive and transmit buffers of the USB serial unit.

File: `rtl/fifo8.v`.

## 1. Summary

| Item | Value |
|------|-------|
| Clock | One, for writing and reading |
| Data | 8 bits |
| Depth | 2^AW bytes in the RAM, plus one in the output register: 2^AW + 1 in all |
| Storage | Inferred simple dual-port block RAM, 2^AW × 8 (AW = 11: one 18 Kbit block RAM) |
| Read style | First-word-fall-through: `rdata` shows the oldest byte while `valid` is 1 |
| Throughput | One push and one pop every clock, at the same time |
| Latency | A byte pushed into an empty FIFO is on `rdata` 2 edges after the push is taken |
| Overflow, underflow | A push while full is dropped; a pop while empty is ignored. No flags |
| Parameters | AW, the RAM's address width |

## 2. Ports

"Edge t" is the rising edge at which an input is sampled.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | The clock | – |
| `rst` | in | 1 | Synchronous reset, active high: empties the FIFO | Sampled at each edge |
| `push` | in | 1 | Write `wdata` into the FIFO | Sampled at each edge; one byte per clock while high |
| `wdata` | in | 8 | The byte to write | With `push` |
| `pop` | in | 1 | Take the byte on `rdata` away | Sampled at each edge; ignored while `valid` is 0 |
| `rdata` | out | 8 | The oldest byte | Meaningful while `valid` is 1; registered |
| `count` | out | AW + 2 | Bytes held, 0 to 2^AW + 1 | Combinational from registers; changes at each push and pop edge |
| `full` | out | 1 | The RAM is full: a push is taken only if a byte leaves the RAM in the same clock | Registered state |
| `valid` | out | 1 | `rdata` holds a byte | Registered |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| AW | 11 | RAM address width. The RAM holds 2^AW bytes, the FIFO 2^AW + 1. AW = 11 gives 2048 + 1 bytes; both machines' serial units use 11 as an example |

AW must be at least 1.

## 4. Behaviour

### 4.1 Inside

The FIFO is a RAM of 2^AW bytes with a write pointer and a read pointer, and an output register (`rdata`, `valid`) in front of it. `ram_count` is the number of bytes in the RAM; `count` = `ram_count` + `valid`.

In each clock:

| Event | When | Effect at the edge |
|-------|------|--------------------|
| Pop | `pop` and `valid` | The byte on `rdata` is gone |
| Refill | The RAM holds a byte (`ram_count` ≠ 0) and the output register is empty or being popped | The oldest RAM byte moves to `rdata`; `valid` 1 |
| Push | `push`, and the RAM not full or a refill in this clock | `wdata` is written into the RAM |
| Valid falls | A pop with no refill | `valid` 0 |

A refill takes only bytes written at an earlier edge. A byte pushed into an empty FIFO goes through the RAM, so it reaches `rdata` one clock after it was written.

### 4.2 Per clock

A push of A, then B, into an empty FIFO, and two pops:

| Edge | `push` | `pop` | After the edge: RAM | `rdata`, `valid` | `count` |
|------|--------|-------|---------------------|------------------|---------|
| 1 | A | – | A | –, 0 | 1 |
| 2 | B | – | B (A moved out) | A, 1 | 2 |
| 3 | – | – | B | A, 1 | 2 |
| 4 | – | 1 | – (B moved out) | B, 1 | 1 |
| 5 | – | 1 | – | B (stale), 0 | 0 |

- `count` goes up at the push edge, `valid` one edge later: `count` can be ahead of `valid` by a clock. Read `valid`, not `count`, to know there is a byte on `rdata`.
- Pops one a clock while the RAM holds bytes give one byte a clock, with no gap.
- A push and a pop in the same clock, with the RAM empty and one byte on `rdata`, empty the output register for one clock: the pushed byte comes out at the next edge. A steady stream of one push a clock still comes out at one byte a clock, two edges behind.

### 4.3 Full

`full` is 1 when the RAM holds 2^AW bytes. The FIFO then holds 2^AW + 1 bytes if `valid` is 1.

- A push while `full` is taken if a refill happens in the same clock (the output register is being popped, or is empty). The new byte is written at the RAM address being read in the same clock; the RAM must give the old byte to the read (read-first; open point F2).
- A push while `full` with no refill is dropped. Nothing says so.
- A writer that pushes only while `full` is 0 never loses a byte.

### 4.4 Empty

A `pop` while `valid` is 0 does nothing. `rdata` keeps the last byte it held.

### 4.5 Reset

`rst` empties the FIFO at the next edge: pointers and counts 0, `valid` 0. The RAM and `rdata` have no reset. A push or a refill in the reset clock still happens on the RAM side, so `rdata` may change at that edge; `valid` is 0 after it, so nothing reads it. A reset is also the way to flush the FIFO.

## 5. How a machine uses it

- **Write side.** Push only while `full` is 0, or push anyway and accept the drop. To drop the oldest byte when full instead (a "keep the newest" mode), pop and push in the same clock; section 4.3 makes that work.
- **Read side.** Use `rdata` while `valid` is 1, and pulse `pop` for one clock per byte taken. `pop` may be combinational from `valid`.
- **Counts.** `count` runs to 2^AW + 1. A register that reports "bytes held" or "room left" in a power of two should saturate it.
- **Flush.** Drive `rst` from the machine's reset or a flush command, for one clock.
- **Clock domains.** Both sides are in one clock. Data from another clock (the FT232H's strobes, for example) must be synchronised before `push` or `pop`.

## 6. Test plan

| Test | What it covers |
|------|----------------|
| `test/fifo8` | Run at AW = 1, 2 and 3 against a queue model, checked after every edge: `count`, `full`, `valid`, and `rdata` (the oldest byte while `valid`, the last byte held while not). Directed parts: the table of 4.2, pops while empty, a steady stream of one push a clock, filling to 2^AW + 1, pushes while full with no pop (dropped) and with a pop (taken), a push and a pop together at every fill level, reset while full and while streaming. Then 18,000 clocks of random pushes and pops at nine rates, with random resets. Counters make sure each of these cases came up |
| The serial unit's testbench (`make serial`) | retro-z80: bytes in order through the receive FIFO, flushes |
| The whole-system tests ("hello", the monitor session) | Both machines: every byte of the console through both FIFOs, against the FT232H model |
| The board | Both machines: the console over USB, every boot |

The unit test runs the RTL in simulation, which reads the old byte when a push and a refill use the same address (F2). It does not show that Vivado's block RAM does the same.

## 7. Open points

| # | Item |
|---|------|
| F1 | Done: `test/fifo8/` (section 6) |
| F2 | When full, a push and a refill use the same RAM address in the same clock. The RTL reads the old byte (Verilog non-blocking order), which needs the block RAM in read-first mode. Check that Vivado infers that (or that the netlist simulates the same), since a drop-oldest mode in a serial unit hits this case |
| F3 | The FIFO holds 2^AW + 1 bytes, one more than a power of two. A machine that says "2 KB" must saturate `count` (both machines do) |
| F4 | No overflow flag. A machine that wants to count dropped bytes does it outside, from `push` and `full` |
