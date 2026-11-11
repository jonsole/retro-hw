// Sprites, memory side: the fetcher, the FIFOs and the deadlines. System
// clock (100 MHz); the FIFOs cross to the pixel units (sprite_pix.v) with
// Gray-coded pointers and a toggle handshake for each flush.
//
// Eight sprites (NS of them built). The machine keeps each sprite's
// settings (window, depth, palette, bits per pixel, steps) in its own
// registers and hands them over a sprite a clock: set_sel names the
// sprite, and the set_ inputs are its settings in that clock. The core
// registers them and works on them in the next clock, so set_sel runs one
// sprite ahead of the calculator; the machine's settings read (a RAM or a
// mux) gets a whole clock. A write to a sprite's settings that lands in
// the very clock they are handed over is seen at the sprite's next visit,
// 8 clocks later (or the next line, if that visit was the one that
// counts). The line
// start (the pointer into the image) lives here, as the line-start pass
// moves it on; the machine reads it and writes it through sel, lst_cur and
// lst_wr. Each sprite has a 32-word FIFO. The fetcher fetches each line's
// words during that line, one word at a time through the scheduler's
// sprite channel, the sprite with the nearest deadline first.
//
// What one sprite line takes: the words that hold its shown pixels, from
// HSTART to HSTOP or the end of the line (beam pixel 864), whichever
// comes first: wv = ceil(ceil(shown width x XSTEP / 2048) x bpp / 16). An
// image line in memory is wf words: the same for the whole window width.
// The fetcher takes a line's first wv words.
//
// Each line's settings: the size calculator's results are written only in
// a window near the end of each line (beam pixels 840-847), so they hold
// still for the next line, and both the fetcher and the pixel side use the
// same values. At the start of each line (beam pixel 0) a short pass visits
// the sprites, one a clock: a running sprite whose window covers the line
// shows on it; its line start moves on by k x wf words (k the source lines
// YSTEP moves on, 0 when a line shows again; not on its first line or after
// a line-start write), and its words are fetched from there. The pixel side
// takes which sprites show at beam pixel 12 (so HSTART must be 16 or more).
//
// A start strobe starts a sprite; the vertical blank stops them all.
// Either way its FIFO is emptied (both clock domains agree on it with a
// handshake) and reads still on their way are dropped.
//
// Deadlines: one shared calculator visits a sprite each clock and works
// out, from the beam, when its FIFO will run dry.
//
// Collisions: the pixel side gathers them over a line and toggles coll_t;
// they are added to coll, which coll_clr clears bit by bit.
//
// Parameters:
//   NS         sprites built (1-8): the others never start, fetch or show
//   PW         bits of the line start and pointer (22 or more); memory
//              addresses are bits 21-1 of it
//   AW         bits of a memory word address (mem_addr): bits AW..1 of the
//              pointer
//   LITTLE     1: a word's low byte (the even byte of a little-endian
//              memory) goes to the FIFO word's high half, which holds the
//              first pixels
//   URGENT     a fetch is marked urgent when its deadline is fewer than
//              this many units (8 clocks each) away. mem_urgent is a
//              register: the compare for the request mem_req carries in
//              this clock, with the deadline of the clock before, so it is
//              at most a clock later than the compare itself
//   MANUAL     1: a sprite with its DMA off can be fed by hand (dat_wr),
//              and fifo_count reads how many words its FIFO holds
module sprite_fetch #(
    parameter NS         = 8,
    parameter PW         = 23,
    parameter AW         = 21,
    parameter LITTLE     = 0,
    parameter URGENT     = 5,
    parameter MANUAL     = 1
) (
    input  wire          clk,
    input  wire          rst,

    // Each sprite's settings, as the machine's registers hold them, for
    // sprite set_sel (read in the same clock)
    output wire [2:0]    set_sel,
    input  wire [10:0]   set_hstart,     // beam pixels
    input  wire [10:0]   set_hstop,
    input  wire [10:0]   set_vstart,     // beam lines
    input  wire [10:0]   set_vstop,
    input  wire [1:0]    set_bpp,        // 0 2 bits, 1 4 bits, 2 8 bits a pixel
    input  wire [1:0]    set_depth,
    input  wire [3:0]    set_pal,
    input  wire [15:0]   set_xstep,      // as written (limited here)
    input  wire [15:0]   set_ystep,

    // Which sprites fetch
    input  wire          dma_on,         // the sprites' DMA as a whole
    input  wire [7:0]    dma_mask,       // ... and each sprite's

    // Starting, and the sprite sel names: its line start, its FIFO
    input  wire [7:0]    start,          // 1 clock: these sprites start
    input  wire [2:0]    sel,
    output wire [PW-1:0] lst_cur,        // sel's line start (the line being drawn, or the value written)
    input  wire          lst_wr,         // 1 clock: sel's line start is lst_new
    input  wire [PW-1:0] lst_new,        // bit 0 is taken as 0
    output wire [5:0]    fifo_count,     // words in sel's FIFO (MANUAL)
    input  wire          dat_wr,         // 1 clock: dat into sel's FIFO, if its DMA is off and there is room (MANUAL)
    input  wire [15:0]   dat,

    input  wire          vblank,         // 1 clock: the vertical blank starts
    input  wire [10:0]   beam_v,         // the beam (memory side samples)
    input  wire [10:0]   beam_h,

    // Scheduler: the sprite channel
    output reg           mem_req,
    output reg  [AW-1:0] mem_addr,
    output reg           mem_urgent,
    input  wire          mem_ack,
    input  wire          mem_rvalid,
    input  wire [15:0]   mem_rdata,

    // To the pixel side: each sprite's settings (read once per line there)
    // Across, beam pixels (0 = the start of the line's horizontal blank,
    // 144 = the picture's first pixel, 863 its last)
    output wire [79:0]   p_hs,           // 8 x 10: first pixel (0-864)
    output wire [79:0]   p_xe,           // 8 x 10: pixel after the last shown (0-864)
    output wire [7:0]    p_act,          // shows on this line (set at its start)
    output wire [15:0]   p_lb,           // 8 x 2: log2 bits per pixel (1-3)
    output wire [127:0]  p_xstep,        // 8 x 16: XSTEP, limited (5.11 source pixels per screen pixel)
    output wire [15:0]   p_depth,
    output wire [31:0]   p_pal,
    output wire [7:0]    p_dma,          // fed by the DMA

    // The FIFOs, between the domains
    input  wire [39:0]   fifo_ra,        // 8 x 5: read addresses (pixel side)
    output wire [127:0]  fifo_rd,        // 8 x 16: the words there
    output wire [47:0]   wp_g,           // 8 x 6: write pointers, Gray-coded
    input  wire [47:0]   rp,             // 8 x 6: read pointers, as sprite_pix registers them (pixel clock)
    output reg  [7:0]    flush_t,
    input  wire [7:0]    flush_ack_t,

    // Collisions found on a line (pixel side, stable when coll_t toggles)
    input  wire [31:0]   coll_line,
    input  wire          coll_t,
    input  wire [31:0]   coll_clr,       // 1 clock: clear these bits
    output reg  [31:0]   coll            // gathered since cleared
);
    integer i;
    genvar g;
    (* ASYNC_REG = "TRUE" *) reg [1:0] coll_s;
    reg        coll_s3;
    always @(posedge clk) begin
        coll_s  <= {coll_s[0], coll_t};
        coll_s3 <= coll_s[1];
    end
    wire coll_ev = coll_s3 != coll_s[1];

    localparam [7:0] BUILT = (NS >= 8) ? 8'hFF : ((8'd1 << NS) - 8'd1);

    // ================================================================ settings
    // Copies of the settings, made by the size calculator below
    reg  [10:0] r_vs [0:7];
    reg  [1:0]  r_bpp [0:7], r_depth [0:7];
    reg  [3:0]  r_pal [0:7];
    reg  [15:0] r_xs [0:7], r_ys [0:7];        // the steps, limited
    function [15:0] lim(input [15:0] s);
        lim = (s == 16'd0) ? 16'h0800 : (s < 16'h0080) ? 16'h0080 : (s > 16'h8000) ? 16'h8000 : s;
    endfunction

    wire [7:0]  active = dma_on ? (dma_mask & BUILT) : 8'd0;

    // ================================================================ per-sprite sizes
    // Worked out from the settings by one shared calculator, a sprite a
    // clock (cs), and kept in registers: written only in the window near
    // the end of each line (upd), so they are the next line's settings.
    reg  [9:0]  hs_t [0:7], xe_t [0:7];        // the window across, on the line's timeline t
    reg  [10:0] ve_c [0:7];
    reg  signed [3:0] wsh [0:7];               // log2 of screen pixels per word, rounded down (for the deadlines)
    reg  [11:0] wf [0:7], wv [0:7];            // words per image line; per shown line
    reg  [2:0]  cs = 3'd0;
    assign set_sel = cs + 3'd1;                // one ahead: the settings are registered below
    reg  [10:0] i_hstart, i_hstop, i_vstart, i_vstop;
    reg  [1:0]  i_bpp, i_depth;
    reg  [3:0]  i_pal;
    reg  [15:0] i_xstep, i_ystep;
    always @(posedge clk) begin
        i_hstart <= set_hstart;  i_hstop <= set_hstop;  i_vstart <= set_vstart;  i_vstop <= set_vstop;
        i_bpp <= set_bpp;  i_depth <= set_depth;  i_pal <= set_pal;  i_xstep <= set_xstep;  i_ystep <= set_ystep;
    end
    wire        upd = (beam_h >= 11'd840) && (beam_h < 11'd848);
    reg  [1:0]  upd_d;                         // ... two clocks on, for stage 3
    always @(posedge clk) upd_d <= {upd_d[0], upd};
    // Three stages, for timing: 1 takes sprite cs's settings and clamps
    // its window; 2 multiplies the widths by XSTEP; 3 works out the word
    // counts (sprite c3). Stage 3 writes for the same visits as stage 1.
    reg  [2:0]  c2, c3;
    reg  [12:0] wfull2, wshow2;
    reg  [15:0] xs2;
    reg  [1:0]  bpp2, bpp3;
    reg  [28:0] pf3, ps3;              // widths x XSTEP
    // log2 of 2048 / XSTEP, rounded down (bigger across: positive)
    function signed [3:0] mag(input [15:0] s);
        integer b, top, m;
        begin
            top = 7;
            for (b = 7; b <= 15; b = b + 1) if (s[b]) top = b;
            m   = (((s & (s - 1'b1)) == 16'd0) ? 11 : 10) - top;    // a power of two exactly, or between
            mag = m[3:0];
        end
    endfunction
    always @(posedge clk) begin : sizes
        reg [10:0] hs, he, hsc, xec;
        reg [10:0] vs, ve, vec;
        reg [1:0]  bpp;
        reg [15:0] xs;
        reg [17:0] srcf, srcs;
        reg [20:0] bf, bs;
        // stage 1 (on the registered settings of sprite cs)
        hs = i_hstart; he = i_hstop; vs = i_vstart; ve = i_vstop;
        bpp = i_bpp;
        xs  = lim(i_xstep);
        // all in beam coordinates: the line is beam pixels 0-863, the frame lines 0-624
        hsc   = (hs > 11'd864) ? 11'd864 : hs;
        xec   = (he > 11'd864) ? 11'd864 : (he < hsc) ? hsc : he;
        vec   = (ve > 11'd625) ? 11'd625 : ve;
        if (upd) begin
            r_vs[cs]    <= vs;
            r_bpp[cs]   <= bpp;
            r_depth[cs] <= i_depth;
            r_pal[cs]   <= i_pal;
            r_xs[cs]    <= xs;
            r_ys[cs]    <= lim(i_ystep);
            hs_t[cs]    <= hsc[9:0];
            xe_t[cs]    <= xec[9:0];
            wsh[cs]     <= $signed({2'b00, 2'd3 - bpp}) + mag(xs);
            ve_c[cs]    <= vec;
        end
        wfull2 <= (he > hs) ? {2'd0, he - hs} : 13'd0;
        wshow2 <= {2'd0, xec - hsc};
        xs2    <= xs;
        bpp2   <= bpp;
        c2     <= cs;
        cs     <= cs + 1'b1;
        // stage 2
        pf3  <= wfull2 * xs2;
        ps3  <= wshow2 * xs2;
        bpp3 <= bpp2;
        c3   <= c2;
        // stage 3: source pixels = ceil(width x XSTEP / 2048), then words
        /* verilator lint_off WIDTHTRUNC */ srcf  = (pf3 + 29'd2047) >> 11; /* verilator lint_on WIDTHTRUNC */
        /* verilator lint_off WIDTHTRUNC */ srcs  = (ps3 + 29'd2047) >> 11; /* verilator lint_on WIDTHTRUNC */
        bf    = ({3'd0, srcf} << (bpp3 + 1'b1)) + 21'd15;
        bs    = ({3'd0, srcs} << (bpp3 + 1'b1)) + 21'd15;
        if (upd_d[1]) begin
            wf[c3]  <= (bf[20:4] > 17'd4095) ? 12'd4095 : bf[15:4];
            // (the shown width is never more than the window's, so wv <= wf)
            wv[c3]  <= (srcs == 18'd0) ? 12'd0 : (bs[20:4] > 17'd4095) ? 12'd4095 : bs[15:4];
        end
    end

    generate for (g = 0; g < 8; g = g + 1) begin : outs
        assign p_hs[10*g +: 10]  = hs_t[g];
        assign p_xe[10*g +: 10]  = xe_t[g];
        assign p_lb[2*g +: 2]    = r_bpp[g] + 1'b1;
        assign p_xstep[16*g +: 16] = r_xs[g];
        assign p_depth[2*g +: 2] = r_depth[g];
        assign p_pal[4*g +: 4]   = r_pal[g];
        assign p_dma[g]          = active[g];
    end endgenerate

    // ================================================================ FIFOs
    reg  [5:0]  wp [0:7];
    // The read pointers cross from the pixel clock. They can move several
    // words in one step, so a Gray code would not make a half-changed sample
    // harmless: instead a value is used only when two successive samples
    // agree. The pixel clock must be at most a third of this one, so that
    // every value is seen whole twice; a value seen less often is only late.
    (* ASYNC_REG = "TRUE" *) reg [5:0] rp_s1 [0:7];
    (* ASYNC_REG = "TRUE" *) reg [5:0] rp_s2 [0:7];
    reg  [5:0]  rp_s3 [0:7];
    reg  [5:0]  wpg [0:7];                     // the write pointers, Gray-coded, registered before they cross
    reg  [3:0]  infl [0:7];                    // reads on their way
    reg  [5:0]  rpb [0:7];                     // the read pointers, binary (registered: a clock old, for timing)
    wire [5:0]  cnt [0:7];                     // words in the FIFO
    wire [6:0]  fill [0:7];                    // ... and on their way
    wire [7:0]  dma_wr, man_wr;                // a word into the FIFO: from memory; by hand
    assign fifo_count = cnt[sel];

    // ================================================================ fetch state
    // Each sprite's place in its image, in distributed RAM (one write a clock):
    // the line's start (lst_cur reads it), the next word, the words of the
    // line still to fetch, and the fraction of YSTEP. Writers: a line-start
    // write, the line-start pass, a word asked for.
    reg  [PW-1:0] m_lst [0:7];
    reg  [PW-1:0] m_ptr [0:7];
    reg  [11:0] m_wl  [0:7];
    reg  [10:0] m_yf  [0:7];
    reg  [7:0]  run;                           // started this frame
    reg  [7:0]  pend;                          // has shown a line since it started or its line start was written
    reg  [7:0]  line_act;                      // shows on this line
    reg  [7:0]  alive;                         // this line's words still to fetch
    reg  [7:0]  epoch, flushing;
    assign p_act = line_act;
    (* ASYNC_REG = "TRUE" *) reg [7:0] fa_s1;
    reg  [7:0]  fa_s2;
    reg  [6:0]  dl [0:7];                      // deadlines, in units of 8 clocks
    assign lst_cur = m_lst[sel];

    // Starting and stopping (the vertical blank) both empty the FIFO
    wire        w_pt    = lst_wr;
    wire [7:0]  restart = (vblank ? BUILT : 8'd0) | (start & BUILT);

    // A flush done: the pixel side has emptied its end
    wire [7:0]  fdone = flushing & ~(fa_s2 ^ flush_t);

    // The line-start pass: at beam pixel 0 of each line (not line 0, where
    // the vertical blank stops every sprite), three stages, a sprite a clock:
    // A whether it shows and how far its line start moves; B the multiply;
    // C the writes. It holds still in a clock with a line-start write (which
    // has the line-start RAM), and fetching waits for it.
    reg         bz;
    always @(posedge clk) bz <= (beam_h == 11'd0);
    wire        line_go = (beam_h == 11'd0) && !bz && (beam_v != 11'd0);
    reg  [3:0]  ba;                            // stage A's sprite; 8: done
    reg         b_v, cv, b_show, c_show, b_e, c_e;
    reg  [2:0]  b_s, c_s;
    reg  [4:0]  b_k;
    reg  [10:0] b_yf, c_yf;
    reg  [PW-1:0] b_lst, c_lst;
    reg  [11:0] b_wf, b_wv, c_wv;
    reg  [16:0] c_p;
    wire        bu_go   = !w_pt;
    wire        bu_busy = !ba[3] || b_v || cv;
    wire [2:0]  a       = ba[2:0];
    wire        a_show  = run[a] && beam_v >= r_vs[a] && beam_v < ve_c[a] && wv[a] != 12'd0;
    wire [11:0] a_sum   = {1'b0, m_yf[a]} + {1'b0, r_ys[a][10:0]};
    wire [5:0]  a_kw    = {1'b0, r_ys[a][15:11]} + {5'd0, a_sum[11]};
    wire [4:0]  a_k     = pend[a] ? a_kw[4:0] : 5'd0;   // source lines to move on: 0-16
    wire [10:0] a_yf    = pend[a] ? a_sum[10:0] : 11'd0;
    wire        c_w     = cv && bu_go && c_e == epoch[c_s];
    wire [PW-1:0] c_next = c_lst + {{(PW-18){1'b0}}, c_p, 1'b0};

    // Who asks next (a clock ahead): of the sprites that want a word, the
    // nearest deadline, the lower number on a tie. For timing, which
    // sprites want a word is registered first (want), and the pick is a
    // tree of pairs. want is a clock old and the pick a clock ahead, so
    // words for the last two picks may be on their way unseen: a FIFO
    // counts as full two words early. issue checks the state of the moment.
    // (The read pointer is a clock old too, which only makes a FIFO look
    // fuller: safe.)
    reg  [7:0]  want;
    reg  [2:0]  pick;
    reg         pick_v;
    reg  [2:0]  pk;                            // the pick, registered
    always @(posedge clk) begin : wants
        integer s;
        for (s = 0; s < 8; s = s + 1)
            want[s] <= !rst && active[s] && !flushing[s] && alive[s] && (fill[s] < 7'd30);
    end
    // one pair: b wins only if it wants a word and a has none or a later deadline
    reg         t1v [0:3], t2v [0:1];
    reg  [2:0]  t1i [0:3], t2i [0:1];
    reg  [6:0]  t1d [0:3], t2d [0:1];
    always @(*) begin : choose
        integer k;
        for (k = 0; k < 4; k = k + 1)
            if (want[2*k+1] && (!want[2*k] || dl[2*k+1] < dl[2*k])) begin
                t1v[k] = 1'b1; t1i[k] = {k[1:0], 1'b1}; t1d[k] = dl[2*k+1];
            end else begin
                t1v[k] = want[2*k]; t1i[k] = {k[1:0], 1'b0}; t1d[k] = dl[2*k];
            end
        for (k = 0; k < 2; k = k + 1)
            if (t1v[2*k+1] && (!t1v[2*k] || t1d[2*k+1] < t1d[2*k])) begin
                t2v[k] = 1'b1; t2i[k] = t1i[2*k+1]; t2d[k] = t1d[2*k+1];
            end else begin
                t2v[k] = t1v[2*k]; t2i[k] = t1i[2*k]; t2d[k] = t1d[2*k];
            end
        if (t2v[1] && (!t2v[0] || t2d[1] < t2d[0])) begin
            pick_v = 1'b1; pick = t2i[1];
        end else begin
            pick_v = t2v[0]; pick = t2i[0];
        end
    end
    reg         pk_v;
    reg  [2:0]  req_s;
    wire        issue   = pk_v && active[pk] && !flushing[pk] && alive[pk] && !restart[pk]
                          && (!mem_req || mem_ack) && !bu_busy;
    // urgent, registered: for the request mem_req carries in the next
    // clock (the one issued now, or the one still waiting), with the
    // deadline as it stands in this clock
    wire        n_req   = !rst && (issue || (mem_req && !mem_ack));
    wire [2:0]  n_s     = issue ? pk : req_s;
    always @(posedge clk) mem_urgent <= n_req && ({25'd0, dl[n_s]} < URGENT);   // (32-bit compare: no width to cut)

    // The picked sprite's next word
    wire [PW-1:0] p_cur = m_ptr[pk];
    wire        endline = (m_wl[pk] == 12'd1);

    // Reads on their way: sprite and epoch
    reg  [2:0]  q_s [0:3];
    reg         q_e [0:3];
    reg  [1:0]  q_h, q_t;

    // The FIFOs (the word's high half holds the first pixels)
    wire [15:0] mem_word = (LITTLE != 0) ? {mem_rdata[7:0], mem_rdata[15:8]} : mem_rdata;
    // A hand-fed word is held and goes in on the first clock with no word
    // from memory, so every FIFO takes its data from one two-way choice
    reg         m_p = 1'b0;                    // a hand-fed word waits
    reg  [2:0]  m_s;
    reg  [15:0] m_d;
    wire        m_go = m_p && !mem_rvalid;
    wire [15:0] fwd  = (MANUAL != 0 && !mem_rvalid) ? m_d : mem_word;
    always @(posedge clk) begin
        if (rst || MANUAL == 0) m_p <= 1'b0;
        else if (dat_wr)        m_p <= 1'b1;
        else if (m_go)          m_p <= 1'b0;
        if (dat_wr) begin m_s <= sel; m_d <= dat; end
    end
    generate for (g = 0; g < 8; g = g + 1) begin : fifos
        if (g < NS) begin : on
            reg [15:0] mem [0:31];
            always @(posedge clk) if (dma_wr[g] || man_wr[g]) mem[wp[g][4:0]] <= fwd;
            assign fifo_rd[16*g +: 16] = mem[fifo_ra[5*g +: 5]];
        end else begin : off
            assign fifo_rd[16*g +: 16] = 16'd0;
        end
        assign dma_wr[g] = !rst && mem_rvalid && q_s[q_h] == g && q_e[q_h] == epoch[g] && !flushing[g] && !restart[g];
        assign man_wr[g] = (MANUAL != 0) && g < NS && !rst && m_go && m_s == g
                           && !active[g] && !flushing[g] && cnt[g] < 6'd32;
        always @(posedge clk) wpg[g] <= wp[g] ^ (wp[g] >> 1);
        assign wp_g[6*g +: 6] = wpg[g];
        always @(posedge clk) if (rp_s2[g] == rp_s3[g]) rpb[g] <= rp_s2[g];
        assign cnt[g]  = wp[g] - rpb[g];
        assign fill[g] = {1'b0, cnt[g]} + {3'd0, infl[g]};
    end endgenerate

    // ================================================================ deadlines
    // One sprite a clock (cs): when its FIFO will run dry, in units of 8
    // system clocks, counting from the beam. The beam on the sprite's line
    // timeline (t = 0-863) is registered once. Lines are not looked at: a
    // sprite not shown on this line or the next only fills its FIFO a
    // little sooner than it needs to.
    // Three stages, for timing: 1 the pixels until the sprite's span and
    // the words in hand; 2 the pixels those words last, and the sum; 3 the
    // units. With the read pointers registered too, a deadline is written
    // from inputs about 4 clocks old and then holds for 8 clocks until the
    // sprite's next visit: 2 units (16 clocks) are taken off to be safe.
    reg  [9:0]  bt, btr;                       // t; 864 - t
    always @(posedge clk) begin
        bt  <= beam_h[9:0];
        /* verilator lint_off WIDTHTRUNC */ btr <= 11'd864 - beam_h; /* verilator lint_on WIDTHTRUNC */
    end
    wire [2:0]  rr = cs;
    reg  [2:0]  d1_rr, d2_rr, d3_rr;
    reg  [13:0] d1_dpx, d2_tot;
    reg  [6:0]  d1_w;
    reg  signed [3:0] d1_wsh;
    reg  [6:0]  d3_dl;
    always @(posedge clk) begin : dcalc
        reg [13:0] wpx;
        reg [17:0] wp18;
        reg [4:0]  wsa;
        reg [11:0] c7;
        // 1: the pixels until the sprite's span (0 if the beam is in it)
        if (bt < xe_t[rr])
            d1_dpx <= (bt < hs_t[rr]) ? {4'b0, hs_t[rr] - bt} : 14'd0;
        else
            d1_dpx <= {4'b0, btr} + {4'b0, hs_t[rr]};
        d1_w   <= fill[rr];
        d1_wsh <= wsh[rr];
        d1_rr  <= rr;
        // 2: the pixels the words last: words x screen pixels per word (a
        // power of two, rounded down: a shrunk sprite's words may last less
        // than a pixel), and the total
        // one left shift, by wsh + 4 (0 to 11), then /16: cheaper than a
        // shifter for each direction, and the same for every wsh (-4 to 7)
        wsa = {d1_wsh[3], d1_wsh} + 5'd4;
        wp18 = {11'd0, d1_w} << wsa;
        wpx = wp18[17:4];
        d2_tot <= d1_dpx + wpx;
        d2_rr  <= d1_rr;
        // 3: x 3.5 / 8 (a pixel is 3.7 clocks: on the safe side), less 2 units
        /* verilator lint_off WIDTHTRUNC */ c7 = {d2_tot[8:0], 3'b000} - {1'b0, d2_tot}; /* verilator lint_on WIDTHTRUNC */
        d3_dl <= (d2_tot >= 14'd292) ? 7'h7F : (c7[11:4] < 8'd2) ? 7'd0 : c7[10:4] - 7'd2;
        d3_rr <= d2_rr;
    end

    // ================================================================ the RAMs
    wire        c_set = c_w && c_show;        // the line-start pass sets up a shown line
    always @(posedge clk) begin
        if (w_pt)
            m_lst[sel] <= {lst_new[PW-1:1], 1'b0};   // lines are words
        else if (c_set)
            m_lst[c_s] <= c_next;
    end
    wire [2:0]  mwa = c_set ? c_s : pk;       // (no word is asked for during the pass)
    always @(posedge clk) begin
        if (c_set || issue) begin
            m_ptr[mwa] <= c_set ? c_next : p_cur + {{(PW-2){1'b0}}, 2'd2};
            m_wl[mwa]  <= c_set ? c_wv : m_wl[pk] - 1'b1;
        end
        if (c_set)
            m_yf[c_s]  <= c_yf;
    end
    integer ii;
    initial for (ii = 0; ii < 8; ii = ii + 1) begin
        m_lst[ii] = {PW{1'b0}}; m_ptr[ii] = {PW{1'b0}}; m_wl[ii] = 12'd0; m_yf[ii] = 11'd0;
    end

    // ================================================================ main
    always @(posedge clk) begin
        fa_s1 <= flush_ack_t;
        fa_s2 <= fa_s1;
        for (i = 0; i < 8; i = i + 1) begin
            rp_s1[i] <= rp[6*i +: 6];
            rp_s2[i] <= rp_s1[i];
            rp_s3[i] <= rp_s2[i];
        end
        dl[d3_rr] <= d3_dl;
        pk     <= pick;
        pk_v   <= pick_v;

        if (rst) begin
            coll     <= 32'd0;
            mem_req  <= 1'b0;
            q_h <= 2'd0; q_t <= 2'd0;
            epoch <= 8'd0; flushing <= 8'd0; alive <= 8'd0;
            run <= 8'd0; pend <= 8'd0; line_act <= 8'd0;
            flush_t <= 8'd0;
            pk_v <= 1'b0;
            ba <= 4'd8; b_v <= 1'b0; cv <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                wp[i] <= 6'd0; infl[i] <= 4'd0;
                dl[i] <= 7'h7F;
            end
        end else begin
            // ---- data back: into its sprite's FIFO, unless the sprite started again since
            if (mem_rvalid) begin
                q_h <= q_h + 1'b1;
            end
            if (mem_ack) begin
                mem_req <= 1'b0;
                q_t     <= q_t + 1'b1;
            end
            for (i = 0; i < 8; i = i + 1)
                if (dma_wr[i] || man_wr[i]) wp[i] <= wp[i] + 1'b1;
            for (i = 0; i < 8; i = i + 1)
                infl[i] <= infl[i] + ((issue && pk == i) ? 4'd1 : 4'd0)
                                   - ((mem_rvalid && q_s[q_h] == i) ? 4'd1 : 4'd0);

            // ---- ask for the next word
            if (issue) begin
                mem_req  <= 1'b1;
                req_s    <= pk;
                mem_addr <= p_cur[AW:1];
                q_s[q_t + (mem_ack ? 1'b1 : 1'b0)] <= pk;
                q_e[q_t + (mem_ack ? 1'b1 : 1'b0)] <= epoch[pk];
                if (endline) alive[pk] <= 1'b0;   // the line's last word
            end

            // ---- the line-start pass
            if (line_go)
                ba <= 4'd0;
            else if (bu_go && !ba[3])
                ba <= ba + 1'b1;
            if (bu_go) begin
                b_v <= !ba[3] && !line_go;
                b_s <= a; b_show <= a_show; b_e <= epoch[a];
                b_k <= a_k; b_yf <= a_yf; b_lst <= m_lst[a]; b_wf <= wf[a]; b_wv <= wv[a];
                cv  <= b_v;
                c_s <= b_s; c_show <= b_show; c_e <= b_e;
                c_yf <= b_yf; c_lst <= b_lst; c_p <= b_k * b_wf; c_wv <= b_wv;
            end
            if (c_w) begin
                line_act[c_s] <= c_show;
                alive[c_s]    <= c_show;
                if (c_show) pend[c_s] <= 1'b1;
            end
            if (w_pt) pend[sel] <= 1'b0;       // the next line starts exactly there

            // ---- flushes done
            flushing <= flushing & ~fdone;

            // ---- starting and stopping: empty the FIFO (after the writes above, so they win)
            for (i = 0; i < 8; i = i + 1)
                if (restart[i]) begin
                    epoch[i]    <= ~epoch[i];
                    flushing[i] <= 1'b1;
                    flush_t[i]  <= ~flush_t[i];
                    wp[i]       <= 6'd0;
                    alive[i]    <= 1'b0;
                    line_act[i] <= 1'b0;
                    pend[i]     <= 1'b0;
                    run[i]      <= !vblank;    // a start starts it; the vertical blank stops it
                end

            // ---- collisions, a line at a time from the pixel side
            coll <= (coll & ~coll_clr) | (coll_ev ? coll_line : 32'd0);
        end
    end

endmodule
