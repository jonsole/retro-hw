---
status: accepted
---

# The settings are registered at the core's input, with `set_sel` one sprite ahead

retro-z80's KS2 critical path (slack +0.015 ns) ran from the core's sprite counter, with a fanout of 222, through the wrapper's settings RAM into the first stage of the size calculator (the `lim` and `mag` carry chain into `wsh`), two thirds of it routing. The core now registers the `set_` inputs and works on them in the next clock, asking for sprite n + 1 while it works on sprite n, so the wrapper's RAM read gets a whole clock and every write still lands in the same clock as before. The one visible effect: a settings write that lands in the very clock its sprite is handed over is seen at the sprite's next visit, 8 clocks later or the next line, which no software writing in the blank can notice. Cost: 84 flip-flops.

## Considered Options

- Register the read in each machine's wrapper instead: it would have to run its own address one ahead and both machines would do the same work; in the core it is done once and the interface stays "settings for `set_sel` in the same clock".
- Split the calculator's first stage: it shortens the core's part of the path but leaves the RAM read and the long net on it.
