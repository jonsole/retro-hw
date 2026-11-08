# SRAM controller (`sram_ctl`)

Status: **draft**

The SRAM controller runs the pins of an asynchronous 10 ns SRAM: one 16-bit read or write every 20 ns, at any address, in any mix. It does not choose who gets a cycle. A scheduler in the machine (the DMA scheduler, `dmac.v` in both machines today) gives it one request per memory cycle; the controller hands read data back 40 ns after the issue, with `rvalid`. The latency is fixed, so the scheduler knows whose read it is: the controller carries no tag.

File: `rtl/sram_ctl.v`.

## 1. Summary

| Item | Value |
|------|-------|
| Clock | One, the system clock: 100 MHz |
| Memory cycle | 20 ns = 2 clocks |
| Slot | 100 ns = 10 clocks = 5 memory cycles, numbered 0–4 |
| Memory | Asynchronous SRAM, 16 bits wide, up to 2M words (21 address bits): the IS61WV204816BLL-10 of the Next |
| Access | One 16-bit read or write per cycle. Reads take both bytes; writes take one or both (byte selects) |
| Issue to pins | A cycle issued at edge E is on the pins from E + 10 to E + 30 ns |
| Read latency | Data in `rdata` with `rvalid` from E + 30 to E + 40: logic takes it at edge E + 40 |
| Back to back | Every cycle can be used: reads and writes in any order, with no gap |
| Who gets a cycle | Decided outside, by the machine's scheduler |
| Pads | The outputs are registered again in the I/O pads (output flip-flops, and DDR registers for /OE, /WE and the data enable); `rdata` must be put in the input pads |
| Parameters | None |

## 2. Ports

E is the edge at which a cycle is issued (section 4.1). "Pins" means the SRAM pins after the pad registers the machine adds.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock, 100 MHz | – |
| `rst` | in | 1 | Synchronous reset, active high. Ends any cycle at once and drops read data in flight | Sampled at every edge |
| `sc` | in | 4 | Slot counter: the clock's place in the 100 ns slot, 0–9, counting up by 1 each clock and wrapping from 9 to 0 | Must step every clock |
| `go` | in | 1 | A request for the cycle that starts at the next edge | Looked at only while `start_next` is 1 |
| `go_we` | in | 1 | 1 = write, 0 = read | With `go` |
| `go_addr` | in | 21 | Word address (byte address bits 21–1) | With `go` |
| `go_wdata` | in | 16 | Write data. Bits 15–8 are the upper byte (D15–D8) | With `go`, writes only |
| `go_be` | in | 2 | Byte enables for a write: bit 1 = upper byte, bit 0 = lower byte. Ignored on a read | With `go`, writes only |
| `start_next` | out | 1 | A new memory cycle starts at the next edge (`sc` is odd) | Combinational from `sc` |
| `next_cycle` | out | 3 | The number in the slot (0–4) of the cycle that starts at the next edge | Combinational from `sc`; valid only while `start_next` is 1 |
| `rvalid` | out | 1 | `rdata` holds the data of the read issued at E. High for one clock | E + 30 to E + 40 |
| `rdata` | out | 16 | Read data, the whole word. Changes only when a read ends | Captured at E + 30; held until the next read ends |
| `sram_a` | out | 21 | Address, to the pad flip-flops | Set at E; pins E + 10 |
| `sram_ce_n` | out | 1 | Chip select, low during a cycle; high in an idle cycle | Set at E; pins E + 10 |
| `sram_ub_n`, `sram_lb_n` | out | 1 each | Byte selects: upper (D15–D8), lower (D7–D0). Both low for a read | Set at E; pins E + 10 |
| `sram_oe_n_r`, `sram_oe_n_f` | out | 1 each | /OE for the first (`_r`) and second (`_f`) half of the next clock, to a DDR register | Pins one clock later |
| `sram_we_n_r`, `sram_we_n_f` | out | 1 each | /WE, the same way | Pins one clock later |
| `sram_dq_o` | out | 16 | Write data, to the pad flip-flops | Set at E; pins E + 10 |
| `sram_dq_t_r`, `sram_dq_t_f` | out | 1 each | Data bus enable, the same way as /OE: 1 = not driving | Pins one clock later |
| `sram_dq_i` | in | 16 | Data from the pins | Sampled by `rdata` at E + 30 |

