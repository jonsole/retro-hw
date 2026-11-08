# DMA scheduler (dmac)

Status: **draft**

The scheduler decides who gets each 20 ns memory cycle of the shared SRAM, as the Amiga's Agnus does. Seven channels ask for cycles. For each cycle the scheduler picks one by four rules and hands it to the SRAM controller (`sram_ctl.v`), which runs it on the pins.

Which cycles belong to whom is the slot plan: an owner for each of the 5 cycles in a 100 ns slot, and a mask of the cycles that urgent display fetches may not take. The plan comes in on two ports. The machine holds it in its own registers, so software can change it at any time; a machine whose plan never changes ties the ports to constants and the logic for them folds away.

A cycle its owner does not use goes to a fixed priority order, so no cycle is ever left idle while anyone is asking.

## 1. Summary

| Item | Value |
|------|-------|
| File | `rtl/dmac.v`, module `dmac` |
| Clock | One: the 100 MHz system clock |
| Memory cycle | 20 ns (2 clocks); 5 cycles (0–4) in a 100 ns slot; 50 M cycles a second |
| Channels | CPU, BPL (layers), SPR (sprites), AUD (audio), COP (copper), BLT (DMA engine), PORT (test port) |
| Hard-deadline channels | BPL and SPR, together "the display": each gives a deadline and an urgent flag |
| Slot plan | `slot_owner` (an owner for each cycle) and `slot_lock` (the cycles urgent requests may not take): ports, so programmable |
| Rules | Locked owner, then urgent display, then owner, then the free order |
| Decision | Combinational, in the clock before the cycle starts |
| Ack | 1 clock, registered: the clock after the decision |
| Read data | Back from `sram_ctl.v` with a tag; the scheduler decodes the tag into a valid line per channel |
| Registers | The 7 ack flip-flops only |
| Parameters | None |
| Size | About 175 LUTs and 7 flip-flops on a 7-series part (4.8) |

### 1.1 Where it sits

```
                 slot plan register (in the machine)
                        | slot_owner, slot_lock
                        v
 CPU  ----req/ack--->+--------+    go, go_we, go_addr,     +----------+
 BPL  ----req/ack--->|        |    go_wdata, go_be, go_tag |          |
 SPR  ----req/ack--->|        |--------------------------->|          |
 AUD  ----req/ack--->|  dmac  |                            | sram_ctl |<===> SRAM
 COP  ----req/ack--->|        |<---------------------------|          |
 BLT  ----req/ack--->|        |  start_next, next_cycle,   |          |
 PORT ----req/ack--->+--------+  rvalid, rtag              +----------+
   ^                     |                                      |
   |   x_rvalid          |                                      |
   +---------------------+                                      |
   ^                                                            |
   +------------------------- rdata (to every channel) ---------+
```

`timebase.v` drives `sc` into `sram_ctl.v`, which tells the scheduler which cycle starts next. The scheduler holds no state about the slot: it decides each cycle afresh from the requests, the plan and the cycle number.

## 2. Ports

