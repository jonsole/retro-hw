# Memory-cycle scheduler (dmac)

Status: **draft**

The scheduler decides which requester gets each memory cycle of the shared SRAM, as the Amiga's Agnus does. It has N requesters, numbered 0 to N−1, and a slot plan of S slots. Both are parameters, set when the scheduler is instantiated. The requesters are generic: the scheduler does not know which is the CPU, the display or the copper. The machine decides that, by the numbers it gives them and by its slot plan.

For each cycle the scheduler picks one requester by four rules and hands its cycle to the SRAM controller (`sram_ctl.v`). The slot plan says which requesters own each slot, and which slots an urgent request may not take. It comes in on ports, so the machine can hold it in a register and software can change it at any time. A slot whose owners do not ask goes to the other requesters, so no cycle is left idle while anyone is asking.

## 1. Summary

| Item | Value |
|------|-------|
| File | `rtl/dmac.v`, module `dmac` |
| Clock | One: the system clock (100 MHz in both machines) |
| Requesters | N (parameter), numbered 0 to N−1. Where two tie, the lower number wins |
| Slot plan | S slots (parameter). For each slot a mask of its owners and a lock bit: ports, so programmable |
| Which slot | The machine gives the slot number of each cycle (`next_slot`) |
| Rules | A locked slot's owner, then an urgent request, then an owner, then a high request, then any request |
| Decision | Combinational, in the clock before the cycle starts |
| Ack | 1 clock, registered: the clock after the decision |
| Read data | Back from `sram_ctl.v` with the winner's number as its tag; decoded into a valid line per requester |
| Registers | The N ack flip-flops only |
| Size | 170 LUTs and 7 flip-flops for N = 7, S = 5 with a constant plan; 208 LUTs with a programmable one (4.8) |

### 1.1 Where it sits

```
                 slot plan register (in the machine)
                        | slot_owner, slot_lock
                        v
 requester 0   --req/ack-->+--------+    go, go_we, go_addr,      +----------+
 requester 1   --req/ack-->|        |    go_wdata, go_be, go_tag  |          |
     ...                   |  dmac  |---------------------------->| sram_ctl |<===> SRAM
 requester N-1 --req/ack-->|        |<----------------------------|          |
     ^                     +--------+  start_next, rvalid, rtag   +----------+
     |  rvalid_o[k]             ^                                   |    |
     +--------------------------+------------- rdata (to all) ------+    |
                                |                                        |
                        next_slot (from next_cycle, or the machine's own counter)
```

`timebase.v` drives `sc` into `sram_ctl.v`, which says when a cycle starts. The scheduler decides each cycle afresh from the requests, the plan and the slot number. It keeps no state about the plan.

## 2. Ports

All inputs are sampled in the system clock. The decision is combinational from them in each clock with `start_next` high, so they must be stable (or tied off) there.

Requester k's signals are bit k of a 1-bit-per-requester port, or field k of a wider one (bits k×AW to k×AW+AW−1 of `addr`, for example).

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock | – |
| `rst` | in | 1 | Reset: acks low | Synchronous |
| `start_next` | in | 1 | A memory cycle starts at the next edge | From `sram_ctl.v` |
| `next_slot` | in | SW | The slot of the plan that cycle is in, 0 to S−1. A value of S or more is a cycle with no owners and no lock | With `start_next` |
| `slot_owner` | in | S×N | Bits n×N to n×N+N−1: slot n's owners, bit k for requester k. Any number of owners, or none | Read in the clock of `start_next`, for `next_slot` only |
| `slot_lock` | in | S | Bit n: in slot n, an urgent request may not take the cycle from an owner that asks | As `slot_owner` |
| `req` | in | N | Requester k asks for a cycle | Held until its ack |
| `urgent` | in | N | Requester k's request must not wait (rule 2) | With `req` |
| `high` | in | N | Requester k goes first among the spare-cycle requests (rule 4) | With `req` |
| `we` | in | N | 1 write, 0 read. Tie to 0 for a requester that only reads | With `req` |
| `addr` | in | N×AW | Word addresses | Stable while `req` |
| `wdata` | in | N×DW | Write data. Tie to 0 for a requester that only reads | Stable while `req` |
| `be` | in | N×DW/8 | Byte enables for a write, bit 0 the lowest byte. Tie to 0 for a requester that only reads | Stable while `req` |
| `ack` | out | N | Requester k was given a cycle | 1 clock, the clock after the decision |
| `rvalid_o` | out | N | Read data for requester k is on the SRAM controller's `rdata` | 1 clock |
| `go` | out | 1 | A cycle starts at the next edge | Combinational, in the clock of `start_next` |
| `go_we`, `go_addr`, `go_wdata`, `go_be` | out | 1, AW, DW, DW/8 | The winner's cycle; all 0 with no winner | With `go` |
| `go_tag` | out | TW | The winner's number | With `go` |
| `rvalid`, `rtag` | in | 1, TW | Read data back from `sram_ctl.v`, and whose it is | – |

