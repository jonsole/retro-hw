# Wiring in sprite_pix

`sprite_pix` draws one sprite on the pixel clock. It takes words from the front of the sprite's FIFO, which `sprite_fetch` fills, and gives a pixel each clock: whether it shows (`opaque`) and its colour index (`idx`). Build one per sprite. Your machine then puts the sprites' pixels and its other layers through its own priority and palette.

The spec is `docs/spec/sprite_pix.md`.

## A minimal instantiation

The sprite's line runs from pixel 720 of the line before to pixel 719 of its own: `t` = 0–863, with `t` = 144 the first pixel shown. Take the sprite's settings from `sprite_fetch` into pixel clock registers at `t` = 12 and hold them for the line.

```verilog
reg  [7:0] c_act, c_dma;
reg  [9:0] c_hs [0:7], c_xe [0:7];
reg  [1:0] c_lb [0:7];
reg [15:0] c_xs [0:7];
reg  [3:0] c_pal [0:7];
always @(posedge clk_pix) if (t == 10'd12 || !video_on) begin : take
    integer n;
    for (n = 0; n < 8; n = n + 1) begin
        c_act[n] <= video_on && sp_act[n];
        c_hs[n]  <= sp_hs[10*n +: 10];   c_xe[n] <= sp_xe[10*n +: 10];
        c_lb[n]  <= sp_lb[2*n +: 2];     c_xs[n] <= sp_xstep[16*n +: 16];
        c_pal[n] <= sp_pal[4*n +: 4];    c_dma[n] <= sp_dma[n];
    end
end

genvar g;
generate for (g = 0; g < 8; g = g + 1) begin : sprs
    wire [5:0] rp;
    assign sp_ra[5*g +: 5] = rp[4:0];
    sprite_pix u (
        .clk_pix(clk_pix), .en(video_on), .t(t),
        .act(c_act[g]), .hs(c_hs[g]), .xe(c_xe[g]), .lb(c_lb[g]),
        .xstep(c_xs[g]), .pal(c_pal[g]), .dma(c_dma[g]),
        .head(sp_rd[16*g +: 16]), .rp(rp), .rp_g(sp_rpg[6*g +: 6]),
        .wp_g(sp_wpg[6*g +: 6]),
        .flush_t(sp_fl[g]), .flush_ack_t(sp_fla[g]),
        .opaque(s_op[g]), .idx(s_idx[g]), .underrun_t(s_under[g])
    );
end endgenerate
```

## A typical span

A 4-bit sprite at 1:1 (`xstep` = `0x0800`), `hs` = 200:

```
clk_pix  _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
t         199 200 201 202 203 204 205 206
rp         0   0   0   0   0   1   1   1
idx        -   -  px0 px1 px2 px3 px4 px5
```

`opaque` and `idx` come a clock after the `t` they belong to: pixel 0 (the word's top 4 bits, `t` = 200) shows at `t` = 201. A 4-bit word lasts four pixels; `rp` moves on as each word is passed.

## Pitfalls

- **One clock late.** `opaque` and `idx` are registered: line them up with your layers' pixels.
- **Settings at `t` = 12.** Taken earlier, they are the last line's; HSTART must be 16 or more.
- **Places before 144 are hidden.** A sprite can start left of the screen; those pixels go by in the horizontal blank and never show.
- **Underruns are sticky.** A DMA sprite that runs dry shows nothing more until it is started again. Watch `underrun_t` to report it.
- **Value 0 is transparent**, in every bits-per-pixel mode.
- **Collisions are yours.** The unit gives only `opaque`. Compare the sprites' and layers' `opaque` over a line and hand the result to `sprite_fetch` with a toggle.