All inputs are sampled in the system clock. Every channel's request inputs must be stable (or tied off) in the clocks with `start_next` high, as the decision is combinational from them.

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock, 100 MHz | – |
| `rst` | in | 1 | Reset: acks low | Synchronous |
| `start_next` | in | 1 | A memory cycle starts at the next edge | From `sram_ctl.v`, every other clock |
| `next_cycle` | in | 3 | Its number in the slot, 0–4 | With `start_next` |
| `slot_owner` | in | 15 | The owner of each cycle: bits 3n+2–3n for cycle n, coded as `go_tag` (0 no owner). BPL or SPR means the display (4.1) | Any time; read in the clock of `start_next` |
| `slot_lock` | in | 5 | Bit n: in cycle n an urgent request may not take the cycle from its owner | As `slot_owner` |
| `cpu_req` | in | 1 | The CPU asks for a cycle | Held until `cpu_ack` |
| `cpu_we`, `cpu_addr`, `cpu_wdata`, `cpu_be` | in | 1, 21, 16, 2 | Write flag, word address (bits 21–1), write data, byte enables (bit 1 the upper byte) | Stable while `cpu_req` |
| `cpu_ack` | out | 1 | The cycle was given | 1 clock, the clock after the decision |
| `cpu_rvalid` | out | 1 | Read data for the CPU is on the SRAM controller's `rdata` | 1 clock |
| `bpl_req`, `bpl_addr` | in | 1, 21 | The layer fetch asks to read a word | Held until `bpl_ack` |
| `bpl_deadline` | in | 10 | System clocks until the word is needed | With `bpl_req` |
| `bpl_urgent` | in | 1 | The request must not wait | With `bpl_req` |
| `bpl_ack`, `bpl_rvalid` | out | 1, 1 | As for the CPU | As for the CPU |
| `spr_req`, `spr_addr`, `spr_deadline`, `spr_urgent`, `spr_ack`, `spr_rvalid` | | | Sprites: as for the layers | |
| `aud_req`, `aud_addr`, `aud_ack`, `aud_rvalid` | | | Audio reads | |
| `cop_req`, `cop_addr`, `cop_ack`, `cop_rvalid` | | | Copper reads | |
| `cop_high` | in | 1 | The copper goes first in the free order | With `cop_req` |
| `blt_req`, `blt_we`, `blt_addr`, `blt_wdata`, `blt_be`, `blt_ack`, `blt_rvalid` | | | DMA engine reads and writes, as for the CPU | |
| `blt_high` | in | 1 | The DMA engine goes before the CPU in the free order | With `blt_req` |
| `port_req`, `port_we`, `port_addr`, `port_wdata`, `port_be`, `port_ack`, `port_rvalid` | | | The test port, as for the CPU | |
| `go` | out | 1 | A cycle starts at the next edge | Combinational, in the clock of `start_next` |
| `go_we`, `go_addr`, `go_wdata`, `go_be` | out | 1, 21, 16, 2 | The winner's cycle. Read-only channels give `go_we` 0 and `go_be` 11 | With `go` |
| `go_tag` | out | 3 | The winner: 1 CPU, 2 BPL, 3 SPR, 4 AUD, 5 COP, 6 BLT, 7 PORT; 0 none | With `go` |
| `rvalid`, `rtag` | in | 1, 3 | Read data back from `sram_ctl.v`, and whose it is | – |

The read data itself (`rdata`) goes from `sram_ctl.v` to every channel directly. Only the valid lines pass through the scheduler.

## 3. Parameters

None. The slot plan is the `slot_owner` and `slot_lock` ports (4.2); the copper's and the DMA engine's priorities are the `cop_high` and `blt_high` ports.

## 4. Behaviour

### 4.1 Channel codes

The same 3-bit code names a channel in `go_tag`, `rtag` and each field of `slot_owner`:

| Code | Channel | Reads/writes | Has a deadline | Its place in the free order |
|------|---------|--------------|----------------|------------------------------|
| 0 | none | – | – | – |
| 1 | CPU | both | no | 6th |
| 2 | BPL, layer fetch | reads | yes | 2nd (as the display) |
| 3 | SPR, sprite fetch | reads | yes | 2nd (as the display) |
| 4 | AUD, audio | reads | no | 3rd |
| 5 | COP, copper | reads | no | 1st with `cop_high`, else 4th |
| 6 | BLT, DMA engine | both | no | 5th with `blt_high`, else 7th |
| 7 | PORT, test port | both | no | 8th |

As an owner, codes 2 and 3 mean the same: the display (4.3).

### 4.2 The slot plan

`slot_owner` holds 5 fields of 3 bits, one for each cycle: bits 3n+2 to 3n for cycle n. Written in octal, one digit is one cycle, with cycle 0 as the last digit. `slot_lock` has bit n for cycle n.

| Plan | `slot_owner` | Cycles 0, 1, 2, 3, 4 | `slot_lock` | Use |
|------|--------------|----------------------|-------------|-----|
| A CPU that can wait | `15'o02421` | CPU, display, AUD, display, none | `5'b00000` | The 68000 machine. An urgent display fetch may take the CPU's cycle |
| A CPU that cannot wait | `15'o42121` | CPU, display, CPU, display, AUD | `5'b00101` | The Z80 machine. The CPU's cycles are its own |
| A big blit | `15'o02426` | BLT, display, AUD, display, none | `5'b00000` | The 68000 machine during a high-priority blit (its "HIGH" mode): the CPU gets only spare cycles |
| The copper first | `15'o02425` | COP, display, AUD, display, none | `5'b00000` | The 68000 machine with a "nasty" copper |
| Everything free | `15'o00000` | none | `5'b00000` | No guarantees: every cycle by the free order |