The read data itself (`rdata`) goes from `sram_ctl.v` to every requester directly. Only the valid lines pass through the scheduler.

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `N` | 7 | Requesters. 1 or more; at most 8 with `sram_ctl.v` as it is (its tag is 3 bits) |
| `S` | 5 | Slots in the plan. 1 or more |
| `AW` | 21 | Word address width |
| `DW` | 16 | Data width, a multiple of 8 |
| `SW` | clog2(S), at least 1 | Width of `next_slot`. Leave it to the default |
| `TW` | clog2(N), at least 1 | Width of `go_tag` and `rtag`. Leave it to the default |

## 4. Behaviour

### 4.1 Numbers

A requester's number is its priority: wherever two requesters meet in the same rule, the lower number wins. The number is also its tag on `go_tag` and `rtag`.

So the machine chooses the order of its requesters by the numbers it gives them. For example, both machines today would number them so:

| Number | Requester | Writes | Urgent | High |
|--------|-----------|--------|--------|------|
| 0 | Layer fetch | no | yes | no |
| 1 | Sprite fetch | no | yes | no |
| 2 | Audio | no | no | no |
| 3 | Copper | no | no | the copper's priority bit |
| 4 | CPU | yes | no | no |
| 5 | DMA engine | yes | no | the job's priority bit |
| 6 | Test port | yes | no | no |

### 4.2 The slot plan

Slot n has an owner mask (bits n×N to n×N+N−1 of `slot_owner`) and a lock bit (bit n of `slot_lock`). With the numbers of 4.1, 5 slots of 20 ns each (S = 5, one 100 ns round of `sram_ctl.v`):

| Plan | Slot 0 | Slot 1 | Slot 2 | Slot 3 | Slot 4 | Locked | Use |
|------|--------|--------|--------|--------|--------|--------|-----|
| A CPU that can wait | CPU | layers, sprites | audio | layers, sprites | – | – | The 68000 machine. An urgent fetch may take the CPU's slot |
| A CPU that cannot wait | CPU | layers, sprites | CPU | layers, sprites | audio | 0, 2 | The Z80 machine. The CPU's slots are its own |
| A big blit | DMA engine | layers, sprites | audio | layers, sprites | – | – | The CPU gets spare cycles only |
| The copper first | copper | layers, sprites | audio | layers, sprites | – | – | A copper list that must not wait for the CPU |
| Everything free | – | – | – | – | – | – | Every cycle by rule 4 |

As masks, slot 0 first (bit 0 of each mask on the right):

| Plan | Owner masks, slots 0 to 4 | `slot_lock` |
|------|---------------------------|-------------|
| A CPU that can wait | `0010000`, `0000011`, `0000100`, `0000011`, `0000000` | `00000` |
| A CPU that cannot wait | `0010000`, `0000011`, `0010000`, `0000011`, `0000100` | `00101` |
| A big blit | `0100000`, `0000011`, `0000100`, `0000011`, `0000000` | `00000` |

In Verilog the mask of slot 0 goes last: `slot_owner = {7'b0000000, 7'b0000011, 7'b0000100, 7'b0000011, 7'b0010000}` is the first plan.

