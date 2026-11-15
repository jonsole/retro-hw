# Wiring in HDMI sound

`hdmi_packets` adds stereo sound to a DVI picture: it sends the samples, and what a display needs to play them, as HDMI data islands in each line's blank. The spec, with every packet's contents, is `docs/spec/hdmi_packets.md`.

On an Artix-7 you don't instantiate it yourself: build `hdmi_out` with `AUDIO` = 1.

## What you write

- The picture, syncs and data enable, exactly as for DVI.
- Three more signals from your sound: left, right, and a strobe for each new sample.
- One level, `hdmi_on`, from a register that is 1 after reset.

## A minimal instantiation

```verilog
hdmi_out #(.AUDIO(1), .VIC(17)) hdmi (
    .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rst(pix_rst),
    .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de),
    .hdmi_on(hdmi_on),
    .clk(clk), .aud_l(out_l), .aud_r(out_r), .aud_v(out_v),      // audio_engine's outputs, as they are
    .tmds_p(tmds_p), .tmds_n(tmds_n)
);
```

With `AUDIO` = 0 (the default) the block is the DVI output it always was, and the extra inputs are not used: tie them to 0.

## A typical line

```
x (from the blank's start)   0..3     4..11     12,13  14..45    46..77    78,79  80..
lane 0                       control  control   guard  packet 1  packet 2  guard  control ...
what it is                            preamble         samples   ACR, an          then the picture's
                                                                 InfoFrame        own preamble and
                                                                 or nothing       guard band
```

About three samples arrive in a line at 48 kHz, and a packet holds four, so every sample goes in the next line's island.

## Pitfalls

- **The blank must be 92 pixels or more.** The island and the control words around it need that. 576p has 144.
- **The picture is 12 pixel clocks later.** Syncs and picture move together, so a display sees no difference.
- **The rate is said to be 48 kHz.** The display follows your real rate, so 48.008 kHz is fine. A rate far from 48 kHz is not supported in this revision.
- **`hdmi_on` is taken at a frame's start.** Switching takes effect at the next frame, and a frame or two of samples are lost on the way back to HDMI.
- **After reset the first frame is DVI.** Sound starts with the first whole frame.
- **Some displays are fussier about HDMI than DVI.** Keep the register that drives `hdmi_on`, so software can fall back.
- **Constrain the crossing.** The samples cross from the system clock inside the core: a toggle through two flip-flops, and the sample registers read once it has settled. Put the two clock groups asynchronous, as for the sprites' and layers' crossings.
- **Without an Artix-7:** wire three `tmds_encoder`s with `HDMI` = 1 to the core's `o_` outputs (lane 0 `g` = 0, lane 1 `g` = 1, lane 2 `g` = `o_g2`) and serialise their words as before.
