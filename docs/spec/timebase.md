# Timebase (timebase)

Status: **draft**

The timebase tells the 100 MHz side where it is on the 100 ns slot grid of the memory system. `sc` counts the system clock edges within a slot; the SRAM controller, the scheduler and the CPU's bus interface all work from it. `ph` counts the edges within 50 ns, for a CPU on a 40 MHz clock whose edges line up with the 100 MHz ones every 50 ns.

## 1. Summary

| Item | Value |
|------|-------|
| File | `rtl/timebase.v`, module `timebase` |
| Clock | One: the 100 MHz system clock |
| `sc` | 0–9: the edge within the 100 ns slot. Memory cycle n is sc 2n and 2n + 1 |
| `ph` | 0–4: the edge within 50 ns |
| Reset | Power-on only; both counters 0 |
| Registers | None |

## 2. Ports

| Name | Dir | Width | Meaning | Timing |
|------|-----|-------|---------|--------|
| `clk` | in | 1 | System clock, 100 MHz | – |
| `rst` | in | 1 | Power-on reset. The last edge that sees it high must be a slot boundary | Synchronous |
| `sc` | out | 4 | Which edge started the current clock, 0–9 within the slot | Registered |
| `ph` | out | 3 | Which edge started the current clock, 0–4 within 50 ns | Registered |

## 3. Parameters

None. A machine that does not use `ph` leaves it unconnected; synthesis removes its three flip-flops.

## 4. Behaviour

- While `rst` is high, `sc` and `ph` are 0 after each edge.
- After that, each edge moves `sc` on by 1, from 9 back to 0, and `ph` by 1, from 4 back to 0.
- So in the first clock after the last edge with `rst` high, both are 0: that clock is the first of a slot.

One column per clock (the value during that clock):

```
 rst      1   1   0   0   0   0   0   0   0   0   0   0   0   0
 sc       .   0   0   1   2   3   4   5   6   7   8   9   0   1
 ph       .   0   0   1   2   3   4   0   1   2   3   4   0   1
```

`ph` is 0 at sc 0 and sc 5, the two points in a slot where a 40 MHz clock from the same MMCM has a rising edge together with the 100 MHz clock.

## 5. How a machine uses it

- Drive `rst` from the power-on reset only. Any later reset must leave the timebase running, or a memory cycle in progress loses its place.
- The power-on reset must end on a slot boundary of any other clock that relies on the grid (for example a 40 MHz CPU clock from the same MMCM): release it from logic that knows where that boundary is, or have nothing else rely on it.
- Give `sc` to `sram_ctl.v` (which makes `start_next` and `next_cycle` from it) and to whatever times the CPU's bus against the slots.
- Use `ph` only for a CPU clock at 40 MHz lined up as above.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/timebase` | Both counters 0 in reset; 95 clocks after reset against `n mod 10` and `n mod 5`; a reset in the middle of a slot starts both again from 0 |
| The machines' system tests | Every memory test runs on the slot grid from `sc` |

## 7. Open points

| # | Point |
|---|-------|
| T1 | A CPU clock other than 40 MHz (or none) needs its own phase counter; `ph` could become a parameter then |
