# Wiring in sprite_fetch

`sprite_fetch` is the memory side of the sprites. It reads each sprite's image from memory a line at a time and puts the words in a FIFO per sprite. A `sprite_pix` per sprite, on the pixel clock, takes them out and draws. Between them sit the FIFOs, which cross the clock domains.

Your machine keeps the sprite registers. The core asks for one sprite's settings each clock and reads them from your registers. The one thing it keeps itself is each sprite's line start, because it moves that on as lines are drawn; your registers read and write it through a port.

The spec is `docs/spec/sprite_fetch.md`.

## What you need

- A sprite channel on your memory scheduler: request and acknowledge, then the word some clocks later, in order.
- The beam in the system clock domain (line 0–624, pixel 0–863 with 0 the start of the horizontal blank) and a strobe at the start of the vertical blank.
- Registers for each sprite: the window (HSTART, HSTOP, VSTART, VSTOP), XSTEP and YSTEP, bits per pixel, depth and palette, the line start, a DMA enable per sprite, a control write that starts the sprite, and a collision register.

## A minimal instantiation

Here the settings sit in small RAMs indexed by sprite. Your register bus writes them; the core reads them at `set_sel`.

```verilog
wire [2:0]  cs;                    // the sprite the core looks at this clock
wire [22:0] lst;                   // line start of sprite `sn`

sprite_fetch #(.NS(8), .PW(23), .SWAP_BYTES(0), .URGENT(5), .MANUAL(0)) spr (
    .clk(clk), .rst(rst),
    .set_sel(cs),
    .set_hstart(hstart[cs]), .set_hstop(hstop[cs]),
    .set_vstart(vstart[cs]), .set_vstop(vstop[cs]),
    .set_bpp(bpp[cs]), .set_depth(depth[cs]), .set_pal(pal[cs]),
    .set_xstep(xstep[cs]), .set_ystep(ystep[cs]),
    .dma_on(dma_master), .dma_mask(dma_enables),
    .start(ctl_written ? (8'd1 << sn) : 8'd0),
    .sel(sn), .lst_cur(lst), .lst_wr(pt_written), .lst_new(pt_value),
    .fifo_count(), .dat_wr(1'b0), .dat(16'd0),
    .vblank(vblank_start), .beam_v(beam_v), .beam_h(beam_h),
    .mem_req(spr_req), .mem_addr(spr_addr), .mem_deadline(spr_deadline),
    .mem_urgent(spr_urgent), .mem_ack(spr_ack), .mem_rvalid(spr_rvalid),
    .mem_rdata(mem_rdata),
    .p_hs(sp_hs), .p_xe(sp_xe), .p_act(sp_act), .p_lb(sp_lb),
    .p_xstep(sp_xstep), .p_depth(sp_depth), .p_pal(sp_pal), .p_dma(sp_dma),
    .fifo_ra(sp_ra), .fifo_rd(sp_rd), .wp_g(sp_wpg), .rp_g(sp_rpg),
    .flush_t(sp_fl), .flush_ack_t(sp_fla),
    .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clear), .coll(coll)
);
```

`sn` is the sprite your register bus addresses. A write of part of the line start (one byte, say) merges into `lst` and goes in whole:

```verilog
assign pt_value = {lst[22:8], wdata[7:0]};    // the low byte written
```

Then build one `sprite_pix` per sprite on the pixel clock (see `docs/guide/sprite_pix.md`).

## A typical line

At the end of each line (beam pixels 840–847) the core takes the settings for the next line. At pixel 0 the line-start pass decides which sprites show, then the words are fetched. A memory read looks like this:

```
clk          _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
mem_req      ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\___________
mem_addr     ----< A0      >< A1  >---------
mem_ack      ____________/‾‾\__/‾‾\_________
mem_rvalid   __________________/‾‾\___/‾‾\__
mem_rdata    ------------------<W0>---<W1>--
```

The request stays up until it is acknowledged; the next one may follow in the same clock as the acknowledge. Words come back in the order asked, any number of clocks later, with up to four on their way. Each goes into its sprite's FIFO.

Starting a sprite:

```
start[n]     __/‾‾\______________________
flush_t[n]   _____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾   (toggles)
flush_ack_t  ______________/‾‾‾‾‾‾‾‾‾‾‾‾‾   (sprite_pix answers)
fetching        no ....................yes, from the next line in the window
```

## Pitfalls

- **Settings in the same clock.** The `set_` inputs must be sprite `set_sel`'s settings in that same clock: read your RAM combinationally. A registered read gives the core the wrong sprite's settings.
- **Bits per pixel 3.** `set_bpp` takes 0, 1, 2 (2, 4, 8 bits). If your register has a fourth value, map it first.
- **Byte order.** The first pixels are in the FIFO word's high half. On a little-endian memory set `SWAP_BYTES` to 1.
- **HSTART at least 16.** The pixel side takes the settings at beam pixel 12, after the line-start pass.
- **The line start moves.** Reading it back gives the start of the line being drawn, not the value you wrote. A write makes the next shown line start exactly there.
- **Starting empties the FIFO.** So does the vertical blank, for every sprite. Start the sprites again each frame (a copper list or the vertical blank interrupt).
- **Sprites not built.** For a sprite at or above `NS`, tie its `flush_ack_t` to its `flush_t` and its `rp_g` to 0.
- **Beam in the right domain.** `beam_h` and `beam_v` must be the system clock's view of the beam. Cross them carefully (for example, sample until two samples agree).
- **Collision clear.** `coll_clr` is a mask for one clock, not a level.
