# Wiring in the TMDS encoder

`tmds_encoder` turns one colour component (8 bits) into the 10-bit word DVI sends on one lane per pixel clock, and sends the control words that carry the syncs during blanking. You need three, one per colour. On the Next, `hdmi_out` (platform) already holds the three and the serialisers, so most machines use that instead of this file directly. The full details are in [the spec](../spec/tmds_encoder.md).

## A minimal instantiation

```verilog
wire [9:0] w_b, w_g, w_r;
tmds_encoder eb (.clk(clk_pix), .d(blue),  .c({vsync, hsync}), .de(de), .q(w_b));
tmds_encoder eg (.clk(clk_pix), .d(green), .c(2'b00),          .de(de), .q(w_g));
tmds_encoder er (.clk(clk_pix), .d(red),   .c(2'b00),          .de(de), .q(w_r));
// Serialise w_b, w_g and w_r bit 0 first at 10 x clk_pix, with a clock lane
// sending 10'b0000011111 (hdmi_out does all this on the Artix-7)
```

## Timing sketch

The last pixels of a line and the start of blanking. Each word on `q` belongs to the inputs one edge earlier.

```
clk_pix    ‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__
de         ‾‾‾‾‾‾‾‾____________________
d          <P1=<P2=
hsync      ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾________‾‾‾‾
q (blue)       <W1=<W2=<C3=<C3=<C2=<C2=
```

`hsync` is active low here and `c` = {vsync, hsync} with vsync high (not active). W1 and W2 are the encoded pixels P1 and P2. C3 is the control word for C1 C0 = 11 (`1010101011`, both syncs high); C2 is the one for 10 (`0101010100`, hsync low).

## Pitfalls

- **`de` must be 0 for all of blanking**, horizontal and vertical. The encoder resets its disparity in control periods and the sink finds the syncs there.
- **Syncs at the level to send.** The encoder does not invert them. 576p needs both active low.
- **Control bits on blue only.** Green and red take `c` = 0 for DVI.
- **One clock of latency**, the same on all three lanes. Any signal sent beside the lanes (a VGA output, a test tap) needs the same delay to line up.
- **Bit 0 first.** Send `q[0]` first on the wire. Sending bit 9 first gives no picture.
- **No HDMI audio.** This is a DVI encoder: no data islands.
