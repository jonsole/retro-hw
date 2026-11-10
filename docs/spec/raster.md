# Rasteriser (raster)

Status: **draft**, revision 1 for review. A new core, from the blitter redesign: it replaces the first blitter's LINE and EDGES jobs. `rtl/raster.v` implements it.

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
| Slopes | Worked out inside, by a serial divider: about 35 clocks an edge |
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
| `AW` | 21 | Word address width, 16 to 23, as the blitter's: no range check. The clip window keeps a job inside its bitmap |
| `LE` | 0 | 1: memory is little-endian |
| `TRI` | 1 | 0: lines only; a TRI job is an error, and the triangle logic and divider are left out (about half the core) |

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
| TRI: sort and three slopes | About 110 |
| LINE: each pixel stepped | 1, plus its memory accesses if written |
| TRI: each row | 1, plus one memory access a destination word of the span (two where C is read) |

The job ends as a blitter job does: `done` if `job_irq`, then the next descriptor if `job_next` is not 0, else idle.

### 4.5 The exact result

This is the definition the test model follows. A pixel's place is the bit position 8 × (`job_daddr` + y × `job_dstride`) + x × bits, as in the blitter (4.8), with the same packing.

```
plot(x, y, A):
    if clip_xmin ≤ x ≤ clip_xmax and clip_ymin ≤ y ≤ clip_ymax:
        C = the pixel at (x, y);  B = job_value's low bits
        each bit j:  D[j] = job_minterm[4 × A + 2 × B[j] + C[j]]
        the pixel at (x, y) becomes D

LINE:
    dx = |x1 − x0|;  dy = |y1 − y0|
    sx = +1 if x1 ≥ x0 else −1;  sy = +1 if y1 ≥ y0 else −1
    xmajor = (dx ≥ dy);  major = max(dx, dy);  minor = min(dx, dy)
    err = major div 2;  (x, y) = (x0, y0)
    for i = 0 .. major:
        if not (job_nolast and i = major):
            plot(x, y, job_pattern[15 − (i mod 16)])
        err = err − minor
        if err < 0:
            err = err + major
            step the minor axis (y by sy if xmajor, else x by sx)
        step the major axis (x by sx if xmajor, else y by sy)

TRI:
    sort the points by y:  (xt, yt), (xm, ym), (xb, yb)
    slope(a, b) = floor((xb − xa) × 65536 / (yb − ya))       # only for yb > ya
    for y = yt .. yb − 1:
        XL = xt × 65536 + slope(t, b) × (y − yt)              # the long edge
        XS = xt × 65536 + slope(t, m) × (y − yt)   if y < ym  # the short edge
             xm × 65536 + slope(m, b) × (y − ym)   otherwise
        left = ceil(min(XL, XS) / 65536);  right = ceil(max(XL, XS) / 65536)
        for x = left .. right − 1:  plot(x, y, 1)
```

- A LINE whose two points lie beyond the same side of the window plots nothing; the core skips the stepping, which gives the same result.
- LINE pixels are written one at a time, in the order stepped, so with a minterm that depends on C a pixel visited twice by joined lines is combined twice (hence `job_nolast`).
- TRI pixels are each written once. A span is written a memory word at a time: whole pixels of the word inside the span take D, the others keep their value; bytes with no pixel of the span are not written.
- With two points at the same y the sort's order between them does not change the result.
- Only bytes holding a plotted pixel are ever written.

### 4.6 Worked examples

**A line** from (2, 1) to (9, 4): dx 7, dy 3, x is the longer axis, the error term starts at 3. The pixels, in order:

```
(2,1) (3,1) (4,2) (5,2) (6,3) (7,3) (8,4) (9,4)
```

From (9, 4) to (2, 1) the same pixels come out in the opposite order. This holds for these two points; in general a line and its reverse may differ by a pixel where the error term is exactly on a tie. With `job_pattern` 0xF0F0 the first four pixels have A 1 and the next four A 0; with minterm 0xCA only the first four are drawn.

**A triangle** with points (10, 2), (3, 6), (14, 9), in any order. Sorted: top (10, 2), middle (3, 6), bottom (14, 9). Slopes: long edge 4/7 = 0x0000_9249; top to middle −7/4 = 0xFFFE_4000; middle to bottom 11/3 = 0x0003_AAAA.

| Row y | Pixels x |
|-------|----------|
| 2 | none (both edges at x = 10) |
| 3 | 9 to 10 |
| 4 | 7 to 11 |
| 5 | 5 to 11 |
| 6 | 3 to 12 |
| 7 | 7 to 12 |
| 8 | 11 to 13 |

Row 9, the bottom point's, is not drawn: a triangle below sharing that point or edge draws it.

**Job ports** for that triangle in colour 5 on a 320-wide 8-bit bitmap at 0x10000, drawn over whatever is there: `tri` 1, `minterm` 0xCC, `bpp` 3, `value` 5, the six coordinates, `daddr` 0x10000, `dstride` 320, and the window 0, 319, 0, 199. With minterm 0x66 instead, drawing it twice restores the bitmap.

### 4.7 Sequences

The descriptor load and set-up are the blitter's (4.10). Then:

- **LINE.** About 16 clocks to find the first row's address, then one clock a pixel stepped. A pixel inside the window is one write (after one read, where 4.1 says); the stepping waits for it.
- **TRI.** The sort and the three divides, one after another on the one divider, about 110 clocks. Then each row: one clock to step both edges, and the span's words, one write each (after one read where needed). A row outside the window, or with an empty span, costs its one clock.
- `stop` is taken between pixels (LINE) or rows (TRI).

### 4.8 Errors and reset

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
| R2 | Jon chose triangle points over ready-made slopes, so the core has a divider. A serial one is small but each triangle pays about 110 clocks before its first pixel |
| R3 | The first design's EDGES job (one pixel a row, for a later fill) is gone: TRI fills directly. retro-z80's fast3d demo moves from edges plus a fill to TRI jobs |
| R5 | Both machines reviewed revision 1 at 6793fd9 and agree; the clip window is now stated as the wrapper's shared registers, and the guide note on long lines is in section 5. retro-z80 may build `TRI` 0 on the KS2 at first, for room |
| R6 | Size, Yosys for 7-series: 892 LUTs and 383 flip-flops with lines only, 1,825 and 781 with triangles. Not yet trimmed (Jon: simple first); the triangle half has 34-bit edge arithmetic that could narrow |
| R4 | Filled shapes other than triangles (trapezoids, convex polygons in one job), shading and depth are not in this revision |