**Changing the plan.** The scheduler reads the owner mask and lock bit only in clocks with `start_next` high, and only those of `next_slot`. A change applies from the next cycle decided. A cycle already given is not affected, and a change in the middle of a round is safe. The plan has no effect on a requester's handshake, only on how soon its ack comes.

**Rules for a plan.**
- A requester that cannot be held off (a CPU on a fixed bus clock) needs the slots its bus cycle lines up with, owned and locked. Software must never take those away.
- A requester with a deadline needs owned slots enough for its worst-case bandwidth (4.6). Urgent requests cover only bursts.
- Locks lengthen the worst-case wait of an urgent request (4.6). Lock only what must be locked.
- Owning a slot does not reserve it: an unused owned slot goes to rule 4. Owning a slot never costs bandwidth, only priority.

### 4.3 The slot number

`next_slot` says which slot of the plan the next cycle is in. The machine drives it:

- **S = 5:** `next_cycle` from `sram_ctl.v` (0 to 4, one 100 ns round) can drive it directly. Slot n is then the cycle issued at the edge where `sc` becomes 2n.
- **Any other S:** a counter that steps on each `start_next` and wraps at S. If a requester's timing is tied to the round (a CPU on a fixed bus clock), the counter must be lined up with that, for example cleared when `sc` and the CPU's clock are both at a known point.
- Values from S up to 2^SW − 1 mean a cycle with no owners and no lock. A counter that never reaches them needs no care.

### 4.4 The rules

For the cycle that starts at the next edge (`start_next` high, `next_slot` = n), the first rule that finds a request wins, and within a rule the lowest number wins:

| Rule | Winner | When |
|------|--------|------|
| 1 | An owner of slot n | Slot n is locked and an owner asks |
| 2 | An urgent requester | Any requester asks with `urgent` |
| 3 | An owner of slot n | An owner asks |
| 4a | A high requester | Any requester asks with `high` |
| 4b | Any requester | Anyone asks |

If nobody asks, `go` is 0 and the cycle is idle. In a clock with `start_next` low there is no winner, whatever is asking.

The same as pseudo-code:

```
owners = slot_owner[n*N +: N]  (0 if n >= S)
locked = slot_lock[n]          (0 if n >= S)
first(m) = the lowest set bit of m

if   !start_next                   -> none
elif locked and (owners & req)     -> first(owners & req)
elif (urgent & req)                -> first(urgent & req)
elif (owners & req)                -> first(owners & req)
elif (high & req)                  -> first(high & req)
elif req                           -> first(req)
else                               -> none
```

### 4.5 Timing

One column per clock, with S = 5 and `next_slot` from `next_cycle`. Requester 4 owns slot 0 and asks in the clock with `sc` 9; requester 0 asks for slot 1:

```
 sc (timebase)    8    9    0    1    2    3    4    5
 start_next       0    1    0    1    0    1    0    1
 next_slot        .    0    .    1    .    2    .    3
 req[4]           1    1    1    0    0    0    0    0
 req[0]           0    0    1    1    1    0    0    0
 go_tag           .    4    .    0    .    .    .    .     combinational, in this clock
 ack[4]           0    0    1    0    0    0    0    0
 ack[0]           0    0    0    0    1    0    0    0
 rvalid_o[4]      0    0    0    0    0    1    0    0
 rvalid_o[0]      0    0    0    0    0    0    0    1
```

- **Decision.** Combinational, in each clock with `start_next` high. `go` and the `go_*` outputs are valid in that clock, and `sram_ctl.v` takes them at the edge that ends it (the issue edge E).
- **Ack.** Registered: high for the one clock after E. A requester drops `req`, or puts up its next request, on seeing the ack. The next decision is a clock after the ack, so a requester that puts up a new request at once can have every cycle.
- **Read data.** `rvalid` and the tag come from `sram_ctl.v` in the clock from E + 30 to E + 40 ns; `rvalid_o[k]` is `rvalid` with the tag decoded, combinationally. The requester takes `rdata` at E + 40, 4 clocks after the issue.
- **Writes.** No valid line. The write is done on the pins at E + 25 ns. A requester's reads and writes are done in the order it was given them.

### 4.6 What the plan guarantees

