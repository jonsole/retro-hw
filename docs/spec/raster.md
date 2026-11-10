# Rasteriser (raster)

Status: **draft**, revision 1 for review. A new core, from the blitter redesign: it replaces the first blitter's LINE and EDGES jobs. No RTL yet.

The rasteriser draws lines and flat-filled triangles into a bitmap in memory, from screen coordinates. A triangle is filled directly, a row at a time, so there is no separate edge pass and fill job. Each pixel is written through the blitter's minterm rule with a constant colour, and clipped to a window. The CPU, or the geometry engine ([geom](geom.md)), supplies the screen coordinates.

Like the blitter it has no registers, takes one job at a time with a chain to the next descriptor, and is one requester on the memory scheduler. Its control ports, descriptor load and memory port are the blitter's ([blitter](blitter.md) 2.1, 2.3, 2.4).

## 1. Summary

| Item | Value |
|------|-------|
| Jobs | LINE: a line between two points. TRI: a filled triangle |
| Coordinates | Signed 16-bit pixels, x to the right, y down. A pixel is addressed by its top-left corner |
| Pixel depths | 1, 2, 4 and 8 bits |
| Colour | A constant, through D = minterm(A, B, C): B the colour, C the old pixel, A a 16-bit pattern along a line (all ones in a triangle) |
| Clipping | A window, inclusive, per job |
| Slopes | Worked out inside, by a serial divider: about 20 clocks an edge |
| Memory | One word port. Reads only where the result needs the old contents |
| Registers | None: the wrapper's |

## 2. Ports

Control (`clk`, `rst`, `enable`, `start_ld`, `start_run`, `stop`, `da_we`, `da_d`, `da_q`, `busy`, `done`, `err`), the descriptor load (`dl_`) and the memory port (`mem_`) are as the blitter's. `stop` takes effect after the row or pixel in hand.

### 2.1 The job

Changed only while idle or in the clocks of `su_v` (8 clocks, `su_i` 0 to 7, at each job's start).

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `su_v`, `su_i` | out | 1, 3 | As the blitter's |
| `job_tri` | in | 1 | 0 LINE, 1 TRI |
| `job_minterm` | in | 8 | As the blitter's |
| `job_bpp` | in | 2 | Log2 of the bits per pixel |
| `job_value` | in | 8 | The colour, in its low `bpp` bits: B for every pixel |
| `job_pattern` | in | 16 | LINE: A for each pixel in turn, from bit 15, going round. All ones for a solid line |
| `job_nolast` | in | 1 | LINE: the last pixel (at point 1) is not drawn, so joined lines don't draw a corner twice |
| `job_irq` | in | 1 | Strobe `done` when this job ends |
| `job_x0`, `job_y0`, `job_x1`, `job_y1` | in | 16 each | Points 0 and 1, signed |
| `job_x2`, `job_y2` | in | 16 each | TRI: point 2 |
| `job_daddr` | in | 24 | The byte holding pixel (0, 0) of the bitmap |
| `job_dstride` | in | 16 | Signed bytes from one row of the bitmap to the next |
| `clip_xmin`, `clip_xmax`, `clip_ymin`, `clip_ymax` | in | 16 each | The window, signed, inclusive. Only pixels inside are written. These are the wrapper's own registers, shared by every job: they are not part of a descriptor, which has no room for them. Held while busy |
| `job_next` | in | 24 | The next descriptor's address; 0 for none |
| `job_bad` | in | 1 | The wrapper rejects the job |

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `AW` | 21 | Word address width, as the blitter's: no range check. The clip window keeps a job inside its bitmap |
| `LE` | 0 | 1: memory is little-endian |
| `TRI` | 1 | 0: lines only; a TRI job is an error, and the divider is left out |

## 4. Behaviour

### 4.1 A pixel

Pixel (x, y) is in the row that starts at byte `job_daddr` + y × `job_dstride`, packed as in the blitter (4.1). It is written as minterm(A, B, C) with B the colour, only if it is inside the clip window. The old word is read first when the minterm depends on C, or when the write covers only part of a byte (depths under 8 bits).

### 4.2 LINE

The pixels of the line from point 0 to point 1 are those of Bresenham's algorithm, stepping one pixel along the longer axis each time, starting at point 0 with the error term at half the longer length (rounded down). Both ends are drawn, unless `job_nolast` leaves out point 1. The same two points give the same pixels whatever the clip window is.

- A line with both ends beyond the same side of the window is skipped whole.
- Otherwise every pixel is stepped, one a clock, and those inside the window are written, one memory write each (and a read where 4.1 says).
- The pattern moves on one bit for every pixel stepped, written or not.

### 4.3 TRI

The triangle's points may be given in any order. The core sorts them by y (top, middle, bottom), divides for the three slopes, and fills row by row.

| Rule | |
|------|--|
| Rows | From the top point's y up to, not including, the bottom point's y |
| An edge from (xa, ya) down to (xb, yb) | Its slope is s = floor((xb − xa) × 2^16 / (yb − ya)), and its x in row y is X = xa × 2^16 + s × (y − ya), a signed fixed-point number with 16 fraction bits |
| A row's span | Between the long edge (top to bottom) and the short edge for that row (top to middle above the middle point's y, middle to bottom from it): from the smaller X to the larger. Its pixels are those with ceil(X_left / 2^16) ≤ x < ceil(X_right / 2^16) |
| Clipping | Rows outside the window are stepped without writing; a span is cut to the window's x range |

