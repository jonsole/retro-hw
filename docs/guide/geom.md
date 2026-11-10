# Wiring in the geometry engine

`geom` turns a list of 3D points in memory into screen coordinates: it rotates and translates each by a matrix, projects it, and writes screen x, screen y and view z back to memory. The spec, with the exact arithmetic and a worked example, is `docs/spec/geom.md`. A machine short of room leaves this core out and lets its CPU do the sums.

## What you write

As for the blitter (`docs/guide/blitter.md`): job registers, the decode in the clocks of `su_v`, the descriptor store, control strobes and status. The job is small: a count, three addresses, a perspective flag, and the next descriptor's address.

## A minimal instantiation

```verilog
geom #(.AW(21)) xform (
    .clk(clk), .rst(rst), .enable(geom_on),
    .start_ld(go_load), .start_run(go_run), .stop(go_stop),
    .da_we(desc_we), .da_d(desc_new), .da_q(desc_addr),
    .busy(busy), .done(done), .err(err),
    .su_v(su_v), .su_i(su_i),
    .job_count(j_count), .job_vaddr(j_points), .job_oaddr(j_results), .job_maddr(j_view),
    .job_persp(j_persp), .job_irq(j_irq), .job_next(j_next), .job_bad(j_bad),
    .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(1'b0),
    .mem_req(m_req), .mem_we(m_we), .mem_addr(m_addr), .mem_wdata(m_wdata), .mem_be(m_be),
    .mem_ack(sched_ack[GEOM]), .mem_rvalid(sched_rvalid[GEOM]), .mem_rdata(mem_rdata)
);
```

The memory port is one requester on `dmac.v`. The core uses one 17×17 signed multiply: a DSP block where the FPGA has one.

## Using it

1. Keep each object's points in memory: three signed 16-bit words a point, x, y, z.
2. Each frame, write the object's view block: 16 words. Nine matrix entries in 2.14 (0x4000 is 1.0), row by row; the translation tx, ty, tz; the eye-to-screen distance d; the screen centre cx, cy; the near plane.
3. Start a job with the count, the points' address, where the results go, and the view block's address.
4. Read the results: three words a point. Screen x and y are ready for `raster`; view z is for sorting and culling.

A chain of jobs with a view block each transforms several objects with no CPU in between.

## Pitfalls

- **0x8000 means behind.** A point nearer than the near plane is not projected: its screen x and y are both written as 0x8000. A real screen coordinate is never 0x8000, so testing one word is enough. Clipping lines and triangles that cross the near plane is the CPU's job.
- **The near plane must be at least 1.** Below that a divide by zero can be asked for.
- **Fold your axes into the matrix.** The engine flips nothing: for screen y growing downwards, negate the matrix's second row.
- **Matrix entries are within ±2.0.** Fold scale and aspect into the matrix, or into d.
- **Results may overwrite the points** (the same address for both), but must not overlap points still to be read.
- **Off-screen points are still written,** limited to ±32767. The rasteriser's window clips what is drawn from them.
- **It is not fast per point:** about 110 clocks with perspective. A few hundred points a frame is comfortable.