With 20 ns cycles, one owned slot in a plan of S slots is 50/S M words a second: 10 M words a second (20 MB/s) for S = 5.

**Bandwidth.** A requester gets at least its owned slots, less:
- those an urgent request takes, where the slot is not locked;
- those a lower-numbered owner of the same slot takes.

On top of that it gets the spare cycles its place in rule 4 wins. For the plans of 4.2:

| Plan | CPU | Layers and sprites together | Audio | Copper, DMA engine, test port |
|------|-----|-----------------------------|-------|-------------------------------|
| A CPU that can wait | 10 M/s, less urgent fetches | 20 M/s | 10 M/s, less urgent fetches | Spare cycles only |
| A CPU that cannot wait | 20 M/s, never taken | 20 M/s | 10 M/s, less urgent fetches | Spare cycles only |
| A big blit | Spare cycles only | 20 M/s | 10 M/s, less urgent fetches | DMA engine 10 M/s, less urgent fetches |

**Urgent wait.** An urgent request loses a cycle only to an owner of a locked slot that asks, or to an urgent request from a lower number. Let L be the longest run of locked slots in a row (counting round the end of the plan) in any plan the machine may use, and U the number of urgent requests from lower numbers that can be served ahead of it. From the start of the clock in which the urgent request is first high to the edge at which the requester takes its data:

  worst case = 6 + 2L + 2U clocks

That is 1 clock until a decision, 1 for the decision, 2 for each cycle lost, and 4 from the issue to the data. For the numbers of 4.1, the layers have U = 0 and the sprites U = 1 if the layers can be urgent at the same moment. With the first plan of 4.2 (L = 0), that is 6 and 8 clocks; with the second (L = 1), 8 and 10. A requester's urgent mark must be at least this far ahead of its deadline.

**A locked owner's wait.** At most until its next owned slot, if it is the only owner. Counted from the start of the clock in which the request is first high to the issue edge: with one owned slot in 5, 10 clocks; with slots 0 and 2 of 5 (decided 4 and 6 clocks apart), 6. Read data follows 4 clocks after the issue. It may be sooner, by a spare cycle.

**An unlocked owner's wait.** As for a locked owner, plus the cycles urgent requests take. That is bounded only by how often other requesters are urgent. A requester that is urgent often has a plan that gives it too little bandwidth.

**Rule 4 has no bounds.** A requester with a high number gets nothing in rule 4 while lower numbers use every spare cycle.

### 4.7 Reset

`rst` clears the acks at the next edge. The decision is combinational, so `go` still follows the requests during reset; the machine should hold `sram_ctl.v` in reset at the same time, which keeps the cycles idle. The scheduler has no other state.

### 4.8 Implementation

The logic is in three parts, all combinational:

1. **The slot.** A mux picks the owner mask and the lock bit of `next_slot` from the plan.
2. **The winner.** Five masks (locked owners, urgent, owners, high, any), each ANDed with `req`. The lowest set bit of each is `m & (~m + 1)`. A priority choice between the five gives the winner as a one-hot mask.
3. **The cycle.** An AND-OR mux, as the winner is one-hot: each requester's address, data, byte enables and write flag ANDed with its winner bit, then ORed together. The tag is the winner's number.

The longest path is from `next_slot` or a request through the slot mux, the lowest-bit pick and the choice to the address mux. It has a full clock.

Inputs tied to constants fold away: a read-only requester's `we`, `wdata` and `be` tied to 0 cost nothing in the mux, and neither does a constant plan. Resources (Yosys 0.33, `synth_xilinx` for 7-series, the scheduler alone, N = 7 and S = 5 numbered as in 4.1, 4 requesters read-only):

| Build | LUTs | Flip-flops |
|-------|------|------------|
| The Z80 plan as constants, no high bits | 170 | 7 |
| A programmable plan (ports, a register outside), high bits on the copper and DMA engine | 208 | 7 |

Most of it is the 21-bit address and 16-bit data mux. The plan register itself (S×N + S bits, 40 for N = 7, S = 5) is in the machine.

### 4.9 Design notes