So two triangles that share an edge fill every pixel along it exactly once, a triangle with no area draws nothing, and the result does not depend on the order of the points. A row's span is written word by word: whole bytes inside the span need no read unless the minterm depends on C.

### 4.4 A job, and its time

| Step | Clocks |
|------|--------|
| Descriptor load (`start_ld`, or a chain) | 16 word reads |
| Set-up (`su_v`) | 8 |
| The first row's address (y × stride) | About 16 |
| TRI: sort and three slopes | About 70 |
| LINE: each pixel stepped | 1, plus its memory accesses if written |
| TRI: each row | 1, plus one memory access a destination word of the span (two where C is read) |

The job ends as a blitter job does: `done` if `job_irq`, then the next descriptor if `job_next` is not 0, else idle.

### 4.5 Errors and reset

`job_bad`, or a TRI job without `TRI`, ends the job and the chain with `err` set, as in the blitter (4.6). Reset is the blitter's.

## 5. How a machine uses it

- A wrapper as for the blitter: job registers, descriptor store, start and stop strobes, and the clip window's registers.
- Software clips long lines roughly before handing them over: every pixel is stepped, so an end near ±32767 costs up to 64,000 clocks.
- One requester on `dmac.v`.
- The CPU supplies screen coordinates, or `geom` writes them to memory for the CPU to build jobs from.
- A triangle fan or a convex polygon is a chain of TRI jobs.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/raster`, random | The core against a pixel-exact model of 4.2 and 4.3: random lines and triangles at every depth, with points inside and far outside random windows, every minterm, patterns, `job_nolast`, both stride signs, chains. Every memory write and the final bitmap are compared, and that nothing outside the window is written |
| `test/raster`, properties | Two triangles sharing an edge cover each pixel once (XOR leaves no seam and no gap); a triangle's pixels are the same for all six orders of its points; a clipped line's pixels are a subset of the unclipped line's |
| `test/raster`, directed | Horizontal, vertical and diagonal lines; one-pixel and zero-area triangles; spans within one word; stop mid-job; each error; `TRI` 0 |
| `drivers.sh`, the machines | As for the blitter |

## 7. Open points

| # | Point |
|---|-------|
| R1 | Choices made in this draft, for review: coordinates are whole pixels (no sub-pixel bits); the fill rule (top-left, 16 fraction bits, floor slopes); lines step every pixel even off-window (the first design did the same); `job_nolast`; `job_daddr` names pixel (0, 0) and the core multiplies y by the stride |
| R2 | Jon chose triangle points over ready-made slopes, so the core has a divider. A serial one is small but each triangle pays about 70 clocks before its first pixel |
| R3 | The first design's EDGES job (one pixel a row, for a later fill) is gone: TRI fills directly. retro-z80's fast3d demo moves from edges plus a fill to TRI jobs |
| R5 | Both machines reviewed revision 1 at 6793fd9 and agree; the clip window is now stated as the wrapper's shared registers, and the guide note on long lines is in section 5. retro-z80 may build `TRI` 0 on the KS2 at first, for room |
| R4 | Filled shapes other than triangles (trapezoids, convex polygons in one job), shading and depth are not in this revision |