**Changing the plan.** The scheduler reads `slot_owner` and `slot_lock` only in clocks with `start_next` high, and only for the one cycle being decided (the field and bit for `next_cycle`). A change applies from the next cycle decided. A cycle already given is not affected, and a change in the middle of a slot is safe. The plan has no effect on a channel's handshake, only on how soon its ack comes.

A machine that changes its plan should drive the ports from a register (20 bits) with its default plan as the reset value. The register's address and layout are the machine's own.

**Rules for a plan.**
- A CPU that cannot be held off needs the cycles its bus cycle lines up with, owned and locked. Software must never take those away.
- The display needs owned cycles enough for its worst-case bandwidth (4.6); urgent fetches cover only bursts.
- Locks lengthen the worst-case wait of an urgent fetch (4.6). Lock only what must be locked.
- Owning a cycle does not reserve it: an unused owned cycle goes to the free order. So owning a cycle never costs bandwidth, only priority.

### 4.3 The display

BPL and SPR are compared as one channel, "the display": of those two that are asking, the one with the smaller deadline goes first, the layers on a tie. This is used in three places:

- **Urgent (rule 2):** among the channels asking with their urgent flag high, the smaller deadline, layers on a tie.
- **As an owner (rules 1 and 3):** among the channels asking, urgent or not, the smaller deadline, layers on a tie.
- **In the free order:** as for an owner.

A deadline is in system clocks until the word is needed, counting down; `10'h3FF` means no deadline. The urgent flag is each channel's own, set when its deadline passes a mark it chooses (4.6).

### 4.4 The rules

For the cycle that starts at the next edge (`start_next` high, `next_cycle` = n), the first rule that finds a request wins:

| Rule | Winner | When |
|------|--------|------|
| 1 | The owner of cycle n | `slot_lock` bit n is set and the owner asks |
| 2 | The urgent display channel (4.3) | `bpl_urgent` or `spr_urgent`, with its request |
| 3 | The owner of cycle n | The owner asks |
| 4 | The first in the free order that asks | Anyone asks |

The free order:

| Place | Channel |
|-------|---------|
| 1 | COP, if `cop_high` |
| 2 | The display (4.3) |
| 3 | AUD |
| 4 | COP |
| 5 | BLT, if `blt_high` |
| 6 | CPU |
| 7 | BLT |
| 8 | PORT |

If nobody asks, `go` is 0 and the cycle is idle. In a clock with `start_next` low the winner is "none" whatever is asking. Cycles 5–7 do not exist (`next_cycle` is 0–4); if one came, it would have no owner and no lock, and go by rules 2 and 4.

The same rules as pseudo-code:

```
owner   = slot_owner[3n+2:3n]              (none for n > 4)
locked  = slot_lock[n]                     (0 for n > 4)
asks(c) = c's req; for c = BPL or SPR: bpl_req or spr_req
own     = owner, or for BPL/SPR the display channel due first

if   !start_next              -> none
elif locked and asks(owner)   -> own
elif an urgent display req    -> the urgent one due first
elif asks(owner)              -> own
else                          -> first of the free order that asks
```

### 4.5 Timing

One column per clock. The CPU owns cycle 0 and asks in the clock with `sc` 9; the layers ask for cycle 1:

```
 sc (timebase)    8    9    0    1    2    3    4    5
 start_next       0    1    0    1    0    1    0    1
 next_cycle       .    0    .    1    .    2    .    3
 cpu_req          1    1    1    0    0    0    0    0
 bpl_req          0    0    1    1    1    0    0    0
 go_tag           .  CPU    .  BPL    .    .    .    .     combinational, in this clock
 cpu_ack          0    0    1    0    0    0    0    0
 bpl_ack          0    0    0    0    1    0    0    0
 cpu_rvalid       0    0    0    0    0    1    0    0
 bpl_rvalid       0    0    0    0    0    0    0    1
```

