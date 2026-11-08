// Layer fetch and the layers' pointer registers (spec 4, sections 4.4, 4.5
// and 5). 100 MHz domain. retro68k's bpldma.v, chunky only and on the
// 8-bit register bus, with retro-z80's tile mode added (section 5.2).
//
// Each layer has one live pointer BPL0PT, which counts up as words are
// fetched, and 8 data registers inside (not registers software can reach,
// spec 4, section 2). There are no other buffers: a layer's data registers
// hold its next 16-pixel group while its shifters (layer_pix.v) show the
// current one.
//
// A layer is "full" once its group is complete: when the fetcher has
// fetched the last of its words (high data register to low). The pixel side
// then takes the group into its shifters when it needs it, and the fetcher
// fetches the next group. Full and taken cross between the clock domains as
// toggles (fill_t here, take_t there).
//
// The fetcher uses the display's memory cycles (1 and 3 of each slot, and
// any cycle nobody else wants; dmac.v). Each word goes to the layer whose
// deadline is nearest (earliest deadline first): when a layer's shifters
// take a group, its countdown loads the time that group lasts (16 source
// pixels, about 59 system clocks x the horizontal scale). Layers with equal
// countdowns take turns.
//
// Line by line: at line_go (start of horizontal blank, from the pixel
// domain) the next line's fetch starts. Each word fetched moves the pointer
// on by 2. The line's first word saves the pointer (the line's start); its
// last word sets the pointer to that start + BPLSTRIDE, or back to the
// start on a repeated line of a vertically scaled layer. So how many words
// are fetched (whole groups, fine scroll) never matters, and every pointer
// move goes through the one fetch path: a CPU write in the same clock wins,
// and also sets the saved start.
//
// Tile layers (CTRL0.MODE = 1; spec 4, sections 4.5 and 5.2). A group is two
// tile columns of 8 source pixels. Its words are "slots": the two columns'
// pattern rows (into the data registers, as a bitmap group of the same
// depth: column 0 in the high registers), then the two map entries of the
// next group (into the layer's entry register, ent). So the entries are
// read one group ahead. The line starts with a group of entries only (group
// 0's), and its last group reads no entries. A group is complete (fill_t)
// with its last pattern word; the next group starts once its entries are
// in (busy). XFLIP reverses the row's pixels as they are stored, YFLIP
// picks the row. At 1 bit a row is one byte: each column's read keeps its
// byte, column 0 in the high half of data register 0. PAL and PRI of the
// group's two columns go to the pixel side beside the data registers
// (attr). The map line (y) and first column come from video.v; MAPPT and
// PATPT, like the other line settings, are taken at the start of the line.
// A tile layer never moves BPL0PT.
//
// Registers (spec 4, section 6.3), layer n at custom 0x090 + n x 0x20:
//   +0x10-0x11  BPLSTRIDE  signed, even (bit 0 reads 0)
//   +0x14-0x16  BPL0PT     bits 21-1, live; reading +0x14 captures all three
//                          bytes, and +0x15 and +0x16 of the same layer then
//                          read the captured bytes (spec 3, rule 4)
//   +0x18-0x1A  MAPPT      bits 21-1: the tile map's first entry
//   +0x1C-0x1E  PATPT      bits 21-1: tile 0's first byte
// Each byte is written directly (spec 3, rule 2).
//
// Reading BPL0PT's low byte hands the whole pointer to the CPU's one
// capture in the bus interface (rb_cdata, rb_cap; spec 3, rule 4), shared
// with BEAMPOS, FRAMECOUNT and the rest (ticket #53; until then this unit
// kept a capture of its own).
//
// Changed from retro68k: no planar layers (one pointer per layer, so the
// pointers and their saved starts are plain registers, not RAMs); no data
// register writes and no BPLDMA (spec 4, open point V5); byte registers;
// the urgent mark is set 2 clocks earlier, since an urgent fetch never takes
// the CPU's cycles (spec 2, open point M5); tile mode.