- **Generic requesters.** The scheduler has no idea what its requesters are. Everything that made a requester special is now an input the machine drives: its number (priority), its owned slots, and its urgent and high flags.
- **Owners and priority.** A pure priority order lets the requesters at the top starve those at the bottom, and makes CPU timing depend on what the display and DMA engine are doing. Owned slots give each requester a floor that is easy to work out (4.6). Spare cycles go by priority, so nothing is wasted.
- **Several owners in a slot.** One mask per slot lets requesters share a slot (layers and sprites, for example), with the lower number first.
- **Locks.** A requester that cannot be held off must have its slots even when another is urgent. Without a lock, urgent requests may take any slot, which keeps their wait at its least.
- **No deadlines.** The first version compared the layers' and sprites' deadlines to pick between them. The generic version picks by number instead, which needs no comparators. Each requester still uses its own deadline to decide when to raise `urgent`.
- **What changed from the first version.** That version had fixed channels (CPU, layers, sprites, audio, copper, DMA engine, test port), fixed cycle masks as parameters, a `CPU_FIRST` mode, a "nasty" copper level and a HIGH mode in which a DMA engine job took the CPU's cycle but left it 1 in 2, 4 or 8 of them. The plan register replaces the modes: a machine makes the copper or the DMA engine owner of the CPU's slot while the job runs. Both machines agreed to drop the share.

## 5. How a machine uses it

The wrapper (or the machine's top level) must:

- **Choose N and S,** and number its requesters by priority (4.1).
- **Connect `sram_ctl.v`.** Drive `start_next` from it and `rvalid`, `rtag` back from it; give it `go_*`. Give `rdata` from it to every requester. Its tag is 3 bits: with TW under 3, pad `go_tag` with zeros on the way in and take the low TW bits of `rtag` on the way back.
- **Give the slot number** (4.3): `next_cycle` from `sram_ctl.v` for S = 5, or a counter.
- **Give a slot plan.** Drive `slot_owner` and `slot_lock` from a register with the machine's default plan as its reset value, or tie them to constants. Keep any slots a requester cannot do without locked in every plan software may write.
- **Tie off what is unused.** A requester that only reads: `we`, `wdata` and `be` 0. One that is never urgent or high: those bits 0. Leave unused acks and valid lines open. An open `req` bit is X in simulation, and so is every decision.
- **Urgent marks.** A requester with a deadline raises `urgent` early enough for the worst case of 4.6 in every plan the machine uses.
- **Hold each request.** `req`, the address and the write data stay still until the ack. After the ack, drop `req` or put up the next request at once. A `req` left high one clock too long gets a second cycle.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/dmac` | Run for five sizes: N, S = 7, 5 (the machines), 1, 1, 8, 8, 3, 6 and 5, 3. Random requests, urgent and high flags, and a random plan (one owner, several or none per slot, random locks) that changes every few hundred clocks, also mid-round, for 300,000 clocks each. `next_slot` takes every value, past the plan's end too. Every clock: the winner, `go`, the tag, address, write flag, byte enables and data against a model of the rules written separately (each rule as a walk over the requesters); the acks a clock later; the valid lines against `rtag`. Counters make sure each rule came up: a locked owner over an urgent request, an urgent request over an owner, an owner, an owner that is not the lowest number asking, a high request over a lower number, any request, a slot past the plan's end, an idle cycle |
| The machines' system tests | Each machine's copper, sprite, video and CPU tests on its own plans. The bandwidth and deadline checks there are the real test of a plan |

## 7. Open points

| # | Point |
|---|-------|
| D1 | `sram_ctl.v` carries a 3-bit tag, so N is at most 8. More requesters need a wider tag there |
| D2 | `sprite_fetch.v` still gives a deadline (`mem_deadline`). The scheduler no longer uses it; the sprite fetch's urgent flag is what counts |
| D3 | Rule 4 puts all high requests ahead of all others. In the first version a high DMA engine went ahead of the CPU but behind the display and audio. With the numbers of 4.1 a high DMA engine now also goes ahead of the display in spare cycles; the display keeps its owned slots and its urgent requests |
| D4 | The size figures are from Yosys; the machines' Vivado builds are the ones that count |
