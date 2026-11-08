# DMA scheduler (dmac)

Status: **draft**

The scheduler decides who gets each 20 ns memory cycle of the shared SRAM, as the Amiga's Agnus does. Seven channels ask for cycles; the scheduler picks one per cycle by a fixed set of rules and hands it to the SRAM controller (`sram_ctl.v`). It has no registers. Which cycles belong to whom is set by parameters, so each machine chooses its own slot plan.

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
| Registers | None |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock, 100 MHz | – |
| `rst` | in | 1 | Reset: acks low, the HIGH share counter cleared | Synchronous |
| `start_next` | in | 1 | A memory cycle starts at the next edge | From `sram_ctl.v`, every other clock |
| `next_cycle` | in | 3 | Its number in the slot, 0–4 | With `start_next` |
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
| `cop_pri` | in | 2 | The copper's priority: 0 normal, 1 high, 2 nasty (with `NASTY`; else high), 3 high | With `cop_req` |
| `blt_req`, `blt_we`, `blt_addr`, `blt_wdata`, `blt_be`, `blt_ack`, `blt_rvalid` | | | DMA engine reads and writes, as for the CPU | |
| `blt_high` | in | 1 | With `HIGH`: the DMA engine's job may take the CPU's cycle | With `blt_req` |
| `blt_share` | in | 2 | With `HIGH`: the CPU keeps 1 in 2 (0), 4 (1) or 8 (2, 3) of the cycles both want | Held through the job |
| `port_req`, `port_we`, `port_addr`, `port_wdata`, `port_be`, `port_ack`, `port_rvalid` | | | The test port, as for the CPU | |
| `go` | out | 1 | A cycle starts at the next edge | Combinational, in the clock of `start_next` |
| `go_we`, `go_addr`, `go_wdata`, `go_be` | out | 1, 21, 16, 2 | The winner's cycle. Read-only channels give `go_we` 0 and `go_be` 11 | With `go` |
| `go_tag` | out | 3 | The winner: 1 CPU, 2 BPL, 3 SPR, 4 AUD, 5 COP, 6 BLT, 7 PORT; 0 none | With `go` |
| `rvalid`, `rtag` | in | 1, 3 | Read data back from `sram_ctl.v`, and whose it is | – |

The read data itself (`rdata`) goes from `sram_ctl.v` to every channel directly. Only the valid lines pass through the scheduler.

## 3. Parameters

| Name | Width | Default | Meaning | For example |
|------|-------|---------|---------|-------------|
| `CPU_CYCLES` | 5 | `00001` | The CPU's own cycles (bit n for cycle n) | A CPU with a 4-clock bus cycle: `00001`. A CPU that must never wait, at 2 accesses a slot: `00101` |
| `HARD_CYCLES` | 5 | `01010` | The hard-deadline channels' cycles | `01010` (cycles 1 and 3) in both machines so far |
| `AUD_CYCLES` | 5 | `00100` | Audio's cycles | `00100`, or `10000` where the CPU has cycle 2 |
| `CPU_FIRST` | 1 | 0 | 1: a CPU request in its own cycle beats every other rule | 1 for a CPU that cannot be held off |
| `NASTY` | 1 | 1 | 1: the copper at priority 2 beats everything but urgent requests | 0 for a machine without a nasty copper |
| `HIGH` | 1 | 1 | 1: `blt_high` and `blt_share` act | 0 where the DMA engine never takes the CPU's cycles |

The masks should not overlap. If they do, the order of rule 2 below decides (CPU, then hard-deadline, then audio).

## 4. Behaviour

### 4.1 The rules

For each cycle, the first rule that finds a request wins:

| Rule | Who | When |
|------|-----|------|
| 0 | CPU | With `CPU_FIRST`, in a CPU cycle, if `cpu_req` |
| 1 | The urgent hard-deadline channel, earliest deadline first (layers on a tie) | Any cycle, if `bpl_urgent` or `spr_urgent` with its request |
| 1 | COP | With `NASTY`, if `cop_req` and `cop_pri` = 2 |
| 2 | CPU, or BLT in its place (4.2) | In a CPU cycle, if `cpu_req` |
| 2 | The hard-deadline channel due first | In a `HARD_CYCLES` cycle, if `bpl_req` or `spr_req` |
| 2 | AUD | In an `AUD_CYCLES` cycle, if `aud_req` |
| 3 | The free order: COP at priority 1–3, the hard-deadline channel due first, AUD, COP, BLT, PORT | Any cycle nobody above took |

"Due first" compares `bpl_deadline` and `spr_deadline`: the smaller wins, the layers on a tie. Among urgent requests the same holds. Cycles 5–7 do not exist (`next_cycle` is 0–4); if one came, it would go by rule 3.

So no cycle is wasted: a cycle its owner does not use goes to the free order.

### 4.2 The HIGH share

With `HIGH`, a DMA engine job with `blt_high` takes the CPU's cycle from the CPU at rule 2, except every 2nd, 4th or 8th time (by `blt_share`). A 3-bit counter counts the cycles both wanted. It moves on only in cycles that reached rule 2 (no urgent request, no nasty copper) with `cpu_req`, `blt_req` and `blt_high` all high. On the CPU's turn the CPU gets the cycle and the counter goes back to 0. Reset clears it.

With `CPU_FIRST`, rule 0 gives the CPU its cycles first, so HIGH never wins: leave `HIGH` at 0.

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
- Give the layer and sprite channels a deadline in system clocks and an urgent flag. The urgent mark is the channel's own: it must leave enough time for the cycles the urgent request may have to wait. With `CPU_FIRST` an urgent request can still wait for the CPU's cycles, so the mark must be earlier.
- Drive `cop_pri` from the copper's priority setting, and `blt_high`, `blt_share` from the DMA engine's current job (or 0).
- Hold each request, with its address and data, until its ack.
- Set the parameters for its own slot plan. A CPU that can be held off (its bus waits for an ack) can use the defaults. A CPU that cannot wait needs `CPU_FIRST` and its own cycles in `CPU_CYCLES`.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/dmac` | Two schedulers side by side on the same random requests: the defaults, and a plan with `CPU_CYCLES` `00101`, `AUD_CYCLES` `10000`, `CPU_FIRST`, no `NASTY`, no `HIGH`. Every clock: the winner, `go`, the address, write flag, byte enables and data against a model of each plan's rules; the acks a clock later; the valid lines against `rtag`. Counters make sure the cases that tell the plans apart came up: an urgent request over the CPU, the CPU over an urgent request, the nasty copper, a HIGH job and the CPU's turn, audio in its cycle |
| The machines' system tests | Each machine's copper, sprite, video and CPU tests run on its own plan: the bandwidth and deadline checks there are the real test of the plan |

## 7. Open points

| # | Point |
|---|-------|
| D1 | A mask for the copper's own cycles (both machines give the copper only free cycles and priority now) |
| D2 | `HIGH` with `CPU_FIRST`: should a HIGH job be able to take a CPU cycle the CPU does not want next? Today it gets it by the free order anyway |
| D3 | More channels (a second DMA engine, a disk) would need a wider tag than `sram_ctl.v` carries now |