## 3. Parameters

None. The widths are fixed: 21 address bits (4 MB). A machine with less memory ties or drops the top address bits outside the core; both machines' 2 MB builds do this (open point S3).

## 4. Behaviour

### 4.1 Slots and cycles

`sc` counts the clocks of a 100 ns slot, 0–9. A memory cycle is 2 clocks. A new cycle starts at the edge after each clock with an odd `sc`:

| `sc` this clock | `start_next` | `next_cycle` | The edge that ends this clock |
|-----------------|--------------|--------------|-------------------------------|
| 1 | 1 | 1 | Issues cycle 1 (`sc` becomes 2) |
| 3 | 1 | 2 | Issues cycle 2 |
| 5 | 1 | 3 | Issues cycle 3 |
| 7 | 1 | 4 | Issues cycle 4 |
| 9 | 1 | 0 | Issues cycle 0 (`sc` becomes 0) |
| 0, 2, 4, 6, 8 | 0 | (not meaningful) | The second clock of a cycle |

So cycle k is issued at the edge where `sc` becomes 2k. In clocks with an even `sc`, `next_cycle` shows 1, 2, 3, 4 and 5; it means nothing there.

The scheduler looks at `start_next` and `next_cycle` in the clock before the issue and puts its choice on `go` and the other `go_*` inputs in the same clock (combinationally, or held from earlier). At the issue edge E the controller takes them. While `start_next` is 0, `go` is ignored: a request is never queued.

### 4.2 Per clock

The controller holds at most two cycles: the one starting on the pins and the one before it, whose read data is still to come.

| Edge | Read | Write |
|------|------|-------|
| E (issue) | Address, /CE low, both byte selects low into the outputs. /OE: high, then low (`_r` 1, `_f` 0). /WE high. Data enable off | Address, /CE low, byte selects from `go_be`, data into `sram_dq_o`. /OE high. /WE: high, then low (`_r` 1, `_f` 0). Data enable: off, then on |
| E + 10 | /OE low for both halves | /WE: low, then high (`_r` 0, `_f` 1). Data enable on for both halves |
| E + 20 | The next cycle's issue. The controller notes that this read's data is due | The next cycle's issue |
| E + 30 | `rdata` takes `sram_dq_i`; `rvalid` 1 for one clock | – |

At an issue edge with `go` 0 the outputs go idle: /CE, the byte selects, /OE and /WE high, data enable off.

### 4.3 On the pins

The machine registers every output once more in the pads (section 5), so the pins show the controller's outputs one clock later. The `_r` and `_f` halves go through DDR registers: `_r` shows from the edge, `_f` from 5 ns after it. A cycle issued at E:

| | E + 10 | E + 15 | E + 25 | E + 30 |
|---|---|---|---|---|
| **Read** | Address, /CE, /UB and /LB out | /OE low | | `rdata` captures the pins; the next cycle's address out |
| **Write** | Address, /CE, the byte selects out; data enable still off | Data driven; /WE low | /WE high | Data released; the next cycle's address out |

- /WE is low for 10 ns, with 5 ns of address set-up before it and 5 ns of hold after it. Data is set up 10 ns before /WE rises and held 5 ns after.
- **Read after write:** the FPGA stops driving at E + 30; /OE goes low at E + 35.
- **Write after read:** /OE goes high at the write's pin start (E + 30 for the read issued at E); the FPGA drives data 5 ns later.
- **Two reads:** /OE goes high for 5 ns between them (E + 30 to E + 35) and /CE stays low.
- **Two writes:** the data bus is let go for 5 ns between them, and /WE is high for 10 ns.
- **Idle:** /CE, /OE and /WE high, the bus undriven.

The margins against the IS61WV204816BLL-10 datasheet are worked out in retro-z80's memory spec (spec 2, section 8.3). The tightest are tHZOE on a write after a read (1 ns on paper) and tPWE (2 ns); the board delays are still to be checked (open point S1).

### 4.4 Read data

