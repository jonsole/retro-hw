// One layer, pixel side: the shifters that turn a layer's 16-pixel groups
// into pixels.
//
// Eight 16-bit shifters, loaded all at once from the layer's data registers
// (in the machine's layer fetch). The first group of a line is taken as
// soon as it is complete, in the horizontal blank (so the fetcher fetches
// the second one before the window starts); after that, each time a group
// is used up. If the next group is not complete by then, the layer shows
// transparent pixels for that group (overrun).
//
// A group is always 16 source pixels:
//   chunky: 1, 2, 4 or 8 consecutive words (bits per pixel), packed pixels,
//           the leftmost pixel in the top bits of the first word, which is
//           in the highest data register used (data register 0 holds the
//           last word)
//   planar: (PLANAR) one word from each of 1-8 planes, the leftmost pixel
//           in bit 15
//
// Scaling repeats each source pixel 1, 2, 4 or 8 times.
//
// Tiles (TILES): a tile layer's group is the same shape, two tile columns
// of 8 pixels, with each column's PAL and PRI (attr) taken with the data.
// PAL is added to palofs for depths of up to 4 bits; PRI goes out with the
// pixel for the priority stage.
//
// A group brings its own settings (gset, taken with it from the layer
// fetch): whether it is planar, its depth, and its scale. So a setting the
// machine changes mid-line applies from the next group the fetch starts,
// never inside one, and the fetch and this unit always agree about a
// group. transp and palofs are read live, straight from the machine's
// registers on its own clock (a raw crossing; spec 4.4).
//
// Without PLANAR gset's planar flag is not used; without TILES the tile and
// attr inputs are not used and pri reads 0.
module layer_pix #(
    parameter PLANAR = 1,              // 1: planar layers built
    parameter TILES  = 0               // 1: tile layers' PAL and PRI built
) (
    input  wire         clk_pix,
    input  wire         clk_pix5,      // 5 x clk_pix, edges lined up (same MMCM): for the fast synchroniser
    input  wire         en,            // video on
    input  wire [10:0]  hc,            // beam (not used now), and the next pixel's position (picture-relative)
    input  wire [10:0]  hn,
    input  wire         line_start,    // start of horizontal blank: a new line's setup begins
    input  wire         ready,         // the data registers hold this line's data (after the fetcher restarted)

    // This line's settings (stable through the line)
    input  wire         active,        // the layer shows on this line
    input  wire [10:0]  xs, xe,        // window
    input  wire [3:0]   pos0,          // first pixel in the first group (fine scroll)
    input  wire         tile,          // (TILES) a tile map: PAL and PRI from attr
    // Live, from the machine's registers (raw crossing)
    input  wire         transp,
    input  wire [3:0]   palofs,

    // The data registers, the group's settings, and the full / taken handshake (toggles)
    input  wire [127:0] dat,           // data register 0 in the lowest 16 bits
    input  wire [9:0]   attr,          // (TILES) {PRI, PAL} of column 1 (9-5) and column 0 (4-0)
    input  wire [5:0]   gset,          // {hs, depth, planar}: log2 of the scale, words - 1, (PLANAR) planar
    input  wire         fill_t,        // from the system clock side
    output reg          take_t,

    // This pixel
    output reg          opaque,
    output reg  [7:0]   idx,
    output reg          pri,           // (TILES) a tile pixel whose entry has PRI set
    output reg  [7:0]   raw,           // the pixel value itself (direct colour)
    output reg  [3:0]   raw_gs,        // ... and its group's {planar, depth}: depth + 1 bits a pixel
    output reg          overrun_t      // toggles when a group was missing
);
    // "Full" from the system clock side, through two flip-flops at 5 x the
    // pixel clock rather than 1 x: a few ns instead of up to a pixel clock
    // and a half. The second stage is then read by the pixel side as a
    // related clock.
    (* ASYNC_REG = "TRUE" *) reg [1:0] fill_s;
    always @(posedge clk_pix5) fill_s <= {fill_s[0], fill_t};
    wire        avail  = fill_s[1] != take_t;
    // The window is a flag: set as the beam comes to xs, cleared as it
    // comes to xe (xs must not be after xe, nor xe after the line's end).
    // With xs = xe the clear wins: an empty window. line_start clears it
    // too, whatever xe was, so settings not yet valid cannot leave it set
    reg         win;
    wire        at_xe  = (hn == xe);
    wire        in_win = active && win;
    always @(posedge clk_pix) begin
        if (at_xe || line_start) win <= 1'b0;
        else if (hn == xs) win <= 1'b1;
    end
    wire        tl     = (TILES != 0) && tile;

    reg  [15:0] sh [0:7];              // shifters
    reg  [9:0]  sha;                   // ... and the group's PAL and PRI (tiles)
    reg  [5:0]  shg;                   // ... and its settings
    wire        pl     = (PLANAR != 0) && shg[0];
    wire [2:0]  planes = shg[3:1];                         // planar: planes - 1
    wire [1:0]  lb     = shg[3] ? 2'd3 : shg[2] ? 2'd2 : shg[1] ? 2'd1 : 2'd0;   // chunky: log2 of bits per pixel, from words - 1
    wire [1:0]  hs     = shg[5:4];
    reg         ok;                    // the current group arrived
    reg         primed;                // the line's first group is in the shifters
    reg  [3:0]  pos;                   // pixel in the group
    reg  [2:0]  hsub;                  // screen pixels shown of this source pixel

    // The pixel at pos. Planar: bit 15 - pos of each plane's word. Chunky at 1
    // bit is the same with one plane. Deeper chunky: the pixel's word first
    // (the highest register holds the leftmost pixels), then its place in it.
    wire [6:0]  bitp  = {3'd0, pos} << lb;                 // chunky: bit of the pixel in the group
    wire [2:0]  wi    = ((3'd1 << lb) - 1'b1) - bitp[6:4]; // ... and its data register
    wire [15:0] cwd   = sh[wi];
    wire        one   = pl || (lb == 2'd0);                // a bit a word: planar, or 1-bit chunky
    wire [2:0]  np    = pl ? planes : 3'd0;
    reg  [7:0]  value;
    always @(*) begin : px
        integer p;
        value = 8'd0;
        if (one) begin
            for (p = 0; p < 8; p = p + 1)
                value[p] = (p <= np) ? sh[p][4'd15 - pos] : 1'b0;
        end else case (lb)
            2'd1:    value[1:0] = cwd[{~pos[2:0], 1'b0} +: 2];
            2'd2:    value[3:0] = cwd[{~pos[1:0], 2'b00} +: 4];
            default: value      = pos[0] ? cwd[7:0] : cwd[15:8];
        endcase
    end
    wire        deep  = pl ? planes[2] : (lb == 2'd3);     // more than 4 bits: no palette offset
    wire [4:0]  ca    = pos[3] ? sha[9:5] : sha[4:0];      // the tile column's PRI and PAL
    wire [3:0]  blk   = tl ? palofs + ca[3:0] : palofs;

    // Moving on by one source pixel
    wire [4:0]  nxp   = pos + 1'b1;
    wire        last  = nxp[4];                            // the group is used up
    wire        step  = (hsub == (3'd7 >> (2'd3 - hs)));   // last screen pixel of this source pixel
    wire        first = active && (hn == xs);              // the window starts with the next pixel

    // Load the shifters from the data registers
    task load;
        integer i;
        begin
            if (avail) begin
                for (i = 0; i < 8; i = i + 1) sh[i] <= dat[16*i +: 16];
                sha    <= (TILES != 0) ? attr : 10'd0;
                shg    <= gset;
                take_t <= ~take_t;
                ok     <= 1'b1;
            end else begin
                ok        <= 1'b0;
                overrun_t <= ~overrun_t;
            end
        end
    endtask

    always @(posedge clk_pix) begin
        if (!en) begin
            opaque    <= 1'b0;
            ok        <= 1'b0;
            overrun_t <= 1'b0;
            take_t    <= fill_s[1];        // nothing waiting
            primed    <= 1'b0;
        end else if (line_start) begin
            opaque <= 1'b0;
            ok     <= 1'b0;
            primed <= 1'b0;
        end else begin
            opaque <= in_win && ok && !(transp && value == 8'd0);
            idx    <= deep ? value : {blk, value[3:0]};
            pri    <= tl && ca[4];
            raw    <= (in_win && ok) ? value : 8'd0;
            raw_gs <= {pl, shg[3:1]};
            if (!primed && ready && avail) begin
                load;                          // the first group, ahead of the window
                primed <= 1'b1;
            end
            if (first) begin
                pos  <= pos0;
                hsub <= 3'd0;
                if (!primed) load;             // (counts as overrun if it is not there)
                primed <= 1'b1;
            end else if (in_win) begin
                if (step) begin
                    hsub <= 3'd0;
                    pos  <= nxp[3:0];
                    if (last && !at_xe) load;
                end else
                    hsub <= hsub + 1'b1;
            end
        end
    end
endmodule
