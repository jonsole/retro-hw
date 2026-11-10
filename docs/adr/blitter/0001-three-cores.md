---
status: accepted
---

# One blitter becomes three cores

The first blitter (`dmx_core`, from both machines' `dmx.v`) did rectangle blits, ADD, lines, polygon edges, FIFO jobs and register loads through a second port, on four channels sharing one datapath. It was about 3,200 LUTs in retro-z80's KS2 build, held that machine's ten worst timing paths, and with it the KS2's full build no longer fitted. Jon judged it too complicated and trying to do too much, and chose a redesign over trimming. An inventory of both machines showed real software uses three minterms, one channel at a time, chains, key-colour cut-outs, a backwards copy, lines and edges; ADD, priority, interrupts, timer starts and the other channels were used by tests only. So it splits by kind of work: `blitter` for rectangles of pixels, `raster` for lines and filled triangles, `geom` for transforming 3D points. Each is a separate requester on the scheduler and a machine builds only what it needs. The FIFO mover retro68k wants is decided later; the second port is dropped.
