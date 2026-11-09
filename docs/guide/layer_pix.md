# Wiring the layer pixel unit

`layer_pix` turns one layer's data into pixels. The layer fetch (on the system clock) fills 8 data registers with a group of 16 source pixels and toggles `fill_t`; the unit takes the group into its shifters when it needs it, toggles `take_t`, and shows the pixels one by one in the layer's window. One unit per layer. The spec is `docs/spec/layer_pix.md`.

## What you need

- A pixel clock and a clock 5 times as fast from the same MMCM.
- A beam: `hc` (the pixel), `hn` (the next one) and `line_start` (one clock at the start of the horizontal blank).
- The layer's window settings for the line, held still from the blank to the end of the line; `transp` and `palofs` live from the registers.
- A layer fetch with 8 data registers for the layer, the group's settings (`gset`: depth, planar, scale) and the full / taken toggles.
- A priority stage that takes `opaque` and `idx` from every layer.

## Instantiation

A chunky-only layer, no tiles:

```verilog
layer_pix #(.PLANAR(0), .TILES(0)) layer0 (
    .clk_pix(clk_pix), .clk_pix5(clk_pix5), .en(video_on),
    .hc(hc), .hn(hn), .line_start(hc == H_VISIBLE), .ready(fetch_ready),
    .active(l0_active), .xs(l0_xs), .xe(l0_xe),
    .pos0(l0_fine_scroll), .transp(l0_transparent), .palofs(l0_palette),
    .tile(1'b0), .dat(l0_dat), .attr(10'd0), .gset(l0_gset),
    .fill_t(l0_fill_t), .take_t(l0_take_t),
    .opaque(l0_opaque), .idx(l0_idx), .pri(), .raw(), .overrun_t(l0_overrun_t)
);
```

`fill_t` comes from the system clock; the unit synchronises it. `take_t` goes back to the system clock, where the fetch synchronises it. `gset` comes with `dat` from the fetch (`layer_fetch`'s `gset[6n +: 6]`): the depth, planar flag and scale the group was fetched with. The unit has no depth or scale inputs of its own; the machine's registers for them feed the fetch.

## A line, clock by clock

A window from pixel 10, scale 1, fine scroll 0. The first group was taken in the blank; the second was filled at once.

```
 hc          9    10   11   12  ...  25   26   27
 hn         10    11   12   13  ...  26   27   28
 pixel       .    p0   p1   p2  ...  p15  p0'  p1'     the pixel the beam is on
 opaque      0    0    1    1   ...  1    1    1
 idx         .    .   p0   p1   ...  p14  p15  p0'     one clock late
 take_t      1    1    1    1   ...  1    0    0       toggles: the second group taken
```

One column per clock; p0' is the second group's first pixel.

In the clock with `hn` = `xs` (here `hc` = 9) the unit sets its pixel counter to `pos0`. From `hc` = 10 each clock shows one pixel, which comes out the clock after. When the 16th pixel of a group is shown, the next group goes into the shifters and `take_t` toggles; the fetch now fills the next group.

With scale 2^hs each source pixel stays for 2^hs clocks, so a group lasts 16 × 2^hs clocks.

## The fetch side

```
 line start:  fill_t <= take_t (synchronised)       empty: drop last line's spare group
              fetch group 0, then fill_t <= ~fill_t
 then:        each time take_t toggles, fetch the next group, then fill_t <= ~fill_t
```

Only touch `dat` and `attr` while the unit is not full (`fill_t` = `take_t` as the fetch sees it). Give `ready` once the fetch has restarted for the new line; a slow `ready` only means the first group is taken later, still in the blank.

## Pitfalls

- **Hold the window settings.** `active`, `xs`, `xe`, `pos0` and `tile` are read every clock: change them only in the horizontal blank, after `line_start`. Depth, planar and scale come with each group in `gset`, so a mid-line write to them (made at the fetch) shows from a group boundary, one or two groups on. `transp` and `palofs` are read raw from the machine's clock: constrain those paths (`set_false_path`, or `set_max_delay` across the `palofs` bits) and accept one mixed pixel while they change.
- **Empty the handshake at the line start.** If the fetch leaves a spare group from the last line, the unit takes it as the new line's first group.
- **Word order.** The first word of a chunky group goes in the highest data register used: for 4 bits per pixel, word 0 in register 3, word 3 in register 0.
- **Byte order.** The leftmost pixel is in the top bits of a word. If the memory is little-endian, the fetch must put the even byte in the word's high half.
- **The fast clock.** `clk_pix5` must be 5 times `clk_pix` with edges lined up. A slower synchroniser makes a new group visible later, which the fetch's deadline must allow for.
- **Overrun is per group.** A late group blanks the layer from the group boundary to the next one; the unit does not take the group late. Count `overrun_t` toggles to see it happen.
- **Unused features.** With `PLANAR` or `TILES` off, tie their inputs to 0 anyway (`gset` bit 0 included), so simulation shows no X.
