# DMA scheduler (dmac)

Status: **draft**

The scheduler decides who gets each 20 ns memory cycle of the shared SRAM, as the Amiga's Agnus does. Seven channels ask for cycles; the scheduler picks one per cycle by a short set of rules and hands it to the SRAM controller (`sram_ctl.v`). It has no registers. Which cycles belong to whom comes in on two ports, the slot table: the machine holds it in its own registers, so software can change the slot plan at any time.

## 1. Summary

| Item | Value |
|------|-------|
| File | `rtl/dmac.v`, module `dmac` |
| Clock | One: the 100 MHz system clock |
| Memory cycle | 20 ns (2 clocks); 5 cycles (0–4) in a 100 ns slot |
| Channels | CPU, BPL (layers), SPR (sprites), AUD (audio), COP (copper), BLT (DMA engine), PORT (test port) |
| Hard-deadline channels | BPL and SPR: each gives a deadline and an urgent flag |
| Decision | Combinational, in the clock before the cycle starts |
| Ack | 1 clock, registered: the clock after the decision |
| Read data | Back from `sram_ctl.v` with a tag; the scheduler decodes the tag into a valid line per channel |
| Slot plan | An owner for each of the 5 cycles, and which of them are locked against urgent requests: ports, so programmable |
| Registers | None (the acks only) |

## 2. Ports

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

None. The slot plan is the `slot_owner` and `slot_lock` ports.

## 4. Behaviour

### 4.1 The rules

For each cycle, the first rule that finds a request wins:

| Rule | Who | When |
|------|-----|------|
| 1 | The cycle's owner | In a locked cycle (`slot_lock`), if the owner asks |
| 2 | The urgent hard-deadline channel, earliest deadline first (layers on a tie) | Any cycle, if `bpl_urgent` or `spr_urgent` with its request |
| 3 | The cycle's owner | If the owner asks |
| 4 | The free order: COP with `cop_high`, the display, AUD, COP, BLT with `blt_high`, CPU, BLT, PORT | Any cycle nobody above took |

"The display" is the hard-deadline channel due first: `bpl_deadline` and `spr_deadline` are compared, the smaller wins, the layers on a tie. An owner of BPL or SPR means the display, so either one can use the display's cycles. Among urgent requests the same order holds. Cycles 5–7 do not exist (`next_cycle` is 0–4); if one came, it would have no owner and go by rule 4.

So no cycle is wasted: a cycle its owner does not use goes to the free order. The CPU is in the free order too, so it gets spare cycles beyond its own unless a `blt_high` job wants them.

### 4.2 Changing the plan

`slot_owner` and `slot_lock` are read in each clock with `start_next`, for that one cycle. A change takes effect from the next cycle decided; a cycle already given is not affected, and a change in mid-slot is fine. Each channel's req/ack handshake is the same whatever the plan, so a channel never sees the change except in how soon its ack comes.

For example (the codes are those of `go_tag`):

| Plan | Cycles 0, 1, 2, 3, 4 | `slot_lock` | Use |
|------|-------|------|-----|
| A CPU that can wait | CPU, BPL, AUD, BPL, none | `00000` | The 68000 machine: an urgent display fetch may take the CPU's cycle |
| A CPU that cannot wait | CPU, BPL, CPU, BPL, AUD | `00101` | The Z80 machine: the CPU's cycles are its own, whatever else asks |
| A big blit | BLT, BPL, AUD, BPL, none | `00000` | The DMA engine takes the CPU's cycle (as the Amiga's "blitter nasty"); the CPU gets only spare cycles |
| The copper first | COP, BPL, AUD, BPL, none | `00000` | A copper list that must not wait for the CPU |

Software can switch between plans like these, for example a big-blit plan for the length of a blit.

### 4.3 Timing

One column per clock:

```
 sc (timebase)    8    9    0    1    2    3
 start_next       0    1    0    1    0    1
 next_cycle       .    0    .    1    .    2
 go_tag           .  CPU    .  BPL    .    .     combinational, in this clock
 cpu_ack          0    0    1    0    0    0
 bpl_ack          0    0    0    0    1    0
```

- The decision is combinational from the requests and `start_next`, `next_cycle`. `go` and the cycle's address, data and tag are valid in the clock where `start_next` is high, and `sram_ctl.v` takes them at the next edge.
- The ack is registered: it is high for the one clock after that edge. A channel drops `req` (or puts up its next request) on seeing the ack, so a request is never given twice.
- Read data comes back from `sram_ctl.v` with `rvalid` and the tag high for one clock, the clock that starts 30 ns after the cycle's first edge (so the data is there by 40 ns). `x_rvalid` is `rvalid` and the tag decoded: combinational.

## 5. How a machine uses it

The wrapper (or the machine's top level) must:

- Drive `start_next` and `next_cycle` from `sram_ctl.v`, and `rvalid`, `rtag` back from it; give `go_*` to it.
- Tie off every channel it does not have: `req` 0, the other inputs to any constant. Leave the unused acks and valid lines open.
- Give the layer and sprite channels a deadline in system clocks and an urgent flag. The urgent mark is the channel's own: it must leave enough time for the cycles the urgent request may have to wait. An urgent request still waits for locked cycles, so with locks the mark must be earlier.
- Hold the slot plan (`slot_owner`, `slot_lock`) in a register, with the machine's own plan as its reset value, or tie it to a constant if the plan never changes.
- Drive `cop_high` from the copper's priority setting, and `blt_high` from the DMA engine's current job (or 0).
- Hold each request, with its address and data, until its ack.
- Choose its slot plan. A CPU that can be held off (its bus waits for an ack) needs no lock. A CPU that cannot wait needs the cycles its bus cycle lines up with, locked. Software that changes the plan must keep those cycles for such a CPU.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/dmac` | Random requests and a random slot plan that changes every few hundred clocks, also in mid-slot. Every clock: the winner, `go`, the address, write flag, byte enables and data against a model of the rules; the acks a clock later; the valid lines against `rtag`. Counters make sure every rule came up: a locked owner over an urgent request, an urgent request over an owner, an owner, the display owner giving the cycle to the sprites, the CPU in a spare cycle, a `blt_high` job over the CPU, a `cop_high` copper over the display, the port, a cycle with no owner |
| The machines' system tests | Each machine's copper, sprite, video and CPU tests run on its own plan: the bandwidth and deadline checks there are the real test of the plan |

## 7. Open points

| # | Point |
|---|-------|
| D1 | The old share mode (a HIGH DMA engine job leaving the CPU 1 in 2, 4 or 8 of its cycles) is gone. A machine that needs it can switch the CPU's cycle between CPU and BLT in its plan register |
| D2 | More channels (a second DMA engine, a disk) would need a wider tag than `sram_ctl.v` carries now, and a wider owner field |
