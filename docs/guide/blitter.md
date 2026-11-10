# Wiring in the blitter

`blitter` works on rectangles of pixels in memory: copy, fill, cut out, combine, one job at a time, with a chain to the next job. The spec, with the exact result and worked examples, is `docs/spec/blitter.md`. This guide is for someone putting it into a machine.

## What you write

The core has no registers. Your wrapper owns:

1. **The job registers.** Minterm, mask kind, depth, direction, constant and key, three strides, width and height, three addresses with their bit positions, and the next descriptor's address. Lay them out as your CPU likes. A small RAM of 8 long words is cheapest.
2. **The decode.** While `su_v` is high (8 clocks, `su_i` 0 to 7) put the job on the `job_` ports, and hold them until the job ends.
3. **The descriptor store.** On `dl_v`, store long word `dl_i` from `dl_w0` (the lower address) and `dl_w1`. Raise `dl_wait` until it is stored, if your RAM needs a clock.
4. **Control and status.** Turn register writes into the strobes `start_ld`, `start_run`, `stop` and `da_we`; read back `busy`, `err` and `da_q`.
5. **An interrupt flag,** set by `done`, if you want one.

## A minimal instantiation

An 8-bit machine with 2 MB of little-endian SRAM and no 1-bit mask image:

```verilog
blitter #(.AW(20), .LE(1), .MASKIMG(0)) blit (
    .clk(clk), .rst(rst), .enable(blit_on),
    .start_ld(go_load), .start_run(go_run), .stop(go_stop),
    .da_we(desc_we), .da_d(desc_new), .da_q(desc_addr),
    .busy(busy), .done(done), .err(err),
    .su_v(su_v), .su_i(su_i),
    .job_minterm(j_mt), .job_mask(j_mask), .job_bpp(j_bpp), .job_rtl(j_rtl),
    .job_bconst(j_bconst), .job_irq(j_irq), .job_value(j_value), .job_key(j_key),
    .job_astride(16'd0), .job_bstride(j_bstr), .job_dstride(j_dstr),
    .job_width(j_width), .job_height(j_height),
    .job_aaddr(24'd0), .job_baddr(j_b), .job_daddr(j_d),
    .job_abit(3'd0), .job_bbit(j_bbit), .job_dbit(j_dbit),
    .job_next(j_next), .job_bad(j_bad),
    .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(1'b0),
    .mem_req(m_req), .mem_we(m_we), .mem_addr(m_addr), .mem_wdata(m_wdata), .mem_be(m_be),
    .mem_ack(sched_ack[BLIT]), .mem_rvalid(sched_rvalid[BLIT]), .mem_rdata(mem_rdata)
);
```

The memory port is one requester on `dmac.v`.

## The three jobs every program uses

| Job | Minterm | Other settings |
|-----|---------|----------------|
| Fill | 0xCC | `job_bconst` 1, `job_value` the colour in every pixel of a word |
| Copy | 0xCC | `job_bconst` 0 |
| Copy with colour 0 transparent | 0xCA | `job_mask` 2, `job_key` 0 |

The spec's section 4.9 gives the port values for these and for text and scrolling.

## Pitfalls

- **Software clips.** The blitter writes exactly the rectangle it is given. There is no clip window and no check against the size of memory: an address past the end wraps.
- **Overlapping copies need the right direction.** A destination to the right of the source in the same rows needs `job_rtl`, with the addresses naming each row's last pixel. One below needs the bottom row first: give its addresses and negative strides.
- **A fill pattern lines up with memory words,** not with the rectangle's left edge.
- **Hold the job.** The job ports must not change from the last `su_v` clock until `busy` falls, or the next descriptor load.
- **A chain ends on an address of 0.** `job_next` 0 means no next job.
- **`stop` is not resumable.** The job ends after the word in hand.
- **Each mask row has its own stride.** A 1-bit mask beside an 8-bit source has rows an eighth as long: set `job_astride` for the mask, `job_bstride` for the source.
