# Geometry engine (geom)

Status: **draft**, revision 1 for review. A new core, from the blitter redesign. No RTL yet.

The geometry engine turns a list of 3D points in memory into screen coordinates: it rotates and translates each point by a matrix, projects it, and writes the result back to memory. The CPU then decides what to draw from the screen points (which faces are visible, in what order) and builds jobs for the rasteriser ([raster](raster.md)). The engine does the arithmetic a small CPU is slow at: nine multiplies and two divides a point.

Like the blitter it has no registers, takes one job at a time with a chain to the next descriptor, and is one requester on the memory scheduler. Its control ports, descriptor load and memory port are the blitter's ([blitter](blitter.md) 2.1, 2.3, 2.4). A machine short of room leaves this core out and lets its CPU do the sums: retro-z80's KS2 does.

## 1. Summary

| Item | Value |
|------|-------|
| Job | N points: read x, y, z; rotate, translate, project; write screen x, screen y and view z |
| Numbers | 16-bit signed fixed point. Matrix entries are 2.14 |
| View | One 3×4 matrix a job (rotation and translation), read from memory |
| Projection | Perspective (divide by z) or none (`job_persp`) |
| Behind the eye | A point nearer than the near plane is marked, not projected |
| Arithmetic | One 16×16 multiplier and one serial divider, shared over the steps |
| Time | About 60 clocks and 6 memory accesses a point |
| Registers | None: the wrapper's |

## 2. Ports

Control, descriptor load and memory port are as the blitter's. `stop` takes effect after the point in hand.

### 2.1 The job

