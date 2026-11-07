# Wiring the timebase

`timebase` is two counters on the 100 MHz system clock. `sc` says which edge of the 100 ns slot the current clock started on (0–9); the memory system runs from it. `ph` says the same within 50 ns (0–4), for a CPU on a 40 MHz clock. The spec is `docs/spec/timebase.md`.

## Instantiation

```verilog
wire [3:0] sc;
timebase tb0 (.clk(clk), .rst(por), .ph(), .sc(sc));   // no 40 MHz CPU: ph left open
```

With a 40 MHz CPU clock from the same MMCM:

```verilog
wire [2:0] ph;
wire [3:0] sc;
timebase tb0 (.clk(clk), .rst(por), .ph(ph), .sc(sc));
```

Give `sc` to `sram_ctl.v`, and to the logic that lines the CPU's bus cycles up with the memory cycles.

## Timing

One column per clock:

```
 por      1   1   0   0   0   0   0   0   0   0   0   0   0   0
 sc       .   0   0   1   2   3   4   5   6   7   8   9   0   1
 ph       .   0   0   1   2   3   4   0   1   2   3   4   0   1
```

The third clock, the first after the last edge that saw `por` high, is the first clock of a slot.

Memory cycle n is the two clocks with sc 2n and 2n + 1: cycle 0 is sc 0–1, cycle 4 is sc 8–9.

## Pitfalls

- **Power-on reset only.** A soft reset, a watchdog reset or a debugger reset must not reset the timebase: the SRAM controller would lose its place in a cycle.
- **End reset on a slot boundary.** If another clock relies on the grid (a 40 MHz CPU clock), the last edge with `rst` high must be one where that clock also has an edge at the start of a slot. With one clock only, any edge will do.
- **Clocks per cycle.** A cycle is two clocks, and a new one starts after odd sc. Logic that counts on its own instead of reading `sc` drifts off the grid after a reset.
