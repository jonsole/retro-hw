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
2. **Projection**, with `job_persp`: if vz < znear, the point is behind: screen x and screen y are both written as 0x8000. Otherwise sx = sat16(cx + (vx·d) / vz) and sy = sat16(cy + (vy·d) / vz), the divide rounding towards zero. znear must be at least 1.
3. Without `job_persp`: sx = sat16(cx + vx), sy = sat16(cy + vy), and nothing is marked behind.
4. **Result.** Three words are written: sx, sy, vz.

Screen y grows downwards if the matrix says so: the engine does not flip any axis. 0x8000 (−32768) is never a projected value's meaning when both words hold it; software tests either word.

### 4.3 A job, and its time

| Step | Clocks |
|------|--------|
| Descriptor load (`start_ld`, or a chain) | 16 word reads |
| Set-up (`su_v`) | 8 |
| The view block | 16 word reads |
| Each point | 3 reads, about 9 clocks of multiplies, with `job_persp` 2 more multiplies and 2 divides of about 20 clocks each, then 3 writes |

The job ends as a blitter job does: `done` if `job_irq`, then the next descriptor if `job_next` is not 0, else idle. A chain of jobs with different view blocks transforms several objects with no CPU in between.

### 4.4 Errors and reset

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
| `test/geom`, directed | The identity matrix; a 90° rotation; d and vz chosen so the divide rounds each way; the extremes −32768 and 32767; count 0; stop mid-job; the error |
| `drivers.sh`, the machines | As for the blitter. retro-z80's KS2 does not build this core |

## 7. Open points

| # | Point |
|---|-------|
| G1 | Choices made in this draft, for review: the view block in memory rather than on ports; three words out a point (screen x, screen y, view z); 0x8000 marks a point behind the near plane; the divide rounds towards zero; no axis is flipped; one view block a job |
| G2 | 16-bit fixed point was chosen for size. A world larger than ±32767 units, or a need for sub-pixel screen positions, would be a later revision |
| G3 | Not in this revision: clipping lines and triangles at the near plane (the CPU does it, from view z), back-face tests, lighting, and driving the rasteriser directly |