- **Decision.** Combinational, in each clock with `start_next` high. `go` and the `go_*` outputs are valid in that clock, and `sram_ctl.v` takes them at the edge that ends it (the issue edge E). Cycle n is issued at the edge where `sc` becomes 2n.
- **Ack.** Registered: high for the one clock after E. A channel drops `req`, or puts up its next request, on seeing the ack. The next decision is a clock after the ack, so a channel that puts up a new request at once can have every cycle.
- **Read data.** `rvalid` and the tag come from `sram_ctl.v` in the clock from E + 30 to E + 40 ns; `x_rvalid` is `rvalid` with the tag decoded, combinationally. The channel takes `rdata` at E + 40, 4 clocks after the issue.
- **Writes.** No `rvalid`. The write is done on the pins at E + 25 ns. Writes and reads from one channel are done in the order they were given.

### 4.6 What the plan guarantees

A slot is 100 ns, so one owned cycle a slot is 10 M words a second (20 MB/s). The SRAM gives 50 M words a second in all.

**Bandwidth.** A channel gets at least its owned cycles, less those taken by urgent display fetches (rule 2) when the cycle is not locked. A cycle the display owns always goes to the display when it asks. In the plans of 4.2:

| Plan | CPU | Display | AUD | The rest (COP, BLT, PORT) |
|------|-----|---------|-----|---------------------------|
| 68000 | 10 M/s, less urgent display fetches | 20 M/s | 10 M/s, less urgent fetches | Spare cycles only |
| Z80 | 20 M/s, never taken | 20 M/s | 10 M/s, less urgent fetches | Spare cycles only |
| Big blit | Spare cycles only | 20 M/s | 10 M/s, less urgent fetches | BLT 10 M/s, less urgent fetches |

On top of that, each channel gets the spare cycles its place in the free order wins.

**Urgent wait.** An urgent request loses a cycle only to a locked owner that asks, or to the other display channel if it is urgent too and due first. Let L be the longest run of locked cycles in a row (counting round the end of the slot), in any plan the machine may use. From the start of the clock in which an urgent request is first high to the edge at which the channel takes its data:

  worst case = 6 + 2L clocks, plus 2 if the other display channel may also be urgent and due first

That is 1 clock until a decision, 1 for the decision, 2 for each locked cycle lost, and 4 from the issue to the data. For the 68000 plan L = 0 (6 clocks, 8 with both urgent); for the Z80 plan L = 1 (8 clocks, 10). The channel's urgent mark must be at least this far before its deadline.

**A locked owner's wait.** At most until its next owned cycle. Counted from the start of the clock in which the request is first high to the issue edge: with one owned cycle a slot, 10 clocks; in the Z80 plan (cycles 0 and 2, decided 4 and 6 clocks apart), 6. Read data follows 4 clocks after the issue. It may be sooner, by a spare cycle.

**An unlocked owner's wait.** As for a locked owner, plus the cycles urgent requests take. That is bounded only by how often the display is urgent. A display that is urgent often has a plan that gives it too little bandwidth.

**The free order** has no bounds. A channel low in it gets nothing while those above it use every cycle. PORT, last, is for tests.

### 4.7 Reset

`rst` clears the acks at the next edge. The decision is combinational, so `go` still follows the requests during reset; the machine should hold `sram_ctl.v` in reset at the same time, which keeps the cycles idle. Nothing else is reset: the scheduler has no other state.

### 4.8 Implementation

The logic is in three parts, all combinational:

1. **The display compare.** Two 10-bit comparisons of `bpl_deadline` with `spr_deadline`: one for "due first" (`hard`), one with the urgent flags (`urg`).
2. **The candidates.** The free-order winner (a priority chain of 8), the owner (a 3-bit field picked from `slot_owner` by `next_cycle`, and its request), and the lock bit.
3. **The winner and the mux.** A 4-way priority choice of the winner code, then a 7-way mux of the address (21 bits), write data (16), byte enables and write flag onto `go_*`.

