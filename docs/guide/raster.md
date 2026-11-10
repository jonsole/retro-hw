# Wiring in the rasteriser

`raster` draws lines and flat-filled triangles into a bitmap in memory, from screen coordinates, one job at a time with a chain to the next. The spec, with the exact pixels and worked examples, is `docs/spec/raster.md`.

## What you write

As for the blitter (`docs/guide/blitter.md`): job registers, the decode in the clocks of `su_v`, the descriptor store, control strobes and status. One thing more: the **clip window**, four signed 16-bit registers shared by every job. They are not part of a descriptor.

## A minimal instantiation

Lines only, on an 8-bit machine with 2 MB of little-endian SRAM:

```verilog
raster #(.AW(20), .LE(1), .TRI(0)) draw (
    .clk(clk), .rst(rst), .enable(draw_on),
    .start_ld(go_load), .start_run(go_run), .stop(go_stop),
    .da_we(desc_we), .da_d(desc_new), .da_q(desc_addr),
    .busy(busy), .done(done), .err(err),
    .su_v(su_v), .su_i(su_i),
    .job_tri(1'b0), .job_minterm(j_mt), .job_bpp(j_bpp), .job_value(j_colour),
    .job_pattern(j_pattern), .job_nolast(j_nolast), .job_irq(j_irq),
    .job_x0(j_x0), .job_y0(j_y0), .job_x1(j_x1), .job_y1(j_y1), .job_x2(16'd0), .job_y2(16'd0),
    .job_daddr(j_bitmap), .job_dstride(j_stride),
    .clip_xmin(cx0), .clip_xmax(cx1), .clip_ymin(cy0), .clip_ymax(cy1),
    .job_next(j_next), .job_bad(j_bad),
    .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(1'b0),
    .mem_req(m_req), .mem_we(m_we), .mem_addr(m_addr), .mem_wdata(m_wdata), .mem_be(m_be),
    .mem_ack(sched_ack[DRAW]), .mem_rvalid(sched_rvalid[DRAW]), .mem_rdata(mem_rdata)
);
```

With `TRI` 1 the core is about twice the size and also fills triangles: set `job_tri` and give the third point.

## Using it

- `job_daddr` is the byte holding pixel (0, 0) of the bitmap, and `job_dstride` the bytes from one row to the next. The core works out each pixel's address from its x and y.
- A solid line has `job_pattern` 0xFFFF and minterm 0xCC. With minterm 0xCA the pattern's 0 bits leave the bitmap alone (a dashed line).
- Joined lines drawn with XOR (minterm 0x66) should set `job_nolast`, so a shared corner is not drawn twice.
- A triangle's points go in any order. Triangles that share an edge fill every pixel along it exactly once, so a mesh has no gaps or doubled pixels.
- A convex polygon is a chain of triangles.

## Pitfalls

- **Set the clip window inside the bitmap.** It is the only thing that keeps a job from writing outside it.
- **Clip long lines roughly first.** Every pixel of a line is stepped, one a clock, even outside the window: an end near ±32767 costs up to 64,000 clocks.
- **A triangle pays about 110 clocks before its first pixel,** for the three slopes. Many tiny triangles are slow; a line or a blitter fill may serve better.
- **Coordinates are whole pixels.** There are no sub-pixel bits.
- **Hold the job and the window** from the last `su_v` clock until `busy` falls.
