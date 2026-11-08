# Wiring in the DMA engine

`dmx_core` is a blitter and DMA engine with four channels. It copies, fills, masks, adds and draws lines in memory, a word at a time, while the CPU gets on with something else. The spec is `docs/spec/dmx_core.md`. This guide is for someone putting it into a new machine.

## What you write

The core has no registers. Your wrapper owns:

1. **The job registers.** Each channel's job: operation, minterm, addresses, strides, width, height, value, next descriptor. Lay them out as your CPU likes. A small RAM (4 channels × 8 long words) is cheapest.
2. **The decode.** While `su_v` is high (8 clocks), put channel `cur`'s job on the `job_` ports. Hold them after. `su_i` counts 0 to 7, so you can read one long word of a RAM a clock and latch its fields.
3. **The descriptor store.** On `dl_v`, write long word `dl_i` of channel `cur` from `dl_w0` (lower address) and `dl_w1`. Raise `dl_wait` until it is written, if your RAM has a busy clock.
4. **The control and status registers.** Turn writes into the strobes `start_ld`, `start_run`, `stop`, `clr_done`, `clr_err`, `da_we`; hold `pause` yourself; read back `busy`, `done`, `err`, `da_q`, `ea_q`.
5. **The interrupt flags.** Set a channel's flag on `irq_set`; let the CPU clear it.

## A minimal instantiation

An 8-bit machine with little-endian SRAM of 2 MB, no other port, no port jobs, LINE and EDGES built:

```verilog
dmx_core #(.CHIP_WORDS(24'h100000), .LE(1), .MASKIMG(1), .XPORT(0), .PORTJOB(0),
           .LINE(1), .EDGES(1)) dma (
    .clk(clk), .rst(rst),
    .enable(dma_on), .pause(pause),
    .start_ld(go_load), .start_run(go_run), .stop(go_stop),
    .clr_done(ack_done), .clr_err(ack_err),
    .da_we(desc_we), .da_d(desc_new),
    .busy(busy), .done(done), .err(err), .da_q(desc_all), .ea_q(err_all),
    .irq_set(irq_set), .idle(dma_idle), .cur(cur),
    .su_v(su_v), .su_i(su_i),
    .job_op(j_op), .job_minterm(j_mt), .job_sat(j_sat), .job_signed(j_sgn),
    .job_mask(j_mask), .job_bpp(j_bpp), .job_desc(j_desc), .job_irq(j_irq),
    .job_bconst(j_bconst), .job_ymaj(j_ymaj), .job_xneg(j_xneg), .job_yneg(j_yneg),
    .job_value(j_value), .job_bstride(j_bstr), .job_dstride(j_dstr),
    .job_width(j_width), .job_height(j_height),
    .job_aaddr(j_a), .job_baddr(j_b), .job_daddr(j_d),
    .job_abit(j_abit), .job_bbit(j_bbit), .job_dbit(j_dbit), .job_next(j_next),
    .job_bport(1'b0), .job_dport(1'b0), .job_bad(j_bad),
    .clip_xmin(cx0), .clip_xmax(cx1), .clip_ymin(cy0), .clip_ymax(cy1),
    .dl_xok(1'b0), .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(dl_wait),
    .mem_req(m_req), .mem_we(m_we), .mem_addr(m_addr), .mem_wdata(m_wdata), .mem_be(m_be),
    .mem_ack(m_ack), .mem_rvalid(m_rvalid), .mem_rdata(m_rdata),
    .acc_a(), .acc_we(), .xp_ok(1'b0),
    .xp_req(), .xp_we(), .xp_addr(), .xp_wdata(), .xp_be(),
    .xp_ack(1'b0), .xp_rvalid(1'b0), .xp_rdata(16'd0),
    .p_rxv(1'b0), .p_rxd(8'd0), .p_rxpop(), .p_txr(1'b0), .p_txpush(), .p_txd()
);

// The running channel's job, a long word a clock (jr is your job RAM)
always @(posedge clk) if (su_v) case (su_i)
    3'd0: begin j_op <= jr[{cur, su_i}][2:0]; /* ... */ end
    // ...
endcase
```

## A memory transaction

The memory port is a request held until taken, with reads coming back in order. A copy's group: two reads, then two writes.

```
clk        _/~\_/~\_/~\_/~\_/~\_/~\_/~\_/~\_/~\_
mem_req    ___/~~~~~~~~~~~~~~~\___/~~~~~~~~~~~\___
mem_we     _______________________/~~~~~~~~~~~\___
mem_addr   ---< R0    >< R1   >---< W0  >< W1 >---
mem_ack    _______/~~~\___/~~~\_______/~~~\/~~~\__
mem_rvalid _______________/~~~\___/~~~\__________
mem_rdata  ---------------< D0 >---< D1 >---------
```

- The request at R0 waits a clock for `mem_ack`; R1 goes up in the clock R0 is taken.
- Read data come back later, in order, one a clock at most.
- The writes start as the last read comes back.

## Starting a job

```
clk        _/~\_/~\_/~\_/~\_/~\_ ... _/~\_/~\_/~\_
start_run  __/~~~\_______________ ... ___________
busy[n]    ______/~~~~~~~~~~~~~~ ... ~~~~~~~~\___
su_v       ______________/~~~~~~ ... ~\_________   (8 clocks)
su_i                     <0><1>  ... <7>
irq_set[n] ______________________ ... ____/~~~\__   (if the job asks)
```

## Pitfalls

- **Register a request you pass on from the other port.** `xp_req` and `xp_addr` come out of long logic. Fed straight into a register bus or another mux, they make a path of over 20 levels that misses 100 MHz (found by retro68k: −0.170 ns). Hold the request in a register until the far side takes it.
- **Hold the job ports.** Change them only while `su_v` is high. The core reads them for the whole job, not only at the start, and sets up again whenever a channel comes back after another one's turn.
- **Byte order.** `LE` must match what the CPU sees: with `LE` set the byte at an even address is bits 7-0 of a memory word. Descriptors and EDGES' coordinates come through as stored, so a 16-bit field in them is in the memory's order.
- **Strobes win.** A strobe in the same clock as the engine's own change wins (a clear of `done` as a job ends leaves it clear). An interrupt flag register written in the clock `irq_set` comes up should still take the new flag, or the interrupt is lost.
- **Idle-only writes.** `start_ld`, `start_run` and `da_we` are ignored while the channel is busy; job register writes should be too.
- **`xp_ok` is combinational.** It looks at `acc_a` and `acc_we` in the same clock. Do not make it depend on the core's other outputs.
- **Reads in order.** Both ports must return reads in the order they were taken. The core counts them; a lost or extra `rvalid` hangs it.
- **LINE and EDGES are off by default.** Set `LINE` and `EDGES` to 1 if your software draws lines or polygons with the engine; at 0 those jobs are errors, and their logic is left out. With both at 0 the clip and octant inputs can be tied to 0.
- **Mask image size.** `MASKIMG = 0` saves about 400 LUTs; a job asking for a mask image is then an error.