The longest path is from `next_cycle` (registered in `sram_ctl.v`) or a channel's request through the owner pick and the winner choice to the select of the address mux. It has a full 10 ns clock.

Resources (Yosys 0.33, `synth_xilinx` for 7-series, the scheduler on its own):

| Build | LUTs | Flip-flops |
|-------|------|------------|
| Z80 plan, ports tied to constants, `cop_high` and `blt_high` 0 | 173 | 7 |
| Every port free (a plan register outside) | 185 | 7 |

Most of it is the output mux. Constant plan ports fold into the rules; the plan register itself (20 flip-flops) is in the machine.

### 4.9 Design notes

- **Owners and priority.** A pure priority order lets the channels at the top starve those at the bottom, and makes CPU timing depend on what the display and the DMA engine are doing. Owned cycles give each channel a floor that is easy to work out (4.6). Spare cycles go by priority, so nothing is wasted.
- **Locks.** A CPU that cannot be held off must have its cycles even when the display is urgent. Without a lock, urgent fetches may take any cycle, which keeps their wait at its least.
- **The CPU in the free order.** The CPU can use spare cycles, so it runs faster when the memory is quiet. A Z80 bus takes its data whenever `cpu_rvalid` comes, so an earlier cycle does no harm.
- **What the plan replaced.** The first version had fixed cycle masks as parameters (`CPU_CYCLES`, `HARD_CYCLES`, `AUD_CYCLES`), a `CPU_FIRST` mode, a "nasty" copper level and a HIGH mode in which a DMA engine job took the CPU's cycle but left it 1 in 2, 4 or 8 of them. The plan register does all of that except the share: a machine writes COP or BLT over the CPU's cycle for as long as the job runs. Both machines agreed to drop the share; during a big blit the CPU gets spare cycles only.

## 5. How a machine uses it

The wrapper (or the machine's top level) must:

- **Connect `sram_ctl.v`.** Drive `start_next` and `next_cycle` from it, and `rvalid`, `rtag` back from it; give it `go_*`. Give `rdata` from it to every channel.
- **Give a slot plan.** Drive `slot_owner` and `slot_lock` from a register with the machine's default plan as its reset value, or tie them to constants. Keep any cycles a CPU cannot do without locked in every plan software may write.
- **Tie off unused channels.** `req` 0, the other inputs to any constant. Leave unused acks and valid lines open. An open `req` is X in simulation, and so is every decision.
- **Display deadlines.** Give the layer and sprite channels a deadline in system clocks (`10'h3FF` for none) and an urgent flag, set at a mark early enough for the worst case of 4.6 in every plan the machine uses.
- **Priorities.** Drive `cop_high` from the copper's priority setting and `blt_high` from the DMA engine's current job, or tie them to 0.
- **Hold each request.** `req`, the address and the write data stay still until the ack. After the ack, drop `req` or put up the next request at once. A `req` left high one clock too long gets a second cycle.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/dmac` | Random requests, deadlines and urgent flags on every channel, and a random slot plan that changes every few hundred clocks, also in mid-slot, for 400,000 clocks. Every clock: the winner, `go`, the address, write flag, byte enables and data against a model of the rules written separately (the free order as a list walked in turn); the acks a clock later; the valid lines against `rtag`. Counters make sure each rule came up: a locked owner over an urgent request, an urgent request over an owner, an owner, the display owner giving the cycle to the sprites, the CPU in a spare cycle, a `blt_high` job over the CPU, a `cop_high` copper over the display, the port, a cycle with no owner |
| The machines' system tests | Each machine's copper, sprite, video and CPU tests on its own plans. The bandwidth and deadline checks there are the real test of a plan |

## 7. Open points

| # | Point |
|---|-------|
| D1 | More channels (a second DMA engine, a disk) would need a wider tag than `sram_ctl.v` carries now, and wider owner fields |
| D2 | In a locked display cycle (rule 1) the display channel is picked by deadline alone, not by its urgent flag. With deadlines and urgent marks that agree this makes no difference |
| D3 | A plan that owns more than one cycle a slot for audio, the copper or the DMA engine is allowed but untried |
| D4 | The size figures are from Yosys; the machines' Vivado builds are the ones that count |