module bpldma_z80 #(
    parameter NL = 3                   // layers built (1-3): the others' registers read 0xFF and are never fetched
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          enable,       // video on, DMACON.DMAEN and BPLEN

    input  wire          rb_rd,
    input  wire          rb_wr,
    input  wire [12:0]   rb_addr,
    input  wire [7:0]    rb_wdata,
    output reg  [7:0]    rb_rdata,
    output reg           rb_hit,
    output reg  [31:0]   rb_cdata,     // with rb_rdata: BPL0PT whole, for the CPU's capture
    output reg           rb_cap,

    // The next line, from the pixel domain (stable when line_t toggles)
    input  wire          line_t,
    input  wire [2:0] act,          // the layer shows on the next line
    input  wire [2:0] adv,          // ... and its pointer moves on after it (last copy of a source line)
    input  wire [5:0] lbpp,       // log2 of bits per pixel: words per group = 1 << lbpp
    input  wire [5:0] hscale,     // log2 of the horizontal scale (for the deadlines)
    input  wire [11:0] wrap,       // CTRL2.WRAP: 0 off, n = the pointer wraps in 2^(n+9) bytes
    input  wire [35:0] ngroups,   // groups to fetch
    input  wire [2:0] tile,         // CTRL0.MODE: a tile map
    input  wire [5:0] mapw,       // CTRL3.MAPW: 32, 64, 128 (3 as 2) entries
    input  wire [29:0] ty,        // tiles: the map line (10 bits a layer)
    input  wire [20:0] tcol,      // tiles: the map column of the first group (7 bits a layer)
    output wire          line_go,      // 1 clock: a new line started here
    output wire          line_gen,     // toggles with line_go

    // To and from the pixel domain
    output wire [383:0] dat,      // 3 layers x 8 data registers x 16 bits, layer 0 register 0 lowest
    output wire [29:0]  attr,     // tiles: the group's {PRI, PAL} for column 1 (9-5) and column 0 (4-0), a layer
    output reg  [2:0] fill_t,
    input  wire [2:0] take_t,

    // The scheduler's layer channel (dmac.v)
    output reg           req,
    output wire          urgent,       // req must not wait
    output wire [9:0]    deadline,     // system clocks until req's data is needed
    output reg  [21:1]   addr,
    input  wire          ack,
    input  wire          rvalid,
    input  wire [15:0]   rdata
);
    // ---------------------------------------------------------------- registers
    // Layer n at custom 0x090 + n x 0x20 (bus address 0x1090 + ...)
    wire [7:0]  lo  = rb_addr[7:0] - 8'h90;
    wire [1:0]  rn  = lo[6:5];
    wire [4:0]  off = lo[4:0];
    wire        sel = (rb_addr[12:8] == 5'h10) && (rb_addr[7:0] >= 8'h90) && ({1'b0, lo[7:5]} < NL);
    wire        sel_mod = sel && (off == 5'h10 || off == 5'h11);
    wire        sel_pt  = sel && (off == 5'h14 || off == 5'h15 || off == 5'h16);
    wire        sel_map = sel && (off == 5'h18 || off == 5'h19 || off == 5'h1A);
    wire        sel_pat = sel && (off == 5'h1C || off == 5'h1D || off == 5'h1E);

    reg  [21:0] pt  [0:2];          // BPL0PT (bit 0 always 0)
    reg  [21:0] svm [0:2];          // its saved line start
    reg  [15:0] mod [0:2];          // BPLSTRIDE (bit 0 always 0)
    reg  [21:0] mappt [0:2];        // MAPPT (bit 0 always 0)
    reg  [21:0] patpt [0:2];        // PATPT (bit 0 always 0)

    // Pointer wrap (spec 4, section 4.4): only the bits below the block size
    // change; the block is aligned to its size
    wire [21:0] wmask [0:2];
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : wraps
        assign wmask[g] = (wrap[4*g +: 4] == 4'd0) ? 22'h3FFFFF
                        : ~(22'h3FFFFF << ({1'b0, wrap[4*g +: 4]} + 5'd9));
    end endgenerate
    function [21:0] wadd(input [21:0] p, input [21:0] d, input [21:0] m);
        wadd = (p & ~m) | ((p + d) & m);
    endfunction

    reg  [15:0] dr [0:23];         // the data registers
    reg  [9:0]  at [0:2];          // tiles: PAL and PRI beside them
    generate for (g = 0; g < 24; g = g + 1) begin : dout
        assign dat[16*g +: 16] = dr[g];
    end
    for (g = 0; g < 3; g = g + 1) begin : aout
        assign attr[10*g +: 10] = at[g];
    end endgenerate

    // ---------------------------------------------------------------- tiles
    // Taken at line_go: the line's mode, depth, map width, map row, pattern
    // row, MAPPT and PATPT; the entry column counts on from tcol
    reg  [2:0]  t_tile;
    reg  [1:0]  t_lb [0:2], t_mw [0:2];
    reg  [6:0]  t_row [0:2], ecol [0:2];
    reg  [2:0]  t_trow [0:2];
    reg  [21:0] t_map [0:2], t_pat [0:2];
    reg  [15:0] ent [0:5];          // ent[2n + c]: layer n's entries for the next group, column c
    // Worked out a clock ahead of use (an entry or a column moves at most
    // once every two clocks, and is used no sooner than two clocks after):
    // the map row's address, the next entry's address, and each column's
    // pattern row address (a byte address: at 1 bit, bit 0 picks the byte)
    reg  [21:0] rowbase [0:2], eaddr [0:2];
    reg  [21:0] pn [0:5];
    function [6:0] colmask(input [1:0] w);
        colmask = (w == 2'd0) ? 7'h1F : (w == 2'd1) ? 7'h3F : 7'h7F;
    endfunction
    always @(posedge clk) begin : tileaddr
        integer m, c;
        reg [2:0] tr;
        for (m = 0; m < 3; m = m + 1) begin
            rowbase[m] <= t_map[m] + ({15'd0, t_row[m]} << (4'd6 + ((t_mw[m] == 2'd3) ? 4'd2 : {2'd0, t_mw[m]})));
            eaddr[m]   <= rowbase[m] + {14'd0, ecol[m], 1'b0};
            for (c = 0; c < 2; c = c + 1) begin
                tr = ent[2*m + c][14] ? ~t_trow[m] : t_trow[m];              // YFLIP
                pn[2*m + c] <= t_pat[m] + ({13'd0, ent[2*m + c][8:0]} << (3'd3 + {1'b0, t_lb[m]}))
                                        + ({19'd0, tr} << t_lb[m]);
            end
        end
    end
    // A row's pixels reversed (XFLIP), d = 2, 4 or 8 bits a pixel
    function [15:0] pixrev(input [15:0] w, input [1:0] lb);
        integer b;
        begin
            pixrev = 16'd0;
            case (lb)
                2'd1:    for (b = 0; b < 8; b = b + 1) pixrev[2*b +: 2] = w[2*(7-b) +: 2];
                2'd2:    for (b = 0; b < 4; b = b + 1) pixrev[4*b +: 4] = w[4*(3-b) +: 4];
                default: pixrev = {w[7:0], w[15:8]};
            endcase
        end
    endfunction
    function [7:0] rev8(input [7:0] v);
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1) rev8[b] = v[7-b];
        end
    endfunction

    // ---------------------------------------------------------------- fetch state
    reg  [1:0]  line_s;
    assign line_go = line_s[1] != line_s[0];
    reg  [2:0] gen;
    assign line_gen = gen[0];
    (* ASYNC_REG = "TRUE" *) reg [2:0] take_s1, take_s2;
    reg  [2:0] take_s3;
    wire [2:0] full = fill_t ^ take_s2;

    reg  [11:0] left   [0:2];       // groups still to start
    reg  [11:0] ngr    [0:2];       // groups to fetch on this line (tiles: one more, the first group's entries)
    reg  [2:0] lastg;               // the group being fetched is the line's last
    reg  [9:0]  rem    [0:2];       // slots of the current group still to ask for
    reg  [2:0] busy;                // a group is on its way (until its last word arrives)
    reg  [2:0] pv_adv;              // the line being fetched: its pointer moves on after it

    // Reads on the way: layer, slot, the group's last pattern word (fill),
    // its last word (done), generation; tiles: XFLIP, the byte
    reg  [1:0]  q_layer [0:3];
    reg  [3:0]  q_slot  [0:3];
    reg         q_fill  [0:3];
    reg         q_last  [0:3];
    reg         q_gen   [0:3];
    reg         q_flip  [0:3];
    reg         q_bsel  [0:3];
    reg  [1:0]  q_h, q_t;

    // A group's slots, highest first: bits 9-2 data registers 7-0 (pattern
    // or bitmap words), bit 1 the next group's column 0 entry, bit 0 its
    // column 1 entry
    reg  [9:0]  gmask_l [0:2];
    always @(*) begin : masks
        integer m;
        reg [7:0] pm;
        for (m = 0; m < 3; m = m + 1) begin
            pm = 8'hFF >> (3'd7 - ((3'd1 << lbpp[2*m +: 2]) - 1'b1));          // 1 << lb words
            if (!t_tile[m])
                gmask_l[m] = {pm, 2'b00};
            else if (left[m] == ngr[m])
                gmask_l[m] = 10'b00_0000_0011;                                // the line's first: entries only
            else
                gmask_l[m] = {(lbpp[2*m +: 2] == 2'd0) ? 8'h03 : pm, (left[m] == 12'd1) ? 2'b00 : 2'b11};
        end
    end
    function [3:0] top(input [9:0] v);                 // highest set bit
        integer b;
        begin
            top = 4'd0;
            for (b = 0; b < 10; b = b + 1) if (v[b]) top = b[3:0];
        end
    endfunction

    // Deadlines: system clocks until each layer's shifters use up the group
    // they took last, so the next one must be in by then. The line's first
    // take (the group loaded ahead of the window) sets no deadline.
    reg  [9:0]  dl [0:2];
    reg  [2:0] first_take;
    reg  [1:0]  req_layer;
    reg         req_ent;               // req is a map entry: needed a group later
    function [3:0] ones(input [7:0] v);
        integer b;
        begin
            ones = 4'd0;
            for (b = 0; b < 8; b = b + 1) ones = ones + v[b];
        end
    endfunction
    // A request is urgent when its layer's deadline is close: the words
    // still to come at 50 ns each, plus about 160 ns for the wait for a
    // display cycle, the read and the crossing back (spec 4, section 5.3;
    // retro68k's 140 ns plus one memory cycle, as an urgent fetch here never
    // takes the CPU's cycles 0 and 2). A map entry is needed for the next
    // group's pattern rows: its deadline is a group later, and the next
    // group's pattern words count among those still to come.
    wire [9:0]  rq_rem     = rem[req_layer];
    wire [1:0]  rq_lb      = lbpp[2*req_layer +: 2];
    wire [4:0]  words_left = req_ent ? {4'd0, rq_rem[1]} + {4'd0, rq_rem[0]} + 5'd1
                                       + ((rq_lb == 2'd0) ? 5'd2 : (5'd1 << rq_lb))
                                     : {1'b0, ones(rq_rem[9:2])} + 5'd1;
    wire [10:0] dl_ent     = (dl[req_layer] == 10'h3FF) ? 11'h3FF
                           : {1'b0, dl[req_layer]} + ({5'd0, 6'd59} << hscale[2*req_layer +: 2]);
    wire [10:0] dl_req     = req_ent ? dl_ent : {1'b0, dl[req_layer]};
    assign      urgent   = req && (dl_req < 11'd16 + {4'd0, words_left, 2'b00} + {6'd0, words_left});
    assign      deadline = dl_req[10] ? 10'h3FF : dl_req[9:0];

    // A fetch takes two clocks, for timing (memory cycles are two clocks
    // apart, so this costs no bandwidth):
    //   A  pick the layer and its slot, and read the pointer and the saved
    //      line start;
    //   B  work out the address and the pointer's next value and write it,
    //      move the group counts on, and hand the request on: to req if it
    //      is free, else to a one-entry holding place (nxt).
    // B starts again from A if the line starts, or the CPU writes a pointer,
    // meanwhile.
    reg         phase;                 // 0: A, 1: B
    reg  [2:0] want;
    reg         dlt [0:8];             // dlt[3a + b]: dl[a] < dl[b]
    reg  [1:0]  pick, last;
    integer n, k;

    // Who asks next: of the layers with a group being asked for, or able to
    // start one, the one with the nearest deadline; on a tie, the next after
    // the last one served
    always @(*) begin : choose
        integer o;
        reg [1:0] c;
        reg       found;
        found = 1'b0;
        pick  = 2'd0;
        c     = last;
        for (o = 1; o <= 3; o = o + 1) begin
            c = (c == 2'd2) ? 2'd0 : c + 1'b1;      // round-robin order after the last
            if (want[c] && (!found || dlt[3*c + pick])) begin
                found = 1'b1;
                pick  = c;
            end
        end
    end
    // The slot to fill next: high to low
    reg         gs_l [0:2];
    reg  [9:0]  gm_l [0:2], rn_l [0:2];
    reg  [3:0]  sl_l [0:2];
    always @(*) begin : nextreg
        integer m;
        for (m = 0; m < 3; m = m + 1) begin
            gs_l[m] = (rem[m] == 10'd0);                           // a new group
            gm_l[m] = gs_l[m] ? gmask_l[m] : rem[m];
            sl_l[m] = top(gm_l[m]);
            rn_l[m] = gm_l[m] & ~(10'd1 << sl_l[m]);
        end
    end
    wire        gstart  = gs_l[pick];
    wire [9:0]  gmask   = gm_l[pick];
    wire [3:0]  sl_n    = sl_l[pick];
    wire [9:0]  rem_n   = rn_l[pick];
    wire [2:0]  pl_n    = sl_n[2:0] - 3'd2;                        // the data register (slots 9-2)

    // Tiles: the column a pattern slot belongs to, and which word of its row:
    // each column has k = max(1, d / 2) of the group's data registers,
    // column 0 the higher ones; a flipped row is stored backwards
    wire [1:0]  lbp     = lbpp[2*pick +: 2];
    wire [2:0]  kcol    = (lbp == 2'd0) ? 3'd1 : 3'd1 << (lbp - 1'b1);
    wire        pcol    = (pl_n < kcol);
    wire [2:0]  pbase   = pcol ? 3'd0 : kcol;
    wire        pflip   = ent[{pick, pcol}][13];
    wire [2:0]  pj      = pflip ? pl_n - pbase : pbase + kcol - 3'd1 - pl_n;

    // The line's first and last words: the first word of its first group,
    // the last word of its last group
    wire        first_w = gstart && (left[pick] == ngr[pick]);
    wire        last_w  = (gstart ? (left[pick] == 12'd1) : lastg[pick]) && rem_n == 10'd0;

    // A CPU write to a pointer byte: the live pointer with that byte changed
    wire        cpu_pw   = rb_wr && sel_pt;
    wire [21:0] cpu_old  = pt[rn];
    wire [21:0] cpu_new  = (off == 5'h14) ? {cpu_old[21:8], rb_wdata[7:1], 1'b0} :
                           (off == 5'h15) ? {cpu_old[21:16], rb_wdata, cpu_old[7:0]} :
                                            {rb_wdata[5:0], cpu_old[15:0]};

    // A: start a fetch
    wire        a_go     = !rst && !phase && !line_go && !cpu_pw && |want && gmask != 10'd0;
    reg  [1:0]  a_pick;
    reg  [3:0]  a_slot;
    reg         a_gstart, a_first_w, a_last_w, a_fill;
    reg  [9:0]  a_rem_n;
    reg  [21:0] a_pt, a_sv;
    reg         a_col, a_flip;
    reg  [2:0]  a_j;
    always @(posedge clk) if (a_go) begin
        a_pick    <= pick;
        a_slot    <= sl_n;
        a_gstart  <= gstart;
        a_rem_n   <= rem_n;
        a_fill    <= (sl_n >= 4'd2) && (rem_n[9:2] == 8'd0);
        a_first_w <= first_w;
        a_last_w  <= last_w;
        a_pt      <= pt[pick];
        a_sv      <= svm[pick];
        a_col     <= (sl_n >= 4'd2) ? pcol : !sl_n[0];          // an entry: slot 1 column 0, slot 0 column 1
        a_flip    <= pflip;
        a_j       <= pj;
    end

    // B: finish it, if there is room for the request
    reg         nxt_v;                 // the holding place
    reg  [1:0]  nxt_layer;
    reg  [3:0]  nxt_slot;
    reg         nxt_fill, nxt_last, nxt_gen, nxt_flip, nxt_bsel;
    reg  [21:1] nxt_addr;
    wire        b_abort  = line_go || cpu_pw;
    wire        b_go     = !rst && phase && !b_abort && !(req && !ack && nxt_v)
                           && (!a_gstart || left[a_pick] != 12'd0);
    wire        a_tile   = t_tile[a_pick];
    wire        a_ent    = (a_slot < 4'd2);
    wire [21:0] start    = a_first_w ? a_pt : a_sv;                // this line's start
    wire [21:0] stride   = pv_adv[a_pick] ? {{6{mod[a_pick][15]}}, mod[a_pick]} : 22'd0;
    wire [21:0] pt_next  = a_last_w ? wadd(start, stride, wmask[a_pick]) : wadd(a_pt, 22'd2, wmask[a_pick]);
    wire [21:0] prow     = pn[{a_pick, a_col}];
    wire [21:0] b_addr   = !a_tile ? a_pt : a_ent ? eaddr[a_pick] : prow + {18'd0, a_j, 1'b0};
    wire        b_bsel   = prow[0];

    // The data registers a word goes to, and the 1-bit tile row's byte
    wire [1:0]  r_layer  = q_layer[q_h];
    wire [3:0]  r_slot   = q_slot[q_h];
    wire [4:0]  r_reg    = {r_layer, r_slot[2:0] - 3'd2};
    wire [7:0]  r_byte0  = q_bsel[q_h] ? rdata[15:8] : rdata[7:0];
    wire [7:0]  r_byte   = q_flip[q_h] ? rev8(r_byte0) : r_byte0;
    wire [15:0] r_word   = (t_tile[r_layer] && q_flip[q_h]) ? pixrev({rdata[7:0], rdata[15:8]}, t_lb[r_layer])
                                                            : {rdata[7:0], rdata[15:8]};

    always @(posedge clk) begin
        for (n = 0; n < 3; n = n + 1) begin
            for (k = 0; k < 3; k = k + 1) dlt[3*n + k] <= dl[n] < dl[k];
            want[n] <= !rst && !line_go &&
                       ((b_go && a_pick == n) ? (a_rem_n != 10'd0)
                        : (rem[n] != 0) || (left[n] != 0 && !busy[n] && !full[n] && gmask_l[n] != 10'd0));
        end
        if (rst || line_go)  phase <= 1'b0;
        else if (a_go)       phase <= 1'b1;
        else if (b_go || b_abort) phase <= 1'b0;
    end

    always @(posedge clk) begin
        line_s  <= {line_s[0], line_t};
        take_s1 <= take_t;
        take_s2 <= take_s1;
        take_s3 <= take_s2;
        for (n = 0; n < 3; n = n + 1)
            if (take_s3[n] != take_s2[n]) begin                     // a group was taken
                dl[n] <= first_take[n] ? 10'h3FF : 10'd59 << hscale[2*n +: 2];
                first_take[n] <= 1'b0;
            end else if (dl[n] != 10'd0 && dl[n] != 10'h3FF) dl[n] <= dl[n] - 1'b1;
        if (rst) begin
            req    <= 1'b0;
            req_ent <= 1'b0;
            last   <= 2'd2;
            q_h    <= 2'd0;
            q_t    <= 2'd0;
            gen    <= 3'd0;
            fill_t <= 3'd0;
            busy   <= 3'd0;
            nxt_v  <= 1'b0;
            pv_adv <= 3'd0;
            lastg  <= 3'd0;
            t_tile <= 3'd0;
            first_take <= 3'd0;
            req_layer <= 2'd0;
            for (n = 0; n < 3; n = n + 1) begin
                left[n] <= 12'd0;  ngr[n] <= 12'd0;  rem[n] <= 10'd0;  dl[n] <= 10'h3FF;
                mod[n]  <= 16'd0;
                pt[n]   <= 22'd0;  svm[n] <= 22'd0;
                mappt[n] <= 22'd0; patpt[n] <= 22'd0;
                at[n]   <= 10'd0;
            end
            for (n = 0; n < 24; n = n + 1) dr[n] <= 16'd0;
        end else begin
            // Data back from the SRAM (little-endian: the even byte, the
            // pixels further left, into the high half; spec 4, section 4.2)
            if (rvalid) begin
                if (q_gen[q_h] == gen[r_layer]) begin
                    if (r_slot < 4'd2)                                 // a map entry, low byte first
                        ent[{r_layer, !r_slot[0]}] <= rdata;
                    else if (t_tile[r_layer] && t_lb[r_layer] == 2'd0) begin
                        // 1-bit tiles: the row's byte; column 0 (slot 3) high, column 1 low
                        if (r_slot[0]) dr[{r_layer, 3'd0}][15:8] <= r_byte;
                        else           dr[{r_layer, 3'd0}][7:0]  <= r_byte;
                    end else
                        dr[r_reg] <= r_word;
                    if (q_fill[q_h]) fill_t[r_layer] <= ~fill_t[r_layer];
                    if (q_last[q_h]) busy[r_layer]   <= 1'b0;
                end
                q_h <= q_h + 1'b1;
            end

            // A request was taken
            if (ack) begin
                req <= 1'b0;
                q_t <= q_t + 1'b1;
            end

            if (line_go) begin
                // Start the next line
                for (n = 0; n < 3; n = n + 1) begin
                    left[n]   <= (enable && act[n] && ngroups[12*n +: 12] != 12'd0) ? ngroups[12*n +: 12] + {11'd0, tile[n]} : 12'd0;
                    ngr[n]    <= (enable && act[n] && ngroups[12*n +: 12] != 12'd0) ? ngroups[12*n +: 12] + {11'd0, tile[n]} : 12'd0;
                    rem[n]    <= 10'd0;
                    dl[n]     <= 10'h3FF;                     // no deadline until the first in-window take
                    first_take[n] <= 1'b1;
                    fill_t[n] <= take_s2[n];                 // empty: last line's spare group is dropped
                    t_lb[n]   <= lbpp[2*n +: 2];
                    t_mw[n]   <= mapw[2*n +: 2];
                    t_row[n]  <= ty[10*n + 3 +: 7];
                    t_trow[n] <= ty[10*n +: 3];
                    ecol[n]   <= tcol[7*n +: 7];
                    t_map[n]  <= mappt[n];
                    t_pat[n]  <= patpt[n];
                end
                t_tile <= tile;
                pv_adv <= adv;
                busy   <= 3'd0;
                gen    <= ~gen;
                req    <= 1'b0;
                nxt_v  <= 1'b0;
            end else begin
                // The next request: from the holding place, else from B, as
                // soon as req is free (or being taken now)
                if (!req || ack) begin
                    if (nxt_v) begin
                        req       <= 1'b1;
                        req_layer <= nxt_layer;
                        req_ent   <= (nxt_slot < 4'd2);
                        addr      <= nxt_addr;
                        q_layer[q_t + (ack ? 1'b1 : 1'b0)] <= nxt_layer;
                        q_slot[q_t + (ack ? 1'b1 : 1'b0)]  <= nxt_slot;
                        q_fill[q_t + (ack ? 1'b1 : 1'b0)]  <= nxt_fill;
                        q_last[q_t + (ack ? 1'b1 : 1'b0)]  <= nxt_last;
                        q_gen[q_t + (ack ? 1'b1 : 1'b0)]   <= nxt_gen;
                        q_flip[q_t + (ack ? 1'b1 : 1'b0)]  <= nxt_flip;
                        q_bsel[q_t + (ack ? 1'b1 : 1'b0)]  <= nxt_bsel;
                        nxt_v     <= b_go;
                    end else if (b_go) begin
                        req       <= 1'b1;
                        req_layer <= a_pick;
                        req_ent   <= a_ent;
                        addr      <= b_addr[21:1];
                        q_layer[q_t + (ack ? 1'b1 : 1'b0)] <= a_pick;
                        q_slot[q_t + (ack ? 1'b1 : 1'b0)]  <= a_slot;
                        q_fill[q_t + (ack ? 1'b1 : 1'b0)]  <= a_fill;
                        q_last[q_t + (ack ? 1'b1 : 1'b0)]  <= (a_rem_n == 10'd0);
                        q_gen[q_t + (ack ? 1'b1 : 1'b0)]   <= gen[a_pick];
                        q_flip[q_t + (ack ? 1'b1 : 1'b0)]  <= a_flip;
                        q_bsel[q_t + (ack ? 1'b1 : 1'b0)]  <= b_bsel;
                    end
                end else if (b_go)
                    nxt_v <= 1'b1;
                // B: the word is asked for
                if (b_go) begin
                    nxt_layer <= a_pick;
                    nxt_slot  <= a_slot;
                    nxt_fill  <= a_fill;
                    nxt_last  <= (a_rem_n == 10'd0);
                    nxt_gen   <= gen[a_pick];
                    nxt_flip  <= a_flip;
                    nxt_bsel  <= b_bsel;
                    nxt_addr  <= b_addr[21:1];
                    last      <= a_pick;
                    rem[a_pick] <= a_rem_n;
                    if (a_gstart) begin
                        left[a_pick]   <= left[a_pick] - 1'b1;
                        lastg[a_pick]  <= (left[a_pick] == 12'd1);
                        busy[a_pick]   <= 1'b1;
                        // A tile group's PAL and PRI, from the entries it uses
                        if (a_tile && !a_ent)
                            at[a_pick] <= {ent[{a_pick, 1'b1}][15], ent[{a_pick, 1'b1}][12:9],
                                           ent[{a_pick, 1'b0}][15], ent[{a_pick, 1'b0}][12:9]};
                    end
                    if (a_tile && a_ent)
                        ecol[a_pick] <= (ecol[a_pick] + 1'b1) & colmask(t_mw[a_pick]);
                end
            end

            // The pointer: a CPU write wins over the fetcher's own change,
            // and also sets the saved start. A tile layer leaves it alone.
            if (cpu_pw) begin
                pt[rn]  <= cpu_new;
                svm[rn] <= cpu_new;
            end else if (b_go && !a_tile) begin
                pt[a_pick] <= pt_next;
                if (a_first_w) svm[a_pick] <= a_pt;
            end
            if (rb_wr && sel_mod) begin
                if (off == 5'h10) mod[rn][7:1]  <= rb_wdata[7:1];
                else              mod[rn][15:8] <= rb_wdata;
            end
            if (rb_wr && sel_map) case (off)
                5'h18:   mappt[rn][7:1]   <= rb_wdata[7:1];
                5'h19:   mappt[rn][15:8]  <= rb_wdata;
                default: mappt[rn][21:16] <= rb_wdata[5:0];
            endcase
            if (rb_wr && sel_pat) case (off)
                5'h1C:   patpt[rn][7:1]   <= rb_wdata[7:1];
                5'h1D:   patpt[rn][15:8]  <= rb_wdata;
                default: patpt[rn][21:16] <= rb_wdata[5:0];
            endcase
        end
    end

    // ---------------------------------------------------------------- reads
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && (sel_mod || sel_pt || sel_map || sel_pat);
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        if (rb_rd && sel_mod) rb_rdata <= (off == 5'h10) ? mod[rn][7:0] : mod[rn][15:8];
        if (rb_rd && sel_map) case (off)
            5'h18:   rb_rdata <= mappt[rn][7:0];
            5'h19:   rb_rdata <= mappt[rn][15:8];
            default: rb_rdata <= {2'd0, mappt[rn][21:16]};
        endcase
        if (rb_rd && sel_pat) case (off)
            5'h1C:   rb_rdata <= patpt[rn][7:0];
            5'h1D:   rb_rdata <= patpt[rn][15:8];
            default: rb_rdata <= {2'd0, patpt[rn][21:16]};
        endcase
        if (rb_rd && sel_pt) case (off)
            5'h14: begin
                rb_rdata <= pt[rn][7:0];
                rb_cdata <= {10'd0, pt[rn]};
                rb_cap   <= 1'b1;
            end
            5'h15:   rb_rdata <= pt[rn][15:8];
            default: rb_rdata <= {2'd0, pt[rn][21:16]};
        endcase
    end
endmodule