Changed only while idle or in the clocks of `su_v` (8 clocks, at each job's start).

| Name | Dir | Width | Meaning |
|------|-----|-------|---------|
| `su_v`, `su_i` | out | 1, 3 | As the blitter's |
| `job_count` | in | 16 | Points to transform; 0 is an empty job |
| `job_vaddr` | in | 24 | The first point: three words a point, x, y, z, signed |
| `job_oaddr` | in | 24 | The first result: three words a point, screen x, screen y, view z, signed. May be `job_vaddr` (the points are replaced) |
| `job_maddr` | in | 24 | The view block: 16 words (4.1) |
| `job_persp` | in | 1 | 1: perspective. 0: no divide (a rotation only) |
| `job_irq` | in | 1 | Strobe `done` when this job ends |
| `job_next` | in | 24 | The next descriptor's address; 0 for none |
| `job_bad` | in | 1 | The wrapper rejects the job |

All addresses are even byte addresses; words are 16 bits in the machine's byte order (`LE`).

## 3. Parameters

| Name | Default | Meaning |
|------|---------|---------|
| `AW` | 21 | Word address width, as the blitter's |
| `LE` | 0 | 1: memory is little-endian |

## 4. Behaviour

### 4.1 The view block

Sixteen words at `job_maddr`, read once at the start of each job:

| Words | Meaning |
|-------|---------|
| 0–8 | The rotation matrix, row by row: m00, m01, m02, m10, … m22. Signed 2.14: 0x4000 is 1.0 |
| 9–11 | The translation tx, ty, tz, signed, in the points' units |
| 12 | d: the distance from the eye to the screen, unsigned |
| 13, 14 | cx, cy: the screen position of the view's centre, signed |
| 15 | znear: the near plane, signed; points with view z below it are not projected |

### 4.2 A point

For a point (x, y, z):

1. **View.** vx = sat16(((m00·x + m01·y + m02·z) >> 14) + tx), and likewise vy and vz from the matrix's second and third rows with ty and tz. The three products are summed in full (34 bits) before the shift, which is arithmetic (it rounds down); sat16 limits the result to −32768 … 32767.
2. **Projection**, with `job_persp`: if vz < znear, the point is behind: screen x and screen y are both written as 0x8000. Otherwise sx = satp(cx + floor((vx·d) / vz)) and sy = satp(cy + floor((vy·d) / vz)): the divide rounds down, so a point crossing the screen's centre steps evenly, and satp limits the result to −32767 … 32767. znear must be at least 1.
3. Without `job_persp`: sx = satp(cx + vx), sy = satp(cy + vy), and nothing is marked behind.
4. **Result.** Three words are written: sx, sy, vz.

Screen y grows downwards if the matrix says so: the engine does not flip any axis. A projected screen x or y is never 0x8000 (−32768), so that value in either word always means behind, and software tests one word.

### 4.3 A job, and its time

| Step | Clocks |
|------|--------|
| Descriptor load (`start_ld`, or a chain) | 16 word reads |
| Set-up (`su_v`) | 8 |
| The view block | 16 word reads |
| Each point | 3 reads, about 9 clocks of multiplies, with `job_persp` 2 more multiplies and 2 divides of about 20 clocks each, then 3 writes |

The job ends as a blitter job does: `done` if `job_irq`, then the next descriptor if `job_next` is not 0, else idle. A chain of jobs with different view blocks transforms several objects with no CPU in between.

### 4.4 The exact result

This is the definition the test model follows. Words are signed 16-bit unless said; `>>` is an arithmetic shift (it rounds down); floor division rounds down.

```
sat16(v) = max(−32768, min(32767, v))        satp(v) = max(−32767, min(32767, v))

read the view block:  m[0..8], tx, ty, tz, d (unsigned), cx, cy, znear
for n = 0 .. job_count − 1:
    x, y, z = the words at job_vaddr + 6n, + 6n + 2, + 6n + 4
    vx = sat16(((m[0]·x + m[1]·y + m[2]·z) >> 14) + tx)      # the sum is 34 bits, kept whole
    vy = sat16(((m[3]·x + m[4]·y + m[5]·z) >> 14) + ty)
    vz = sat16(((m[6]·x + m[7]·y + m[8]·z) >> 14) + tz)
    if job_persp and vz < znear:
        sx = sy = −32768                                     # 0x8000: behind
    else if job_persp:
        sx = satp(cx + floor((vx · d) / vz))                 # the product is 33 bits, the
        sy = satp(cy + floor((vy · d) / vz))                 # quotient kept whole until satp
    else:
        sx = satp(cx + vx);  sy = satp(cy + vy)
    write sx, sy, vz to job_oaddr + 6n, + 6n + 2, + 6n + 4
```

- A point's three words are all read before any of its results is written, so results may overwrite the points (`job_oaddr` = `job_vaddr`). Results written elsewhere must not overlap points still to be read.
- The view block is read once, before the first point; changing it in memory during a job has no effect on that job.
- With znear below 1 a divide by zero or a negative vz can be asked for: the result is then not specified. The wrapper may reject it with `job_bad`.

### 4.5 A worked example

A view turned 30° about the y axis, 400 units in front of the eye, on a 320×200 screen with the eye 256 units from it. cos 30° is 0x376D and sin 30° 0x2000 in 2.14.

| View block words | Values |
|------------------|--------|
| 0–8 (matrix rows) | 0x376D, 0, 0x2000; 0, 0x4000, 0; 0xE000, 0, 0x376D |
| 9–11 (tx, ty, tz) | 0, 0, 400 |
| 12 (d) | 256 |
| 13, 14 (cx, cy) | 160, 100 |
| 15 (znear) | 16 |

| Point (x, y, z) | View (vx, vy, vz) | Written (sx, sy, vz) |
|-----------------|-------------------|----------------------|
| (100, −50, 200) | (186, −50, 523) | (251, 75, 523) |
| (−100, 50, −200) | (−187, 50, 276) | (−14, 146, 276) |
| (0, 0, −390) | (−195, 0, 62) | (−646, 100, 62) |
| (0, 0, −460) | (−230, 0, 1) | (0x8000, 0x8000, 1): behind |

For the first point: vx = ((14189 × 100 + 8192 × 200) >> 14) = 186; sx = 160 + floor(186 × 256 / 523) = 160 + 91 = 251; sy = 100 + floor(−50 × 256 / 523) = 100 − 25 = 75 (the divide rounds down, from −24.47). The third point is in front of the near plane but far off the left of the screen: the rasteriser's window clips what is drawn from it.

### 4.6 Sequence

After the descriptor load and set-up (the blitter's 4.10), the 16 words of the view block are read in rising order. Then, for each point: three reads; the nine products, one a clock, summed a row at a time; with `job_persp` the near test, two more products and the two divides one after the other; then three writes. The core asks for the next point's reads as soon as this point's writes are taken. `stop` is taken between points.

### 4.7 Errors and reset

`job_bad` ends the job and the chain with `err` set, as in the blitter (4.6). Reset is the blitter's.

## 5. How a machine uses it

- A wrapper as for the blitter: job registers, descriptor store, start and stop strobes.
- One requester on `dmac.v`.
- One DSP block (a 16×16 signed multiply) on an FPGA that has them.
- Software keeps each object's points in memory once, writes a view block per object per frame, runs the job, then reads the screen points to cull, sort and build `raster` jobs.

## 6. Test plan

| Test | What it checks |
|------|----------------|
| `test/geom`, random | The core against a bit-exact model of 4.2: random points, matrices and view blocks, both `job_persp` settings, values that saturate, points behind and just in front of the near plane, results written over the points, chains, both byte orders. Every memory write is compared |
| `test/geom`, directed | The identity matrix; a 90° rotation; negative and positive quotients with a remainder, to check the divide rounds down; results at the limits ±32767; count 0; stop mid-job; the error |
| `drivers.sh`, the machines | As for the blitter. retro-z80's KS2 does not build this core |

## 7. Open points

| # | Point |
|---|-------|
| G1 | Choices made in this draft, for review: the view block in memory rather than on ports; three words out a point (screen x, screen y, view z); 0x8000 marks a point behind the near plane; the divide rounds down; no axis is flipped; one view block a job |
| G2 | 16-bit fixed point was chosen for size. A world larger than ±32767 units, or a need for sub-pixel screen positions, would be a later revision |
| G4 | Both machines reviewed revision 1 at 6793fd9. retro-z80's two changes are in: projected values saturate to ±32767 so 0x8000 only ever means behind, and the divide rounds down, matching its own register-driven geometry unit so both give the same screen points |
| G3 | Not in this revision: clipping lines and triangles at the near plane (the CPU does it, from view z), back-face tests, lighting, and driving the rasteriser directly |
