// Layer fetch (docs/spec/layer_fetch.md): reads each layer's words from
// memory, a 16-pixel group at a time, into the layer's data registers,
// where layer_pix.v takes them. System clock.
//
// NL layers, one requester on the memory scheduler (dmac.v) for all of
// them: the layer with the nearest deadline asks next. Each layer's data
// registers hold its next group while its shifters show the current one;
// full and taken cross between the clock domains as toggles (fill_t here,
// take_t there).
//
// No bus registers. The machine keeps its register file and drives the
// settings as ports; the live pointers are inside, behind one addressed
// write and read port, as they count on with every word read. Options:
//   PLANAR    planar layers, one pointer a plane
//   TILES     tile layers: chunky pattern rows picked by a map, the map
//             entries read a group ahead
//   DATWRITE  writes into the data registers, and a fetch enable per
//             register (retro68k's BPLxDAT and BPLDMA)
//   DATREAD   0: with DATWRITE, no read-back of the data registers
//             (dat_rdata is 0)
//   LITTLE    little-endian memory: a data word's bytes swap as it is stored
//
// Line by line: line_t (from the pixel clock) toggles at the start of each
// horizontal blank; two clocks later line_go starts the next line's fetch.
// Each word read moves its pointer on by 2; nothing counts the words. At
// each line_go the line ends: every pointer read from since its last
// reset or write is reset, one a clock, to its line start + stride (or back
// to the start on a repeated line), which is also the next line's start,
// before the new line's first group is set up. So how much of a line was
// fetched never matters to where the next one starts, and a pointer
// written after its last read (a split screen) starts the next line as
// written.
//
// A group's depth, planar flag and scale are taken as it starts (stage A
// of its first word), from a one-clock register of the settings, and go
// out with it in gset for layer_pix: a setting the machine changes applies
// from a layer's next group, never inside one, and the two cores always
// agree about a group.
//
// A fetch takes two clocks, A then B (spec 4.8); memory cycles are two
// clocks apart, so this costs nothing. urgent is a register: the compare
// for the request that req carries in this clock, with the deadline of
// the clock before (spec 4.4).
module layer_fetch #(
    parameter NL       = 3,                    // layers
    parameter AW       = 21,                   // word address width
    parameter PW       = 22,                   // pointer width (byte address), >= AW + 1
    parameter PLANAR   = 1,
    parameter TILES    = 0,
    parameter DATWRITE = 0,
    parameter DATREAD  = 1,
    parameter LITTLE   = 0,
    parameter URG_BASE = 15,                   // urgent mark: clocks ...
    parameter URG_WORD = 5,                    // ... plus this many a word still to come
    parameter LW       = (NL > 1) ? $clog2(NL) : 1
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              enable,

    // The line
    input  wire              line_t,
    output wire              line_go,
    output wire              line_gen,

    // Line settings, a field a layer (spec section 2 says which are copied
    // at line_go and which are read live)
    input  wire [NL-1:0]     act,
    input  wire [NL-1:0]     adv,
    input  wire [3*NL-1:0]   depth,          // words a group - 1
    input  wire [NL-1:0]     planar,
    input  wire [2*NL-1:0]   hscale,
    input  wire [4*NL-1:0]   wrap,
    input  wire [16*NL-1:0]  stride,
    input  wire [12*NL-1:0]  ngroups,
    input  wire [NL-1:0]     tile,
    input  wire [2*NL-1:0]   mapw,
    input  wire [10*NL-1:0]  ty,
    input  wire [7*NL-1:0]   tcol,
    input  wire [PW*NL-1:0]  mappt,
    input  wire [PW*NL-1:0]  patpt,

    // The pointers: {layer, plane}
    input  wire [LW+2:0]     ptr_sel,
    input  wire              ptr_wr,
    input  wire [PW-1:0]     ptr_wdata,
    output wire [PW-1:0]     ptr_rdata,

    // The data registers, from the machine (DATWRITE): {layer, register}
    input  wire              dat_wr,
    input  wire [LW+2:0]     dat_sel,
    input  wire [15:0]       dat_wdata,
    input  wire [1:0]        dat_be,
    input  wire [8*NL-1:0]   dma_en,
    output wire [15:0]       dat_rdata,

    // To layer_pix
    output wire [128*NL-1:0] dat,
    output wire [10*NL-1:0]  attr,
    output wire [6*NL-1:0]   gset,       // the group's settings: {hscale, depth, planar} a layer
    output reg  [NL-1:0]     fill_t,
    input  wire [NL-1:0]     take_t,

    // The memory scheduler
    output reg               req,
    output reg               urgent,
    output reg  [AW-1:0]     addr,
    input  wire              ack,
    input  wire              rvalid,
    input  wire [15:0]       rdata
);
    localparam PIW = (PLANAR != 0) ? LW + 3 : LW;     // a pointer's index: {layer, plane}, or the layer
    localparam [31:0] NP  = 32'd1 << PIW;              // pointers (a power of two, for the index width)
    localparam [31:0] NPV = (PLANAR != 0) ? 8 * NL : NL;   // ... of which these exist
    localparam [31:0] DRN = 32'd1 << (LW + 3);         // data registers, likewise; 8 a layer are used
    localparam [31:0] ENN = 32'd1 << (LW + 1);         // tile entries, two a layer
    localparam [9:0] DL_NONE = 10'h3FF;
    localparam [31:0]   LASTI = NL - 1;
    localparam [LW-1:0] LAST0 = LASTI[LW-1:0];           // the round robin starts at layer 0

    integer n, k;
    genvar g;

    // ---------------------------------------------------------------- helpers
    function [1:0] lb_of;                      // log2 of bits a pixel, from words - 1
        input [2:0] d;
        lb_of = d[2] ? 2'd3 : d[1] ? 2'd2 : d[0] ? 2'd1 : 2'd0;
    endfunction
    function [3:0] top;                        // highest set bit
        input [9:0] v;
        integer b;
        begin
            top = 4'd0;
            for (b = 0; b < 10; b = b + 1) if (v[b]) top = b[3:0];
        end
    endfunction
    function [3:0] ones;
        input [7:0] v;
        integer b;
        begin
            ones = 4'd0;
            for (b = 0; b < 8; b = b + 1) ones = ones + {3'd0, v[b]};
        end
    endfunction
    function [PW-1:0] wadd;                    // add within the wrap block
        input [PW-1:0] p, d, m;
        wadd = (p & ~m) | ((p + d) & m);
    endfunction
    function [PW-1:0] wmask_of;
        input [3:0] w;
        wmask_of = (w == 4'd0) ? {PW{1'b1}} : ~({PW{1'b1}} << ({1'b0, w} + 5'd9));
    endfunction
    function [6:0] colmask;
        input [1:0] w;
        colmask = (w == 2'd0) ? 7'h1F : (w == 2'd1) ? 7'h3F : 7'h7F;
    endfunction
    function [15:0] pixrev;                    // a row's pixels reversed, 2, 4 or 8 bits each
        input [15:0] w;
        input [1:0]  lb;
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
    function [7:0] rev8;
        input [7:0] v;
        integer b;
        for (b = 0; b < 8; b = b + 1) rev8[b] = v[7-b];
    endfunction

    // ---------------------------------------------------------------- the line
    reg  [2:0]  lsync;                         // line_t through two flip-flops, then compared
    assign line_go = lsync[2] != lsync[1];
    reg         gen;                           // the line's generation: reads from an old line are dropped
    assign line_gen = gen;

    reg  [NL-1:0] take_s1, take_s2, take_s3;
    wire [NL-1:0] full = fill_t ^ take_s2;

    // ---------------------------------------------------------------- storage
    reg  [PW-1:0] pt  [0:NP-1];                // the pointers ...
    reg  [PW-1:0] svm [0:NP-1];                // ... and their saved line starts (not reset)
    reg  [15:0]   dr  [0:DRN-1];               // the data registers
    reg  [9:0]    at  [0:NL-1];                // tiles: {PRI, PAL} of columns 1 and 0
    reg  [15:0]   ent [0:ENN-1];               // tiles: the next group's entries, ent[2n + c]
    initial begin : init_ptrs                  // for simulation; synthesis may keep or drop it
        integer q;
        for (q = 0; q < NP; q = q + 1) begin pt[q] = {PW{1'b0}}; svm[q] = {PW{1'b0}}; end
    end

    generate
        for (g = 0; g < 8*NL; g = g + 1) begin : dout
            assign dat[16*g +: 16] = dr[g];
        end
        for (g = 0; g < NL; g = g + 1) begin : aout
            assign attr[10*g +: 10] = (TILES != 0) ? at[g] : 10'd0;
        end
    endgenerate
    // Only the 8 x NL registers there are: the index is padded to a power of
    // two, and a register number past the last layer's must build nothing
    wire          ds_ok = ({{(29-LW){1'b0}}, dat_sel} < 8 * NL);
    assign dat_rdata = ((DATWRITE != 0) && (DATREAD != 0) && ds_ok) ? dr[dat_sel] : 16'd0;

    // ---------------------------------------------------------------- line state
    reg  [11:0]   left [0:NL-1];               // groups still to start
    reg  [11:0]   ngr  [0:NL-1];               // groups to fetch on this line
    reg  [9:0]    rem  [0:NL-1];               // slots of the current group still to ask for
    reg  [NL-1:0] busy;                        // a group is on its way (until its last word arrives)
    reg  [NL-1:0] pv_adv;                      // the line's pointers move on after it
    reg  [9:0]    dl   [0:NL-1];               // deadline: clocks until the group taken last is used up
    reg  [NL-1:0] first_take;

    // Tiles: copied at line_go
    reg  [NL-1:0] t_tile;
    reg  [1:0]    t_mw [0:NL-1];
    reg  [6:0]    t_row [0:NL-1], ecol [0:NL-1];
    reg  [2:0]    t_trow [0:NL-1];
    reg  [PW-1:0] t_map [0:NL-1], t_pat [0:NL-1];
    // Tiles: addresses worked out a clock ahead of use
    reg  [PW-1:0] rowbase [0:NL-1], eaddr [0:NL-1];
    reg  [PW-1:0] pn [0:ENN-1];

    // The settings a group takes as it starts: registered a clock (rs_*),
    // and kept for the group (g_*). With DATWRITE the fetch enables, with
    // the depth in them, are registered the same way (em).
    reg  [2:0]    rs_dep [0:NL-1], g_dep [0:NL-1];
    reg  [1:0]    rs_hs  [0:NL-1], g_hs  [0:NL-1];
    reg  [NL-1:0] rs_pl, g_pl;
    reg  [7:0]    em [0:NL-1];
    // The settings for a layer's word: a new group's are the registered
    // ones (it takes them now), a started group's its own
    wire [NL-1:0] newg;                                  // rem == 0
    reg  [2:0]    e_dep [0:NL-1];
    reg  [1:0]    e_lb  [0:NL-1];
    reg  [NL-1:0] e_pl;
    always @(*) begin
        for (n = 0; n < NL; n = n + 1) begin
            e_dep[n] = newg[n] ? rs_dep[n] : g_dep[n];
            e_lb[n]  = lb_of(e_dep[n]);
            e_pl[n]  = newg[n] ? rs_pl[n] : g_pl[n];
        end
    end
    // Declared above, so the per-layer assigns come after (Icarus needs a
    // signal declared before use)
    generate
        for (g = 0; g < NL; g = g + 1) begin : gout
            assign gset[6*g +: 6] = {g_hs[g], g_dep[g], g_pl[g]};
            assign newg[g]        = (rem[g] == 10'd0);
        end
    endgenerate

    // The registers a group fills (slots 9-2), and for a tile layer the
    // entries it reads (slots 1, 0): highest first
    reg  [7:0]    used_l  [0:NL-1];            // the data registers the depth uses
    reg  [7:0]    en_l    [0:NL-1];            // ... of which the fetch fills (live, for the line start)
    reg  [9:0]    gmask_l [0:NL-1];
    reg  [7:0]    used_r  [0:NL-1];            // ... as registered, for the group mask
    always @(*) begin
        for (n = 0; n < NL; n = n + 1) begin
            used_l[n] = 8'hFF >> (3'd7 - depth[3*n +: 3]);
            used_r[n] = 8'hFF >> (3'd7 - rs_dep[n]);
            if (DATWRITE != 0)
                en_l[n] = ((PLANAR != 0) && planar[n]) ? (dma_en[8*n +: 8] & used_l[n])
                                                        : (dma_en[8*n] ? used_l[n] : 8'd0);
            else
                en_l[n] = used_l[n];
            if ((TILES != 0) && t_tile[n]) begin
                if (left[n] == ngr[n])
                    gmask_l[n] = 10'b00_0000_0011;                   // the line's first: entries only
                else
                    gmask_l[n] = {(lb_of(rs_dep[n]) == 2'd0) ? 8'h03 : used_r[n],
                                  (left[n] == 12'd1) ? 2'b00 : 2'b11};
            end else
                gmask_l[n] = {(DATWRITE != 0) ? em[n] : used_r[n], 2'b00};   // em already has the depth in it
        end
    end

    // ---------------------------------------------------------------- who asks next
    reg  [NL-1:0]    want;
    reg              dlt [0:NL*NL-1];           // dlt[NL a + b]: dl[a] < dl[b]
    reg  [LW-1:0]    pick, last;
    always @(*) begin : choose
        integer o;
        reg [LW-1:0] c;
        reg          found;
        found = 1'b0;
        pick  = {LW{1'b0}};
        c     = last;
        for (o = 0; o < NL; o = o + 1) begin
            c = (c == NL - 1) ? {LW{1'b0}} : c + 1'b1;            // round robin after the last served
            if (want[c] && (!found || dlt[NL*c + pick])) begin
                found = 1'b1;
                pick  = c;
            end
        end
    end
    // The slot to fill next, worked out once, for the layer picked
    wire [9:0]    rem_p   = rem[pick];
    wire          gstart  = (rem_p == 10'd0);                       // a new group
    wire [9:0]    gmask   = gstart ? gmask_l[pick] : rem_p;
    wire [3:0]    sl_n    = top(gmask);
    wire [9:0]    rem_n   = gmask & ~(10'd1 << sl_n);
    wire [2:0]    pl_n    = sl_n[2:0] - 3'd2;                       // the data register (slots 9-2)
    wire          perpl   = (PLANAR != 0) && e_pl[pick];            // a pointer a plane
    wire [PIW-1:0] pi;                                               // the pointer the pick reads
    wire [PIW-1:0] wi;                                               // the pointer ptr_sel names
    generate
        if (PLANAR != 0) begin : ptr_planar
            assign pi = {pick, perpl ? pl_n : 3'd0};
            assign wi = ptr_sel;
        end else begin : ptr_layer
            assign pi = pick;
            assign wi = ptr_sel[LW+2:3];
        end
    endgenerate

    assign ptr_rdata = pt[wi];

    // Tiles: the column a pattern slot belongs to, and which word of its row
    wire [1:0]    lbp     = e_lb[pick];
    wire [2:0]    kcol    = (lbp == 2'd0) ? 3'd1 : 3'd1 << (lbp - 1'b1);
    wire          pcol    = (pl_n < kcol);                           // 1: column 1 (the lower registers)
    wire [2:0]    pbase   = pcol ? 3'd0 : kcol;
    wire          pflip   = ent[{pick, pcol}][13];
    wire [2:0]    pj      = pflip ? pl_n - pbase : pbase + kcol - 3'd1 - pl_n;

    // ---------------------------------------------------------------- A: start a fetch
    reg           phase;                        // 0: A, 1: B
    reg           cu_act, c_v;                  // the line-end resets are being made (below)
    wire          a_go  = !rst && !phase && !line_go && !ptr_wr && !cu_act && !c_v && |want && gmask != 10'd0;
    reg  [LW-1:0] a_pick;
    reg  [3:0]    a_slot;
    reg  [PIW-1:0] a_pi;
    reg           a_gstart, a_fill, a_col, a_flip;
    reg  [9:0]    a_rem_n;
    reg  [2:0]    a_j;
    reg  [PW-1:0] a_pt;
    // The settings a group takes as it starts. Each register has one
    // always block, its reset included: two blocks driving one register
    // simulate fine but do not synthesise (drivers.sh checks it)
    always @(posedge clk) begin
        if (rst) begin
            g_pl <= {NL{1'b0}};
            for (n = 0; n < NL; n = n + 1) begin g_dep[n] <= 3'd0;  g_hs[n] <= 2'd0; end
        end else if (a_go && gstart) begin
            g_dep[pick] <= rs_dep[pick];
            g_hs[pick]  <= rs_hs[pick];
            g_pl[pick]  <= rs_pl[pick];
        end
    end
    always @(posedge clk) if (a_go) begin
        a_pick    <= pick;
        a_slot    <= sl_n;
        a_pi      <= pi;
        a_gstart  <= gstart;
        a_rem_n   <= rem_n;
        a_fill    <= (sl_n >= 4'd2) && (rem_n[9:2] == 8'd0);        // the group's last pattern word
        a_pt      <= pt[pi];
        a_col     <= (sl_n >= 4'd2) ? pcol : !sl_n[0];              // an entry: slot 1 column 0, slot 0 column 1
        a_flip    <= pflip;
        a_j       <= pj;
    end

    // ---------------------------------------------------------------- B: finish it
    reg           nxt_v;                        // the one-entry holding place
    reg  [LW-1:0] nxt_layer;
    reg  [3:0]    nxt_slot;
    reg           nxt_fill, nxt_last, nxt_gen, nxt_flip, nxt_bsel;
    reg  [AW-1:0] nxt_addr;
    wire          b_abort = line_go || ptr_wr;
    wire          b_go    = !rst && phase && !b_abort && !(req && !ack && nxt_v)
                            && (!a_gstart || left[a_pick] != 12'd0);
    wire          a_tile  = (TILES != 0) && t_tile[a_pick];
    wire          a_ent   = (TILES != 0) && (a_slot < 4'd2);
    wire [PW-1:0] pt_next;                                          // a_pt + 2 (the shared adder, below)
    wire [PW-1:0] prow    = pn[{a_pick, a_col}];
    wire [PW-1:0] b_addr  = !a_tile ? a_pt : a_ent ? eaddr[a_pick] : prow + {{(PW-4){1'b0}}, a_j, 1'b0};
    wire          b_bsel  = prow[0];

    // ---------------------------------------------------------------- line-end reset
    // uf: a word has been read from the pointer since its last reset or
    // write. From line_go every pointer there is (cu_q from 0) is looked at
    // in turn: C1 reads its line start, C2 writes start (+ stride if the
    // ended line's adv) to the pointer and its line start if its flag is
    // set, and clears the flag. One a clock; a ptr_wr holds C1 and C2 for
    // its clock (the write port is the machine's), and clears the written
    // pointer's flag, so a pointer written after its last read keeps the
    // written value (a split screen).
    reg  [NL-1:0] cu_adv;                       // the ended line's adv
    reg  [PIW-1:0] cu_q, c_q;
    reg  [PW-1:0] c_sv;
    reg  [NP-1:0] uf;                           // used: read since its last reset or write
    wire [LW-1:0] c_l    = (PLANAR != 0) ? c_q[PIW-1:PIW-LW] : c_q[LW-1:0];
    wire [15:0]   c_mod  = stride[16*c_l +: 16];
    // One adder for both pointer moves: + 2 for a word read (stage B), or the
    // line start + stride for a reset (C2). They are never in the same clock:
    // stage A holds from line_go until the resets are done
    wire [LW-1:0] ad_l   = c_v ? c_l : a_pick;
    wire [PW-1:0] ad_a   = c_v ? c_sv : a_pt;
    wire [PW-1:0] ad_d   = !c_v ? {{(PW-2){1'b0}}, 2'd2}
                         : cu_adv[c_l] ? {{(PW-16){c_mod[15]}}, c_mod[15:1], 1'b0} : {PW{1'b0}};
    wire [PW-1:0] ad_y   = wadd(ad_a, ad_d, wmask_of(wrap[4*ad_l +: 4]));
    wire [PW-1:0] c_next = ad_y;
    assign        pt_next = ad_y;
    wire          c2_go  = c_v && !ptr_wr;
    wire          c2_wr  = c2_go && uf[c_q];
    wire          c1_go  = cu_act && !ptr_wr && (!c_v || c2_go);
    wire          cu_last = ({{(32-PIW){1'b0}}, cu_q} == NPV - 32'd1);   // the last pointer there is

    always @(posedge clk) begin
        if (c1_go) begin
            c_q  <= cu_q;
            c_sv <= svm[cu_q];
        end
        if (rst) begin
            cu_act <= 1'b0;  c_v <= 1'b0;  uf <= {NP{1'b0}};  cu_q <= {PIW{1'b0}};  cu_adv <= {NL{1'b0}};
        end else begin
            if (line_go) begin
                cu_act <= 1'b1;  c_v <= 1'b0;  cu_q <= {PIW{1'b0}};
                cu_adv <= pv_adv;                                   // the ended line's
            end else begin
                if (c1_go) begin
                    if (cu_last) cu_act <= 1'b0;
                    else         cu_q   <= cu_q + 1'b1;
                end
                if (c1_go)      c_v <= 1'b1;
                else if (c2_go) c_v <= 1'b0;
            end
            if (b_go && !a_tile) uf[a_pi] <= 1'b1;                  // a word read (never in a line_go clock)
            if (c2_wr)           uf[c_q]  <= 1'b0;                  // reset
            if (ptr_wr)          uf[wi]   <= 1'b0;                  // written
        end
    end

    // The pointer: a write from the machine wins over the fetch's own moves
    // and sets the line start too. A tile layer leaves its pointer alone.
    always @(posedge clk) begin
        if (ptr_wr) begin
            pt[wi]  <= {ptr_wdata[PW-1:1], 1'b0};
            svm[wi] <= {ptr_wdata[PW-1:1], 1'b0};
        end else if (c2_wr) begin
            pt[c_q]  <= c_next;
            svm[c_q] <= c_next;
        end else if (b_go && !a_tile) begin
            pt[a_pi] <= pt_next;
        end
    end

    // Deadline comparisons, wants and the fetch enables: registered a clock
    // before use (for timing). want follows B's own change; anything else
    // only makes a decision late, not wrong.
    always @(posedge clk) begin
        for (n = 0; n < NL; n = n + 1) begin
            em[n]     <= en_l[n];
            rs_dep[n] <= depth[3*n +: 3];
            rs_hs[n]  <= hscale[2*n +: 2];
            rs_pl[n]  <= (PLANAR != 0) && planar[n];
            for (k = 0; k < NL; k = k + 1) dlt[NL*n + k] <= dl[n] < dl[k];
            want[n] <= !rst && !line_go &&
                       ((b_go && a_pick == n) ? (a_rem_n != 10'd0)
                        : (rem[n] != 10'd0) || (left[n] != 12'd0 && !busy[n] && !full[n] && gmask_l[n] != 10'd0));
        end
        if (rst || line_go)       phase <= 1'b0;
        else if (a_go)            phase <= 1'b1;
        else if (b_go || b_abort) phase <= 1'b0;
    end

    // Tiles: the map row's address, the next entry's, and each column's pattern row
    always @(posedge clk) begin : tileaddr
        integer m, c;
        reg [2:0]    tr;
        reg [3:0]    sh;
        for (m = 0; m < NL; m = m + 1) begin
            sh = 4'd6 + ((t_mw[m] == 2'd3) ? 4'd2 : {2'd0, t_mw[m]});
            rowbase[m] <= t_map[m] + ({{(PW-7){1'b0}}, t_row[m]} << sh);
            eaddr[m]   <= rowbase[m] + {{(PW-8){1'b0}}, ecol[m], 1'b0};
            for (c = 0; c < 2; c = c + 1) begin
                tr = ent[2*m + c][14] ? ~t_trow[m] : t_trow[m];                        // YFLIP
                pn[2*m + c] <= t_pat[m] + ({{(PW-9){1'b0}}, ent[2*m + c][8:0]} << (3'd3 + {1'b0, e_lb[m]}))
                                        + ({{(PW-3){1'b0}}, tr} << e_lb[m]);
            end
        end
    end

    // ---------------------------------------------------------------- the request, and the data back
    // Reads on their way: layer, slot, completes the group, the group's last
    // word, generation; tiles: XFLIP and which byte
    reg  [LW-1:0] q_layer [0:3];
    reg  [3:0]    q_slot  [0:3];
    reg           q_fill  [0:3], q_last [0:3], q_gen [0:3], q_flip [0:3], q_bsel [0:3];
    reg  [1:0]    q_h, q_t;
    wire [1:0]    q_w = q_t + (ack ? 2'd1 : 2'd0);                  // where the next read is noted

    reg  [LW-1:0] req_layer;
    reg           req_ent;                                          // req is a map entry: due a group later

    wire [LW-1:0] r_layer = q_layer[q_h];
    wire [3:0]    r_slot  = q_slot[q_h];
    wire [LW+2:0] r_reg   = {r_layer, r_slot[2:0] - 3'd2};
    wire [15:0]   r_sw    = (LITTLE != 0) ? {rdata[7:0], rdata[15:8]} : rdata;
    wire          r_hi    = (LITTLE != 0) ? q_bsel[q_h] : !q_bsel[q_h];   // the byte the address names
    wire [7:0]    r_byte0 = r_hi ? rdata[15:8] : rdata[7:0];
    wire [7:0]    r_byte  = q_flip[q_h] ? rev8(r_byte0) : r_byte0;
    wire          r_tile  = (TILES != 0) && t_tile[r_layer];
    wire [15:0]   r_word  = (r_tile && q_flip[q_h]) ? pixrev(r_sw, lb_of(g_dep[r_layer])) : r_sw;
    wire          r_ok    = rvalid && (q_gen[q_h] == gen);
    wire          r_ent   = r_ok && (TILES != 0) && r_slot < 4'd2;
    wire          r_b1    = r_ok && !r_ent && r_tile && g_dep[r_layer] == 3'd0;  // a 1-bit tile row's byte
    wire          r_wr    = r_ok && !r_ent && !r_b1;

    // DATWRITE: nothing of the layer is fetched (judged live), so a write of
    // register 0's low byte completes the group
    wire          r_lok    = ({{(32-LW){1'b0}}, r_layer} < NL);     // (always: says so to synthesis)
    // The data registers have one write port. A fetched word goes in as it
    // comes; a machine write (DATWRITE) is held and goes in on the first
    // clock with no fetched word, so all the registers share one choice of
    // data. One write is held at a time: another dat_wr replaces it.
    reg           h_v;                                              // a machine write waits
    reg  [LW+2:0] h_sel;
    reg  [15:0]   h_d;
    reg  [1:0]    h_be;
    wire          f_wr  = rvalid && r_lok && (r_b1 || r_wr);        // a fetched word (or a tile row's byte)
    wire          h_go  = h_v && !f_wr;
    wire [LW+2:0] w_sel = f_wr ? (r_b1 ? {r_layer, 3'd0} : r_reg) : h_sel;
    wire [15:0]   w_d   = f_wr ? (r_b1 ? {r_byte, r_byte} : r_word) : h_d;
    wire [1:0]    w_be  = f_wr ? (r_b1 ? {r_slot[0], !r_slot[0]} : 2'b11) : h_be;
    wire [LW-1:0] dw_layer = h_sel[LW+2:3];
    wire          dw_fills = h_go && h_sel[2:0] == 3'd0 && h_be[0]
                             && !(enable && en_l[dw_layer] != 8'd0);
    always @(posedge clk) begin
        if (rst || DATWRITE == 0)  h_v <= 1'b0;
        else if (dat_wr && ds_ok)  h_v <= 1'b1;
        else if (h_go)             h_v <= 1'b0;
        if (dat_wr) begin h_sel <= dat_sel;  h_d <= dat_wdata;  h_be <= dat_be; end
    end

    // Next clock's request (the same choice as below), for the urgent register
    reg           n_req, n_ent;
    reg  [LW-1:0] n_layer;
    reg  [9:0]    n_rem;
    always @(*) begin
        n_req = req;  n_layer = req_layer;  n_ent = req_ent;
        if (line_go) n_req = 1'b0;
        else if ((!req || ack) && nxt_v) begin n_req = 1'b1; n_layer = nxt_layer; n_ent = (TILES != 0) && nxt_slot < 4'd2; end
        else if ((!req || ack) && b_go) begin n_req = 1'b1; n_layer = a_pick; n_ent = a_ent; end
        else if (ack) n_req = 1'b0;
        n_rem = (b_go && a_pick == n_layer) ? a_rem_n : rem[n_layer];
    end
    wire [1:0]  n_lb  = lb_of(g_dep[n_layer]);                                      // the group's own depth
    wire [4:0]  n_wl  = n_ent ? {4'd0, n_rem[1]} + {4'd0, n_rem[0]} + 5'd1 + ((n_lb == 2'd0) ? 5'd2 : (5'd1 << n_lb))
                              : {1'b0, ones(n_rem[9:2])} + 5'd1;                       // words not yet through B, + 1
    wire [10:0] n_dl0 = {1'b0, dl[n_layer]};
    wire [10:0] n_dle = (dl[n_layer] == DL_NONE) ? 11'h3FF : n_dl0 + ({5'd0, 6'd59} << hscale[2*n_layer +: 2]);
    wire [10:0] n_dl  = n_ent ? n_dle : n_dl0;
    wire [31:0] n_mark = URG_BASE + URG_WORD * {27'd0, n_wl};                        // 32-bit: no width to cut

    always @(posedge clk) begin
        lsync   <= {lsync[1:0], line_t};
        take_s1 <= take_t;
        take_s2 <= take_s1;
        take_s3 <= take_s2;
        for (n = 0; n < NL; n = n + 1)
            if (take_s3[n] != take_s2[n]) begin                                      // a group was taken
                dl[n] <= first_take[n] ? DL_NONE : 10'd59 << g_hs[n];          // the taken group's scale
                first_take[n] <= 1'b0;
            end else if (dl[n] != 10'd0 && dl[n] != DL_NONE) dl[n] <= dl[n] - 1'b1;

        urgent <= !rst && n_req && ({21'd0, n_dl} < n_mark);

        if (rst) begin
            req    <= 1'b0;   req_ent <= 1'b0;   req_layer <= {LW{1'b0}};
            last   <= LAST0;
            q_h    <= 2'd0;   q_t <= 2'd0;
            gen    <= 1'b0;
            fill_t <= {NL{1'b0}};
            busy   <= {NL{1'b0}};
            nxt_v  <= 1'b0;
            pv_adv <= {NL{1'b0}};
            t_tile <= {NL{1'b0}};
            first_take <= {NL{1'b0}};
            for (n = 0; n < NL; n = n + 1) begin
                left[n] <= 12'd0;  ngr[n] <= 12'd0;  rem[n] <= 10'd0;  dl[n] <= DL_NONE;
                at[n]   <= 10'd0;
            end
            for (n = 0; n < 8*NL; n = n + 1) dr[n] <= 16'd0;
        end else begin
            // Data back from the memory
            if (rvalid) begin
                if (r_ent)  ent[{r_layer, !r_slot[0]}] <= rdata;                      // an entry, as read
                if (r_ok && q_fill[q_h]) fill_t[r_layer] <= ~fill_t[r_layer];
                if (r_ok && q_last[q_h]) busy[r_layer]   <= 1'b0;
                q_h <= q_h + 1'b1;
            end
            if (ack) begin
                req <= 1'b0;
                q_t <= q_t + 1'b1;
            end

            if (line_go) begin
                for (n = 0; n < NL; n = n + 1) begin
                    if (enable && act[n] && ngroups[12*n +: 12] != 12'd0 && en_l[n] != 8'd0) begin
                        left[n] <= ngroups[12*n +: 12] + {11'd0, (TILES != 0) && tile[n]};
                        ngr[n]  <= ngroups[12*n +: 12] + {11'd0, (TILES != 0) && tile[n]};
                    end else begin
                        left[n] <= 12'd0;
                        ngr[n]  <= 12'd0;
                    end
                    rem[n]    <= 10'd0;
                    dl[n]     <= DL_NONE;                              // no deadline until the first in-window take
                    first_take[n] <= 1'b1;
                    fill_t[n] <= take_s2[n];                           // empty: last line's spare group is dropped
                    t_mw[n]   <= mapw[2*n +: 2];
                    t_row[n]  <= ty[10*n + 3 +: 7];
                    t_trow[n] <= ty[10*n +: 3];
                    ecol[n]   <= tcol[7*n +: 7];
                    t_map[n]  <= mappt[PW*n +: PW];
                    t_pat[n]  <= patpt[PW*n +: PW];
                end
                t_tile <= tile & {NL{TILES != 0}};
                pv_adv <= adv;
                busy   <= {NL{1'b0}};
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
                        req_ent   <= (TILES != 0) && nxt_slot < 4'd2;
                        addr      <= nxt_addr;
                        q_layer[q_w] <= nxt_layer;  q_slot[q_w] <= nxt_slot;  q_fill[q_w] <= nxt_fill;
                        q_last[q_w]  <= nxt_last;   q_gen[q_w]  <= nxt_gen;   q_flip[q_w] <= nxt_flip;
                        q_bsel[q_w]  <= nxt_bsel;
                        nxt_v     <= b_go;
                    end else if (b_go) begin
                        req       <= 1'b1;
                        req_layer <= a_pick;
                        req_ent   <= a_ent;
                        addr      <= b_addr[AW:1];
                        q_layer[q_w] <= a_pick;  q_slot[q_w] <= a_slot;  q_fill[q_w] <= a_fill;
                        q_last[q_w]  <= (a_rem_n == 10'd0);  q_gen[q_w] <= gen;  q_flip[q_w] <= a_flip;
                        q_bsel[q_w]  <= b_bsel;
                    end
                end else if (b_go)
                    nxt_v <= 1'b1;
                // B: the word is asked for
                if (b_go) begin
                    nxt_layer <= a_pick;   nxt_slot <= a_slot;   nxt_fill <= a_fill;
                    nxt_last  <= (a_rem_n == 10'd0);
                    nxt_gen   <= gen;      nxt_flip <= a_flip;   nxt_bsel <= b_bsel;
                    nxt_addr  <= b_addr[AW:1];
                    last      <= a_pick;
                    rem[a_pick] <= a_rem_n;
                    if (a_gstart) begin
                        left[a_pick]   <= left[a_pick] - 1'b1;
                        busy[a_pick]   <= 1'b1;
                        if (a_tile && !a_ent)                                        // the group's PAL and PRI
                            at[a_pick] <= {ent[{a_pick, 1'b1}][15], ent[{a_pick, 1'b1}][12:9],
                                           ent[{a_pick, 1'b0}][15], ent[{a_pick, 1'b0}][12:9]};
                    end
                    if (a_tile && a_ent)
                        ecol[a_pick] <= (ecol[a_pick] + 1'b1) & colmask(t_mw[a_pick]);
                end
            end

            // The data registers' one write: a fetched word (a 1-bit tile
            // row's byte goes to one half: column 0 high), or the held
            // machine write
            if (f_wr || h_go) begin
                if (w_be[1]) dr[w_sel][15:8] <= w_d[15:8];
                if (w_be[0]) dr[w_sel][7:0]  <= w_d[7:0];
            end
            if (dw_fills) fill_t[dw_layer] <= ~take_s2[dw_layer];
        end
    end
endmodule