A read issued at E is captured at E + 30, the edge at which the next cycle's address reaches the pins; the SRAM's output hold (tOHA) and the pad delays cover the hold. `rvalid` is high from E + 30 to E + 40, so logic in the system clock takes the data at E + 40: 40 ns, or 4 clocks, after the issue. `rdata` keeps its value until the next read ends, so a channel may take it later. Whose read it was, the scheduler knows: it is the cycle it gave 4 clocks before (`dmac.v`'s `RD_DELAY`).

A write has no `rvalid`. It is done on the pins at E + 25.

### 4.5 Reset

`rst` makes the outputs idle at the next edge and forgets a read in flight (no `rvalid` comes for it). A write on the pins when reset comes has /WE cut short, so that word may be wrong (open point S4). `rdata` is not reset.

## 5. How a machine uses it

- **A slot counter.** `sc` must count 0–9 and wrap, one step per clock. Values 10–15 are never allowed.
- **A scheduler.** It decides, in each clock with `start_next` 1, who gets the cycle `next_cycle`, and drives `go` and the `go_*` inputs for it. It tells the winner it has been granted at the issue edge, so the winner can drop or change its request. It keeps who got each cycle for 4 clocks and sends each `rvalid` to the channel whose read it is.
- **Pad registers for the outputs.** `sram_a`, `sram_ce_n`, `sram_ub_n`, `sram_lb_n` and `sram_dq_o` each go through one flip-flop placed in the I/O pad (`IOB = TRUE`). The `_r`/`_f` pairs each go through a DDR output register (`oddr`, platform spec), with power-up value 1 (`INIT = 1`) so the SRAM is off and the bus undriven before the first clock. The data bus is 16 `IOBUF`s with the pad flip-flop as I and the DDR enable as T.
- **The read register in the input pads.** `rdata` must be placed in the input pad flip-flops, by a constraint on the cell (both machines: `set_property IOB TRUE` on `.../mem/rdata_reg*`). Without it the capture at E + 30 has the fabric delay to cover as well, and the timing in section 4.3 no longer holds.
- **The pins in simulation.** The same pad registers, with a small clock-to-out delay (1 ns in both machines' testbenches), the behavioural `oddr` (platform spec), and `sim/sram_model.v`.
- **Less memory.** For a 2 MB SRAM drop pin address bit 20, or fold the address before `go_addr`, so that the top half mirrors the bottom.
- **Reset.** Either the power-on reset or the machine's system reset. Both machines' choices are examples: one uses the power-on reset only, the other the system reset (open point S4).

## 6. Test plan

There is no unit test in `test/` yet (open point S2). The controller is tested inside each machine:

| Test | Machine | What it covers |
|------|---------|----------------|
| Whole-system testbench (`tb.v`) with `sim/sram_model.v`, datasheet checks on | Both | Every cycle the CPU, the display and a busy DMA port make, through the pad registers and `oddr`: set-up, hold, pulse widths, address change under /WE, bus contention, undefined data written |
| The DMA port's random word reads and writes against a copy (`+dma`) | Both | Reads and writes back to back, in every mix, from every cycle number; read data back to the right channel |
| The boot ROM's memory self-test, a 2 MB build | retro-z80 | Data lines, address lines, byte writes, the 2 MB mirror |
| The board | Both | The real SRAM and pads at 100 MHz, every boot |

## 7. Open points

| # | Item |
|---|------|
| S1 | Check the 20 ns cycles against the IS61WV204816BLL-10 datasheet with the pad and board delays of the KS2 and KS3. The tight points are tHZOE on a write after a read and tPWE. A fallback is for the scheduler not to issue a write straight after a read; it needs no change here |
| S2 | Proposed: a unit test `test/sram_ctl/` with the pad registers, the behavioural `oddr` and `sim/sram_model.v`: every pair of read and write back to back, idle cycles between, byte writes, `rvalid` at E + 30 to E + 40 for each cycle number, `go` ignored while `start_next` is 0, reset during a read and during a write |
| S3 | The address width is fixed (21 bits). A parameter could come if a machine needs less memory. (The 3-bit tag is gone: the scheduler routes read data itself, so the controller sets no limit on channels) |
| S4 | A reset during a write cuts /WE short. Proposed: let a write that is on the pins finish, or document that the system reset may corrupt the word being written |
| S5 | The file's header comment names a machine's spec number ("spec 5") and a machine's CPU path (`bus_if`, fx68k). Proposed: point to this spec instead |
