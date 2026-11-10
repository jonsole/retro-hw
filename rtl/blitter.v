// The blitter (docs/spec/blitter_v1.md): four DMA channels, their
// scheduler and one datapath. The machine's wrapper keeps
// the registers: it holds the job registers, decodes the running channel's
// job onto the job_ ports, stores loaded descriptors, and turns register
// writes into the channel strobes.
//
// Four channels share one datapath, which works on one channel at a time
// (the area technique): the engine picks the next channel with work (round
// robin), restores its progress, runs one group of up to 16 destination
// words, saves the progress and picks again. While only one channel can
// run, it goes straight on to that channel's next group or row instead.
//
// A job is rows of pixels, each row a stream of bits. Each destination
// pixel D is MINTERM(A, B, C) bit by bit (BLIT), or C + B (ADD): A the mask
// (a 1 bpp image, B compared with a key colour, or all ones), B the image or
// VALUE, C the destination's old contents. For each destination word of a
// row the B bits are lined up with a barrel shifter fed by the previous and
// the current B word, as in the Amiga's blitter; the A bits come from a
// 32-bit shift register, taking one bit per destination pixel, widened to
// the pixel's bits.
// A backwards (DESC) job uses the same shifter: words are bit-reversed on
// the way in and back again before the combine stage, so only the
// addresses and the edge masks run the other way.
//
// Inside the engine every word is held with the even byte in bits 15-8, so
// that a word's bits from 15 down are the pixels in address order. With LE
// set the memory is little-endian, and words are swapped as they arrive
// and as they go back.
//
// A group is four phases: read up to 17 B words, read up to 17 A words (a
// mask image), read the C words that are needed (when the minterm or ADD
// uses C, and edge words that cover part of a byte), then work out and
// write each destination word. Writes are pipelined so a request is ready
// as each one is taken. When there is nothing more to read the writes start
// at once, while the last B words are still coming back; a group with
// nothing to read at all goes to its writes from the B phase's first clock.
// (S_GRP itself always goes on to S_RD: the counts it works out are
// registered before anything decides on them, for timing.)
//
// LINE (OP 2) steps one pixel at a time: each pixel inside the clip
// rectangle is its word read (when the minterm needs C), merged through the
// minterm and written back. Its progress lives in fields the group
// machinery saves anyway: the pixel's bit address in w_dw:w_od, x in w_arow,
// y in w_srow, the error term in w_sw, the pixels left in w_dleft and the
// pattern's place in w_ao.
//
// EDGES (OP 3) reads each edge (a word: two point numbers) and its two
// points (two words each), works out the line and runs it through LINE's
// stepping. Besides LINE's progress it keeps the next edge's word in w_aw,
// the edges left in w_rows, and the line's N, M and octant in w_carry,
// w_aleft and w_le, so a channel coming back mid-line carries on.
//
// Every access goes through one access unit. Addresses below CHIP_WORDS go
// to the memory port; with XPORT set, the others the wrapper accepts go to
// the other port (the machine's registers or ROM, say). Reads come back in
// the order asked; the unit waits for one port's reads to come back before
// using the other.
//
// LINE and EDGES are built only with their parameters set: without them
// OP 2 and OP 3 are errors and their states and registers are left out.
//
// With PORTJOB set, a port job moves a byte at a time between a FIFO and
// memory; a channel whose FIFO is not ready gives up its turn.
module blitter #(
    parameter [23:0] CHIP_WORDS = 24'h200000,  // memory port: word addresses 0 to this - 1
    parameter        LE      = 0,              // 1: memory words little-endian
    parameter        MASKIMG = 1,              // 0: no 1 bpp mask image (MASK 1 is an error)
    parameter        XPORT   = 0,              // 1: the other port, for addresses past CHIP_WORDS
    parameter        PORTJOB = 0,              // 1: port jobs (FIFO to memory, memory to FIFO)
    parameter        LINE    = 0,              // 1: LINE jobs (OP 2); 0: OP 2 is an error
    parameter        EDGES   = 0               // 1: EDGES jobs (OP 3, which use LINE's stepping); 0: OP 3 is an error
) (
    input  wire        clk,
    input  wire        rst,

    // Channels: strobes for one clock, applied after the engine's own changes
    input  wire        enable,         // the engine may run (0: every channel waits)
    input  wire [3:0]  pause,          // channel n waits
    input  wire [3:0]  start_ld,       // start channel n (if idle): load the descriptor at its address
    input  wire [3:0]  start_run,      // start channel n (if idle): run the job as it is
    input  wire [3:0]  stop,           // stop channel n (if busy) at the end of its group
    input  wire [3:0]  clr_done,
    input  wire [3:0]  clr_err,
    input  wire [3:0]  da_we,          // channel n's descriptor address becomes da_d (if idle)
    input  wire [23:0] da_d,
    output reg  [3:0]  busy,
    output reg  [3:0]  done,
    output reg  [3:0]  err,
    output wire [95:0] da_q,           // the descriptor addresses, channel n at bits 24n+23-24n
    output wire [95:0] ea_q,           // the error addresses, likewise
    output wire [3:0]  irq_set,        // channel n's interrupt is due (one clock)
    output wire        idle,           // no channel busy
    output reg  [1:0]  cur,            // the channel being worked on

    // The job: the wrapper's decode of channel cur's job, read in the
    // clocks of su_v (job word su_i of channel cur) and held after
    output wire        su_v,
    output reg  [2:0]  su_i,
    input  wire [2:0]  job_op,         // 0 BLIT, 1 ADD, 2 LINE, 3 EDGES
    input  wire [7:0]  job_minterm,
    input  wire        job_sat,        // ADD: saturate
    input  wire        job_signed,     // ADD: pixels are signed
    input  wire [1:0]  job_mask,       // 0 none, 1 image at job_aaddr, 2 B against the key colour
    input  wire [1:0]  job_bpp,        // log2 of bits per pixel
    input  wire        job_desc,       // backwards
    input  wire        job_irq,        // interrupt at the end
    input  wire        job_bconst,     // B is job_value, not memory
    input  wire        job_ymaj,       // LINE: the octant
    input  wire        job_xneg,
    input  wire        job_yneg,
    input  wire [31:0] job_value,
    input  wire [15:0] job_bstride,    // signed bytes, row to row (A's and B's)
    input  wire [15:0] job_dstride,
    input  wire [23:0] job_width,      // pixels per row
    input  wire [15:0] job_height,     // rows
    input  wire [23:0] job_aaddr,      // A's, B's and D's first bytes
    input  wire [23:0] job_baddr,
    input  wire [23:0] job_daddr,
    input  wire [2:0]  job_abit,       // the first pixel in its byte
    input  wire [2:0]  job_bbit,
    input  wire [2:0]  job_dbit,
    input  wire [23:0] job_next,       // the next descriptor, 0 for none
    input  wire        job_bport,      // port job: B from the FIFO
    input  wire        job_dport,      // port job: D to the FIFO
    input  wire        job_bad,        // the wrapper rejects the job

    // LINE's clip rectangle: signed, inclusive
    input  wire [15:0] clip_xmin,
    input  wire [15:0] clip_xmax,
    input  wire [15:0] clip_ymin,
    input  wire [15:0] clip_ymax,

    // Descriptor load: 16 words in, handed over a long word at a time
    input  wire        dl_xok,         // the descriptor may be on the other port
    output wire        dl_v,           // long word dl_i of channel cur: dl_w0 then dl_w1 (memory order)
    output wire [2:0]  dl_i,
    output reg  [15:0] dl_w0,
    output wire [15:0] dl_w1,
    input  wire        dl_wait,        // the wrapper has not stored the last one yet

    // The memory port: one request, held until mem_ack; reads back in order
    output reg         mem_req,
    output reg         mem_we,
    output reg  [21:1] mem_addr,
    output reg  [15:0] mem_wdata,
    output reg  [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // The other port (XPORT): the same handshake; xp_ok says whether the
    // access at acc_a (acc_we) can go there, else it is an error
    output wire [22:0] acc_a,
    output wire        acc_we,
    input  wire        xp_ok,
    output reg         xp_req,
    output reg         xp_we,
    output reg  [22:0] xp_addr,
    output reg  [15:0] xp_wdata,
    output reg  [1:0]  xp_be,
    input  wire        xp_ack,
    input  wire        xp_rvalid,
    input  wire [15:0] xp_rdata,

    // The FIFO of a port job (PORTJOB)
    input  wire        p_rxv,          // a byte is there ...
    input  wire [7:0]  p_rxd,
    output wire        p_rxpop,        // ... take it
    input  wire        p_txr,          // room for a byte ...
    output wire        p_txpush,       // ... send this one
    output reg  [7:0]  p_txd
);
    // ================================================================ channel state
    reg  [23:0] chdesc [0:3];
    reg  [23:0] cherr  [0:3];
    reg  [3:0]  stopreq;
    reg  [1:0]  mode [0:3];            // where the channel is in its job
    localparam M_LOAD = 2'd0, M_SETUP = 2'd1, M_ROW = 2'd2, M_RUN = 2'd3;

    assign idle = ~|busy;
    assign da_q = {chdesc[3], chdesc[2], chdesc[1], chdesc[0]};
    assign ea_q = {cherr[3], cherr[2], cherr[1], cherr[0]};

    // ================================================================ the working job
    // The channel being worked on: its progress. Saved to st[] between groups.
    reg  [26:0] w_nbits;               // bits per row
    reg  [15:0] w_rows;                // rows still to do, this one included
    reg  [23:0] w_srow, w_drow;        // this row's first bytes
    reg  [22:0] w_dw, w_sw;            // next destination and source words
    reg  [23:0] w_dleft, w_sleft;      // words of this row still to write and to read
    reg  [3:0]  w_od;                  // the first pixel's bit in its word (from the start side)
    reg  [3:0]  w_t;                   // the shift
    reg         w_pre;                 // read one source word ahead first
    reg         w_first;               // the next word is the row's first
    reg  [3:0]  w_le;                  // bits used in the row's last word (0 = 16)
    reg  [15:0] w_carry;               // the last source word taken
    // The mask image A (MASK = 1): a 1 bpp stream with B's stride
    reg  [23:0] w_arow;                // this row's first byte
    reg  [22:0] w_aw;                  // next word to read
    reg  [23:0] w_aleft;               // words of this row still to read
    reg  [3:0]  w_ao;                  // the row's first bit in its word (from the start side)
    reg  [31:0] w_areg;                // bits not yet used, from bit 31
    reg  [4:0]  w_acnt;                // how many
    // LINE: what the engine derives from the octant and lengths (not saved:
    // worked out again whenever the channel comes back)
    reg  [17:0] l_ins, l_ind;          // E's steps: 2N, and 2(N - M)
    reg  [26:0] l_dmaj, l_dmin;        // the bit address's steps along each axis
    reg  [3:0]  l_k;                   // pixels this turn
    reg  [15:0] l_c;                   // the pixel's word as read (C)
    // EDGES: the edge's ends as read, y x stride
    reg  [15:0] e_ab;                  // the edge word: a (the even byte) in 7-0, b in 15-8
    reg  [15:0] e_x0, e_y0, e_x1, e_y1;
    reg  [31:0] e_mul;

    // Only the progress is saved: the job's fixed fields are read again
    // (S_SETUP) when the channel comes back after another one has run. A
    // channel that carries on straight after its own group needs neither.
    localparam SW = 16+24+24 + 23+23+24+24+4+4+1+1+4+16 + 24+23+24+4+32+5;
    wire [SW-1:0] w_pack = {w_rows, w_srow, w_drow, w_dw, w_sw, w_dleft, w_sleft,
                            w_od, w_t, w_pre, w_first, w_le, w_carry,
                            w_arow, w_aw, w_aleft, w_ao, w_areg, w_acnt};
    reg           w_live;              // the w_ registers and the job ports hold channel w_ch's
    reg  [1:0]    w_ch;
    reg           su_back;             // S_SETUP: only the job's fixed fields, then on
    reg  [SW-1:0] st [0:3];
    integer k;
    initial for (k = 0; k < 4; k = k + 1) st[k] = {SW{1'b0}};

    // ================================================================ the datapath
    wire        srcmem  = !job_bconst;
    wire        maskimg = MASKIMG != 0 && (job_mask == 2'd1);
    wire        portjob = PORTJOB != 0 && (job_bport || job_dport);
    // Does a minterm nibble (the four B, C combinations) depend on C?
    function cdep(input [3:0] n);
        cdep = (n[3] ^ n[2]) | (n[1] ^ n[0]);
    endfunction
    // Where A is 0 and the minterm's low nibble is 0xA (D = C), or for ADD,
    // the pixel is left alone: at 8 bpp a byte not written, C not read
    wire        keep0   = (job_op == 3'd1) || (job_minterm[3:0] == 4'hA);
    // Reads every C word: ADD, or the minterm uses C where A can be 1 (the
    // high nibble), or where A can be 0 (the low nibble, or keeping C in
    // part of a byte)
    wire        op_rd   = (job_op == 3'd1) || cdep(job_minterm[7:4])
                          || (job_mask != 2'd0 && (keep0 ? (job_bpp != 2'd3) : cdep(job_minterm[3:0])));

    function [15:0] rev16(input [15:0] v);
        integer i;
        for (i = 0; i < 16; i = i + 1) rev16[i] = v[15 - i];
    endfunction
    // A memory word to the engine's order (the even byte in bits 15-8) and back
    function [15:0] order(input [15:0] v);
        order = (LE != 0) ? {v[7:0], v[15:8]} : v;
    endfunction
    // A constant B for a destination word (engine order); odd is the word
    // at byte address 2 mod 4. At 8 bpp the byte at address a is VALUE's
    // byte a mod 4: from bits 7-0 up when LE, from bits 31-24 down if not
    function [15:0] pattern(input [31:0] v, input [1:0] lb, input odd);
        case (lb)
            2'd3: if (LE != 0) pattern = odd ? {v[23:16], v[31:24]} : {v[7:0], v[15:8]};
                  else         pattern = odd ? v[15:0] : v[31:16];
            2'd2: pattern = {4{v[3:0]}};
            2'd1: pattern = {8{v[1:0]}};
            default: pattern = {16{v[0]}};
        endcase
    endfunction
    function [15:0] msbs(input [1:0] lb);      // each pixel's top bit
        case (lb)
            2'd3: msbs = 16'h8080;
            2'd2: msbs = 16'h8888;
            2'd1: msbs = 16'hAAAA;
            default: msbs = 16'hFFFF;
        endcase
    endfunction
    function [15:0] smear(input [15:0] f, input [1:0] lb);   // a pixel's top bit to the whole pixel
        integer i;
        begin
            smear = f;
            for (i = 1; i < 8; i = i + 1)
                if (i < (1 << lb)) smear = smear | (f >> i);
        end
    endfunction
    // A's bits for a destination word: bit i of t (from bit 15) to the
    // whole of pixel i
    function [15:0] widen(input [15:0] t, input [1:0] lb);
        integer i;
        for (i = 0; i < 16; i = i + 1) widen[15 - i] = t[15 - (i >> lb)];
    endfunction
    // The Amiga's minterm: each bit of the result is m[a*4 + b*2 + c]
    function [15:0] minterm(input [7:0] m, input [15:0] a, input [15:0] b, input [15:0] c);
        minterm = ({16{m[7]}} &  a &  b &  c) | ({16{m[6]}} &  a &  b & ~c)
                | ({16{m[5]}} &  a & ~b &  c) | ({16{m[4]}} &  a & ~b & ~c)
                | ({16{m[3]}} & ~a &  b &  c) | ({16{m[2]}} & ~a &  b & ~c)
                | ({16{m[1]}} & ~a & ~b &  c) | ({16{m[0]}} & ~a & ~b & ~c);
    endfunction
    // Pixels of s that are not the key colour (all their bits set)
    function [15:0] notkey(input [15:0] s, input [7:0] key, input [1:0] lb);
        reg [15:0] kk, x;
        begin
            kk = pattern({key, key, key, key}, lb, 1'b1);
            x  = s ^ kk;
            case (lb)
                2'd3: notkey = {{8{|x[15:8]}}, {8{|x[7:0]}}};
                2'd2: notkey = {{4{|x[15:12]}}, {4{|x[11:8]}}, {4{|x[7:4]}}, {4{|x[3:0]}}};
                2'd1: notkey = {{2{|x[15:14]}}, {2{|x[13:12]}}, {2{|x[11:10]}}, {2{|x[9:8]}},
                                {2{|x[7:6]}},   {2{|x[5:4]}},   {2{|x[3:2]}},   {2{|x[1:0]}}};
                default: notkey = x;
            endcase
        end
    endfunction
    // Per-pixel add, wrapping or saturating
    function [15:0] padd(input [15:0] d, input [15:0] s, input [1:0] lb, input sat, input sgn);
        reg [15:0] h, l, t, sum, co, ov, f, dneg;
        begin
            h    = msbs(lb);
            l    = ~h;
            t    = (d & l) + (s & l);                 // no carry crosses a pixel
            sum  = t ^ ((d ^ s) & h);
            co   = ((d & s) | ((d ^ s) & t)) & h;     // carry out of each pixel
            ov   = ~(d ^ s) & (d ^ sum) & h;          // signed overflow
            dneg = smear(d & h, lb);
            if (!sat)
                padd = sum;
            else if (!sgn)
                padd = sum | smear(co, lb);
            else begin
                f    = smear(ov, lb);
                padd = (sum & ~f) | (f & ((dneg & h) | (~dneg & l)));
            end
        end
    endfunction

    // Is a word address on the memory port?
    function inchip(input [22:0] w);
        inchip = ({1'b0, w} < CHIP_WORDS);
    endfunction

    // ================================================================ group buffers
    // A group is up to 16 destination words
    reg  [15:0] sbuf [0:16];           // source words, in the order read
    reg  [15:0] abuf [0:16];           // mask words, in the order read
    reg  [4:0]  g_na;                  // mask words to read
    reg  [15:0] dbuf [0:15];           // destination words, by position in the group
    reg  [4:0]  g_n;                   // destination words in this group (1-16)
    reg  [4:0]  g_nr;                  // source words to read
    reg  [15:0] g_dneed;               // destination words to read
    reg  [4:0]  g_last;                // the row's last word in this group (16: none)
    reg  [15:0] s_0;                   // sbuf[0] kept apart, so sbuf has one read port (distributed RAM)
    reg  [4:0]  s_have;                // source words back in sbuf: the writes may start before the last
                                       // ones are back
    // Known contents from the start: a C word not read still goes through
    // the minterm (its result does not depend on it), and the simulator
    // would carry the unknown bits through
    initial for (k = 0; k < 17; k = k + 1) begin sbuf[k] = 16'd0; abuf[k] = 16'd0; end
    initial for (k = 0; k < 16; k = k + 1) dbuf[k] = 16'd0;

    // ================================================================ engine state
    localparam S_IDLE = 5'd0, S_REST = 5'd1, S_DESC = 5'd2, S_SETUP = 5'd3, S_CHECK = 5'd4,
               S_MUL = 5'd5, S_ROW1 = 5'd6, S_ROW2 = 5'd7, S_ROW3 = 5'd8, S_GRP = 5'd9,
               S_RD = 5'd10, S_DR = 5'd11, S_WR = 5'd12, S_SAVE = 5'd13, S_DRAIN = 5'd14,
               S_RA = 5'd15, S_BACK = 5'd16, S_LSET = 5'd17, S_LPIX = 5'd18, S_LRD = 5'd19,
               S_LCMB = 5'd20, S_LWR = 5'd21, S_LSTEP = 5'd22, S_EFETCH = 5'd23, S_EPTS = 5'd24,
               S_ECALC = 5'd25, S_EADDR = 5'd26, S_PORT = 5'd27;
    reg  [4:0]  es;
    reg  [1:0]  last_ch;
    wire [3:0]  runnable = busy & ~pause & {4{enable}};
    // LINE's stepping is built for LINE or EDGES; EDGES' own states for EDGES
    localparam  LS = (LINE != 0) || (EDGES != 0);
    localparam  ES = (EDGES != 0);

    reg  [4:0]  r_tot, r_iss, r_got;   // reads to make, made, back
    reg  [22:0] r_a;                   // the next address (S_RD, S_RA, S_DESC)
    reg  [3:0]  q_j [0:15];            // S_DR: each read's place in the group
    reg         e_bad;                 // stop: an error
    reg  [23:0] e_addr;

    // S_DR: the next destination word to read
    reg  [3:0]  dr_j;
    always @(*) begin : drpick
        integer i;
        dr_j = 4'd0;
        for (i = 15; i >= 0; i = i - 1) if (g_dneed[i]) dr_j = i[3:0];
    end
    wire [22:0] dr_a = job_desc ? w_dw - dr_j : w_dw + dr_j;

    // S_WR pipeline: stage A (line up), stage B (combine), then the request
    reg  [4:0]  wj;                    // next word to start
    reg  [4:0]  sptr, aptr;
    reg         a_v, b_v;
    reg  [15:0] a_s, a_m, a_d, a_a;
    reg  [22:0] a_w, b_w;
    reg  [15:0] b_out;
    reg  [1:0]  b_be;
    reg         b_skip;

    // S_PORT
    reg  [3:0]  pc_n;                  // bytes moved in this turn
    reg         p_rd, p_have;          // memory to FIFO: the byte asked for; here

    // EDGES: the edge's point being read (S_EPTS: point a, then b, two words each)
    wire [7:0]  e_pn     = r_iss[1] ? e_ab[15:8] : e_ab[7:0];
    wire [22:0] e_pw     = {1'b0, job_aaddr[22:1]} + {13'd0, e_pn, 1'b0} + {22'd0, r_iss[0]};

    // ================================================================ the access unit
    // The phase's next access (engine order: xq_be[1] is the even byte)
    reg         xq_v, xq_we;
    reg  [22:0] xq_w;
    reg  [15:0] xq_wd;
    reg  [1:0]  xq_be;
    always @(*) begin
        xq_v = 1'b0; xq_we = 1'b0; xq_w = r_a; xq_wd = b_out; xq_be = b_be;
        case (es)
            S_DESC:     xq_v = (r_iss < 5'd16) && !e_bad;
            S_RD, S_RA: xq_v = (r_iss < r_tot) && !e_bad;
            S_DR:       begin xq_v = (g_dneed != 16'd0) && !e_bad; xq_w = dr_a; end
            S_WR:       begin xq_v = b_v && !b_skip && !e_bad; xq_we = 1'b1; xq_w = b_w; end
            S_LRD:      if (LS) begin xq_v = (r_iss == 5'd0) && !e_bad; xq_w = w_dw; end
            S_LWR:      if (LS) begin xq_v = (r_iss == 5'd0) && !e_bad; xq_we = 1'b1; xq_w = w_dw; end
            S_EFETCH:   if (ES) begin xq_v = (r_iss == 5'd0) && (w_rows != 16'd0) && !e_bad; xq_w = w_aw; end
            S_EPTS:     if (ES) begin xq_v = (r_iss < 5'd4) && !e_bad; xq_w = e_pw; end
            S_PORT:     if (PORTJOB == 0) ;
                        else if (job_bport) begin  // FIFO to memory: a byte at a time
                            xq_v  = p_rxv && pc_n < 4'd8 && w_dleft != 24'd0 && !e_bad;
                            xq_we = 1'b1;
                            xq_w  = w_drow[23:1];
                            xq_wd = {p_rxd, p_rxd};
                            xq_be = w_drow[0] ? 2'b01 : 2'b10;
                        end else begin             // memory to FIFO: read the byte
                            xq_v  = !p_have && !p_rd && pc_n < 4'd8 && w_dleft != 24'd0 && !e_bad;
                            xq_w  = w_srow[23:1];
                        end
            default: ;
        endcase
    end
    assign acc_a  = xq_w;
    assign acc_we = xq_we;

    reg  [4:0]  chip_out;              // memory port reads not yet back
    reg  [4:0]  x_out;                 // other port reads not yet back

    wire        xq_chip = inchip(xq_w);
    wire        xq_bad  = xq_v && !xq_chip && !(XPORT != 0 && xp_ok);
    // Without XPORT the other port's inputs are not looked at, and every
    // access taken goes to the memory port
    wire        xp_on    = (XPORT != 0);
    wire        chip_ok  = (!mem_req || mem_ack) && !(xp_on && (xp_req || x_out != 5'd0));
    wire        x_ok     = (!xp_req || xp_ack) && chip_out == 5'd0;
    wire        xq_take  = xq_v && !xq_bad && ((xq_chip || !xp_on) ? chip_ok : x_ok);
    wire        xq_tchip = xq_take && (xq_chip || !xp_on);                 // taken, for the memory port
    wire        acc_held = mem_req || (xp_on && xp_req);                   // a request not yet taken
    wire        rd_out   = (chip_out != 5'd0) || (xp_on && x_out != 5'd0); // reads not yet back
    // Reads back, in order: as stored (descriptors, points) and in the engine's order
    wire        x_rv  = mem_rvalid || (xp_on && xp_rvalid);
    wire [15:0] x_raw = (xp_on && !mem_rvalid) ? xp_rdata : mem_rdata;
    wire [15:0] x_rd  = order(x_raw);
    wire [15:0] x_wd  = order(xq_wd);
    wire [1:0]  x_be  = !xq_we ? 2'b11 : (LE != 0) ? {xq_be[0], xq_be[1]} : xq_be;

    assign p_rxpop  = PORTJOB != 0 && (es == S_PORT) && job_bport && xq_take;
    assign p_txpush = PORTJOB != 0 && (es == S_PORT) && job_dport && p_have && p_txr;

    // Descriptor load: the second word of each pair hands the long word over
    assign dl_v  = (es == S_DESC) && x_rv && r_got[0];
    assign dl_i  = r_got[3:1];
    assign dl_w1 = x_raw;
    assign su_v  = (es == S_SETUP);

    // ================================================================ the write pipeline
    wire        b_take   = b_v && (b_skip || xq_take);
    wire        a_move   = a_v && (!b_v || b_take);

    // At the end of a group: carry on with the same channel
    wire        wr_on    = (runnable == (4'd1 << cur)) && !stopreq[cur]
                        && !(w_dleft == {19'd0, g_n} && w_rows == 16'd1);

    // Stage A for word wj: its source word must be back
    wire        a_hasn   = srcmem && (sptr < g_nr);
    wire        a_new    = (wj < g_n) && (!a_v || a_move) && !e_bad && (!a_hasn || sptr < s_have);
    wire [15:0] a_B      = a_hasn ? sbuf[sptr] : 16'd0;
    wire [31:0] a_cat    = {w_carry, a_B} << w_t;
    wire [15:0] a_shp    = a_cat[31:16];
    wire [15:0] m_first  = (w_first && wj == 5'd0) ? (16'hFFFF >> w_od) : 16'hFFFF;
    wire [15:0] m_last   = (wj == g_last) ? ((w_le == 4'd0) ? 16'hFFFF : ~(16'hFFFF >> w_le)) : 16'hFFFF;
    wire [15:0] a_mp     = m_first & m_last;
    wire [22:0] a_wa     = job_desc ? w_dw - wj : w_dw + wj;
    wire [15:0] a_st     = srcmem ? (job_desc ? rev16(a_shp) : a_shp) : pattern(job_value, job_bpp, a_wa[0]);
    wire [15:0] a_mt     = job_desc ? rev16(a_mp) : a_mp;
    // the mask image: take 16 >> BPP bits (one a pixel), adding a word first if short
    wire [4:0]  a_k      = 5'd16 >> job_bpp;
    wire        a_ins    = (w_acnt < a_k);
    wire [15:0] a_word   = (aptr < g_na) ? abuf[aptr] : 16'd0;
    wire [31:0] a_regi   = a_ins ? (w_areg | ({a_word, 16'd0} >> w_acnt)) : w_areg;
    wire [15:0] a_wide   = widen(a_regi[31:16], job_bpp);
    wire [15:0] a_at     = job_desc ? rev16(a_wide) : a_wide;

    // Stage B
    wire [15:0] b_A      = (job_mask == 2'd2) ? notkey(a_s, job_value[7:0], job_bpp)
                         : (job_mask == 2'd1) ? a_a : 16'hFFFF;
    wire [15:0] res      = (job_op == 3'd1) ? padd(a_d, a_s, job_bpp, job_sat, job_signed)
                         : minterm(job_minterm, b_A, a_s, a_d);
    wire [15:0] mfin     = a_m & ~(keep0 ? ~b_A : 16'd0);

    // LINE and EDGES: the line's octant, N (the shorter length) and M (the
    // longer): LINE's from its job, EDGES' from the edge (kept in w_le,
    // w_carry and w_aleft)
    wire        is_e     = ES && (job_op == 3'd3);
    wire        is_l     = (LINE != 0) && (job_op == 3'd2);
    wire        l_ymaj   = is_e ? w_le[0] : job_ymaj;
    wire        l_xneg   = is_e ? w_le[1] : job_xneg;
    wire        l_yneg   = is_e ? w_le[2] : job_yneg;
    wire [15:0] l_nn     = is_e ? w_carry : job_height;
    wire [15:0] l_mm     = is_e ? w_aleft[15:0] : job_width[15:0] - 1'b1;
    // and what is worked out from its ends
    wire [16:0] e_dx     = {e_x1[15], e_x1} - {e_x0[15], e_x0};
    wire [16:0] e_dy     = {e_y1[15], e_y1} - {e_y0[15], e_y0};
    wire [15:0] e_ax     = e_dx[16] ? 16'd0 - e_dx[15:0] : e_dx[15:0];
    wire [15:0] e_ay     = e_dy[16] ? 16'd0 - e_dy[15:0] : e_dy[15:0];
    wire        e_ymaj   = e_ay > e_ax;
    wire [15:0] e_m      = e_ymaj ? e_ay : e_ax;
    wire [15:0] e_n      = e_ymaj ? e_ax : e_ay;
    // left out: an end outside -16384..16383 (x = 0x8000 among them), or
    // both beyond the same side of the clip rectangle
    wire        e_range  = (e_x0[15] != e_x0[14]) || (e_y0[15] != e_y0[14])
                        || (e_x1[15] != e_x1[14]) || (e_y1[15] != e_y1[14]);
    wire        e_beyond = ($signed(e_x0) < $signed(clip_xmin) && $signed(e_x1) < $signed(clip_xmin))
                        || ($signed(e_x0) > $signed(clip_xmax) && $signed(e_x1) > $signed(clip_xmax))
                        || ($signed(e_y0) < $signed(clip_ymin) && $signed(e_y1) < $signed(clip_ymin))
                        || ($signed(e_y0) > $signed(clip_ymax) && $signed(e_y1) > $signed(clip_ymax));

    // LINE: this pixel. x in w_arow, y in w_srow; the pattern's bit, from 31
    wire [15:0] l_x      = w_arow[15:0];
    wire [15:0] l_y      = w_srow[15:0];
    wire        l_in     = $signed(l_x) >= $signed(clip_xmin) && $signed(l_x) <= $signed(clip_xmax)
                        && $signed(l_y) >= $signed(clip_ymin) && $signed(l_y) <= $signed(clip_ymax);
    wire        l_a      = job_value[5'd31 - {1'b0, w_ao}];
    wire        l_keep   = !l_a && (job_minterm[3:0] == 4'hA);          // D = C: nothing to do
    wire        l_needc  = (job_bpp != 2'd3) || cdep(l_a ? job_minterm[7:4] : job_minterm[3:0]);
    wire [4:0]  l_bits   = 5'd1 << job_bpp;
    wire [15:0] l_pm     = (16'hFFFF >> w_od) & ~(16'hFFFF >> ({1'b0, w_od} + l_bits));
    wire [15:0] l_res    = minterm(job_minterm, {16{l_a}}, pattern({4{job_value[7:0]}}, job_bpp, 1'b0), l_c);
    wire [17:0] l_e      = w_sw[17:0];
    wire        l_minor  = !l_e[17] && (l_e != 18'd0);                    // E > 0: the shorter axis too

    // Job checks: OP 4-7 and MASK 3 are errors, so are OP 2 without LINE,
    // OP 3 without EDGES, MASK 1 without MASKIMG, and whatever the wrapper
    // rejects. LINE: no DESC or MASK, WIDTH up to 32,768, HEIGHT up to
    // WIDTH - 1
    wire        bad_line = is_l && (job_desc || job_mask != 2'd0 || job_width > 24'd32768
                                                || (job_width != 24'd0 && {8'd0, job_height} > job_width - 1'b1));
    // EDGES: no DESC or MASK, even POINTS and EDGES, up to 65,535 edges
    wire        bad_edges = is_e && (job_desc || job_mask != 2'd0 || job_aaddr[0] || job_baddr[0]
                                     || job_width[23:16] != 8'd0);
    // A port job: a plain copy (BLIT 0xCC, no mask), FIFO to memory or
    // memory to FIFO, one row of bytes, forwards
    wire        bad_port = (PORTJOB == 0 && (job_bport || job_dport))
                        || (portjob && (job_op != 3'd0 || job_minterm != 8'hCC || job_mask != 2'd0 || job_bconst
                                        || (job_bport && job_dport) || job_bpp != 2'd3 || job_height != 16'd1
                                        || job_desc));
    wire        bad_op   = (job_op > 3'd3) || (LINE == 0 && job_op == 3'd2) || (EDGES == 0 && job_op == 3'd3)
                        || (job_mask == 2'd3) || (MASKIMG == 0 && job_mask == 2'd1) || job_bad
                        || bad_line || bad_edges || bad_port;

    // Row start
    reg  [26:0] rs_sba, rs_dba, rs_aba;  // the row's first bits
    reg  [32:0] mul_s, mul_d;

    // The interrupt at S_SAVE: an error, or the end of a job that asks for one
    wire        job_end  = w_rows == 16'd0 && (mode[cur] == M_ROW || mode[cur] == M_SETUP);
    assign irq_set = ((es == S_SAVE) && (e_bad || (job_end && job_irq))) ? (4'd1 << cur) : 4'd0;

`ifdef BLITTER_TRACE
    reg [4:0] es_d;
    integer tclk = 0;
    always @(posedge clk) begin
        tclk = tclk + 1;
        es_d <= es;
        if (es != es_d) $display("%0d blt es %0d -> %0d cur %0d busy %b mode %0d rows %0d dleft %0d", tclk, es_d, es, cur, busy, mode[cur], w_rows, w_dleft);
        if (xq_take) $display("%0d blt take w %h we %b", tclk, xq_w, xq_we);
        if (mem_ack) $display("%0d blt ack", tclk);
    end
`endif

    // Into S_WR: the write pipeline from the group's first word. From S_DR,
    // and straight from S_RD or S_RA when there is nothing more to read
    // before the writes.
    task go_wr;
        begin
            wj   <= 5'd0;
            sptr <= w_pre ? 5'd1 : 5'd0;
            if (w_pre) w_carry <= s_0;
            // the row's first mask word: its first bit lined up with the
            // destination's first pixel
            aptr <= 5'd0;
            if (w_first && maskimg) begin
                w_areg <= ({abuf[0], 16'd0} << w_ao) >> (w_od >> job_bpp);
                w_acnt <= 5'd16 + {1'b0, w_od >> job_bpp} - {1'b0, w_ao};
                aptr   <= 5'd1;
            end
            a_v <= 1'b0; b_v <= 1'b0;
            es  <= S_WR;
        end
    endtask

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            es <= S_IDLE;
            w_live <= 1'b0;
            mem_req <= 1'b0; xp_req <= 1'b0;
            chip_out <= 5'd0; x_out <= 5'd0;
            busy <= 4'd0; done <= 4'd0; err <= 4'd0; stopreq <= 4'd0;
            last_ch <= 2'd3;
            for (i = 0; i < 4; i = i + 1) begin
                chdesc[i] <= 24'd0; cherr[i] <= 24'd0; mode[i] <= M_LOAD;
            end
        end else begin
            // ---------------------------------------------------- the access unit
            if (xq_bad && !e_bad) begin
                e_bad  <= 1'b1;
                e_addr <= {xq_w, 1'b0};
            end
            // The memory port: one request, held until taken
            if (xq_tchip) begin
                mem_req   <= 1'b1;
                mem_we    <= xq_we;
                mem_addr  <= xq_w[20:0];
                mem_wdata <= x_wd;
                mem_be    <= x_be;
            end else if (mem_ack)
                mem_req <= 1'b0;
            chip_out <= chip_out + ((xq_tchip && !xq_we) ? 5'd1 : 5'd0)
                                 - (mem_rvalid ? 5'd1 : 5'd0);
            // The other port, the same way
            if (XPORT != 0) begin
                if (xq_take && !xq_chip) begin
                    xp_req   <= 1'b1;
                    xp_we    <= xq_we;
                    xp_addr  <= xq_w;
                    xp_wdata <= x_wd;
                    xp_be    <= x_be;
                end else if (xp_ack)
                    xp_req <= 1'b0;
                x_out <= x_out + ((xq_take && !xq_chip && !xq_we) ? 5'd1 : 5'd0)
                               - (xp_rvalid ? 5'd1 : 5'd0);
            end
            // Source words, in S_RD and still coming back in S_WR: one
            // write port, so sbuf can be distributed RAM
            if (x_rv && (es == S_RD || es == S_WR)) begin
                sbuf[s_have] <= job_desc ? rev16(x_rd) : x_rd;
                if (s_have == 5'd0) s_0 <= job_desc ? rev16(x_rd) : x_rd;
                s_have <= s_have + 1'b1;
            end

            case (es)
            // ---------------------------------------------------- pick a channel
            S_IDLE: if (|runnable) begin : pick
                integer o;
                reg [1:0] c;
                reg       f;
                f = 1'b0;
                c = last_ch;
                for (o = 0; o < 4; o = o + 1) begin
                    c = c + 1'b1;
                    if (!f && runnable[c]) begin f = 1'b1; cur <= c; end
                end
                es <= S_REST;
            end

            S_REST: begin
                if (!(w_live && w_ch == cur))
                    {w_rows, w_srow, w_drow, w_dw, w_sw, w_dleft, w_sleft,
                     w_od, w_t, w_pre, w_first, w_le, w_carry,
                     w_arow, w_aw, w_aleft, w_ao, w_areg, w_acnt} <= st[cur];
                su_back <= 1'b0;
                last_ch <= cur;
                e_bad   <= 1'b0;
                r_tot <= 5'd0; r_iss <= 5'd0; r_got <= 5'd0;
                su_i  <= 3'd0;
                case (mode[cur])
                    M_LOAD: begin
                        // the descriptor: a multiple of 4, all 32 bytes on
                        // the memory port (or where the wrapper allows)
                        r_a <= chdesc[cur][23:1];
                        if (chdesc[cur][1:0] != 2'd0 ||
                            !((inchip(chdesc[cur][23:1]) && inchip(chdesc[cur][23:1] + 23'd15))
                              || (XPORT != 0 && dl_xok))) begin
                            e_addr <= chdesc[cur];
                            e_bad  <= 1'b1;
                            es     <= S_SAVE;
                        end else
                            es <= S_DESC;
                    end
                    M_SETUP: es <= S_SETUP;
                    default: if (w_live && w_ch == cur)
                                 es <= (is_l || is_e) ? S_LPIX : (mode[cur] == M_ROW) ? S_ROW1 : S_GRP;
                             else begin
                                 su_back <= 1'b1;
                                 es <= S_SETUP;
                             end
                endcase
            end

            // ---------------------------------------------------- load a descriptor
            // 16 words, each pair a job long word, the lower address first
            // (a long word comes at most every 4 clocks: a waiting store in
            // the wrapper has landed by the next)
            S_DESC: begin
                if (xq_take) begin
                    r_a   <= r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    r_got <= r_got + 1'b1;
                    if (!r_got[0]) dl_w0 <= x_raw;
                end
                if (r_got == 5'd16 && !dl_wait) begin
                    mode[cur] <= M_SETUP;
                    su_i <= 3'd0;
                    es   <= S_SETUP;
                end
            end

            // ---------------------------------------------------- start a job
            // The wrapper reads the job, a long word a clock, onto the job ports
            S_SETUP: begin
                su_i <= su_i + 1'b1;
                if (su_i == 3'd7) es <= su_back ? S_BACK : S_CHECK;
            end
            // back to a job after another channel's turn: the width in bits again
            S_BACK: begin
                w_nbits <= {3'd0, job_width} << job_bpp;
                es <= (is_l || is_e) ? S_LSET : (mode[cur] == M_ROW) ? S_ROW1 : S_GRP;
            end

            S_CHECK: begin
                w_nbits <= {3'd0, job_width} << job_bpp;
                mul_s   <= $signed({1'b0, job_height - 1'b1}) * $signed(job_bstride);
                mul_d   <= $signed({1'b0, job_height - 1'b1}) * $signed(job_dstride);
                // the progress from the job
                w_arow  <= job_aaddr;
                w_srow  <= job_baddr;
                w_drow  <= job_daddr;
                w_rows  <= job_height;
                if (bad_op) begin
                    e_addr <= chdesc[cur];
                    e_bad  <= 1'b1;
                    es     <= S_SAVE;
                end else if (is_e) begin
                    if (job_width == 24'd0) begin
                        w_rows <= 16'd0;             // no edges: the job ends
                        es     <= S_SAVE;
                    end else begin
                        w_rows  <= job_width[15:0];  // the edges left
                        w_aw    <= job_baddr[23:1];  // the first edge's word
                        r_iss   <= 5'd0; r_got <= 5'd0;
                        mode[cur] <= M_RUN;
                        es      <= S_EFETCH;
                    end
                end else if (is_l) begin
                    if (job_width == 24'd0) begin
                        w_rows <= 16'd0;             // nothing to do: the job ends
                        es     <= S_SAVE;
                    end else begin
                        // the first pixel; the rest is worked out in S_LSET
                        w_rows  <= 16'd1;
                        {w_dw, w_od} <= {job_daddr, 3'b000} + ({24'd0, job_dbit} << job_bpp);
                        w_sw    <= {5'd0, job_height, 1'b0} - {5'd0, job_width[17:0]} + 23'd1;    // 2N - M
                        w_dleft <= job_width;
                        w_ao    <= 4'd0;
                        mode[cur] <= M_RUN;
                        es      <= S_LSET;
                    end
                end else if (job_width == 24'd0 || job_height == 16'd0) begin
                    w_rows <= 16'd0;                 // nothing to do: the job ends
                    es     <= S_SAVE;
                end else if (portjob) begin
                    w_dleft   <= job_width;          // bytes
                    mode[cur] <= M_RUN;
                    es        <= S_GRP;
                end else
                    es <= S_MUL;
            end

            S_MUL: begin
                // backwards: start from the last row
                if (job_desc) begin
                    w_srow <= w_srow + mul_s[23:0];
                    w_arow <= w_arow + mul_s[23:0];
                    w_drow <= w_drow + mul_d[23:0];
                end
                es <= S_ROW1;
            end

            // ---------------------------------------------------- start a row
            S_ROW1: begin
                rs_sba <= {w_srow, 3'b000} + ({24'd0, job_bbit} << job_bpp);
                rs_dba <= {w_drow, 3'b000} + ({24'd0, job_dbit} << job_bpp);
                rs_aba <= {w_arow, 3'b000} + {24'd0, job_abit};
                es <= S_ROW2;
            end
            S_ROW2: begin : row2
                reg [26:0] se, de, ae;
                se = rs_sba + w_nbits;
                de = rs_dba + w_nbits;
                ae = rs_aba + {3'd0, job_width};
                if (!job_desc) begin
                    w_ao <= rs_aba[3:0];
                    w_aw <= rs_aba[26:4];
                end else begin
                    w_ao <= 4'd0 - ae[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_aw <= (ae - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                end
                if (!job_desc) begin
                    w_od <= rs_dba[3:0];
                    w_dw <= rs_dba[26:4];
                    w_t  <= rs_sba[3:0];          // the source's start bit, for now
                    w_sw <= rs_sba[26:4];
                end else begin
                    w_od <= 4'd0 - de[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_dw <= (de - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                    w_t  <= 4'd0 - se[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_sw <= (se - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                end
                es <= S_ROW3;
            end
            S_ROW3: begin : row3
                reg [27:0] dn, sn, an;
                dn = {1'b0, w_nbits} + w_od + 4'd15;
                sn = {1'b0, w_nbits} + w_t + 4'd15;
                an = {4'd0, job_width} + w_ao + 4'd15;
                w_dleft <= dn[27:4];
                w_sleft <= srcmem ? sn[27:4] : 24'd0;
                w_pre   <= srcmem && (w_t >= w_od);
                w_t     <= srcmem ? w_t - w_od : 4'd0;
                w_le    <= w_od + w_nbits[3:0];
                w_first <= 1'b1;
                w_aleft <= an[27:4];
                w_acnt  <= 5'd0;
                mode[cur] <= M_RUN;
                es <= S_GRP;
            end

            // ---------------------------------------------------- a group
            S_GRP: if (portjob) begin
                pc_n   <= 4'd0;
                p_rd   <= 1'b0;
                p_have <= 1'b0;
                es     <= S_PORT;
            end else begin : grp
                reg [4:0] n, nr, ga;
                reg [24:0] want;
                reg [8:0] need, avail, extra, na;
                reg [15:0] dn;
                reg [23:0] lw;
                integer j;
                n    = (w_dleft > 24'd16) ? 5'd16 : w_dleft[4:0];
                want = n + w_pre;
                nr   = (want > w_sleft) ? w_sleft[4:0] : want[4:0];
                // mask words: the row's first, then enough for n words of pixels
                need  = {4'd0, n} << (3'd4 - {1'b0, job_bpp});
                avail = w_first ? {5'd0, w_od >> job_bpp} + 9'd16 - {5'd0, w_ao} : {4'd0, w_acnt};
                extra = (need > avail) ? (need - avail + 9'd15) >> 4 : 9'd0;
                na    = extra + (w_first ? 9'd1 : 9'd0);
                ga    = !maskimg ? 5'd0 : ({15'd0, na} > w_aleft) ? w_aleft[4:0] : na[4:0];
                // the row's last word, when it is in this group and covered in part
                lw = w_dleft - 1'b1;
                for (j = 0; j < 16; j = j + 1)
                    dn[j] = (j < n) && (op_rd || (w_first && j == 0 && w_od[2:0] != 3'd0)
                                        || (w_dleft <= 24'd16 && lw[3:0] == j[3:0] && w_le[2:0] != 3'd0));
                g_na  <= ga;
                g_n  <= n;
                g_nr <= nr;
                g_last <= (w_dleft > 24'd16) ? 5'd16 : w_dleft[4:0] - 1'b1;
                g_dneed <= dn;
                r_tot <= nr; r_iss <= 5'd0; r_got <= 5'd0;
                s_have <= 5'd0;
                r_a   <= w_sw;
                // on to S_RD even with no B words to read: it decides from
                // the counts registered here (a fill goes from there
                // straight to the writes, a group with only C words to S_DR)
                es <= S_RD;
            end

            S_RD: begin
                if (xq_take) begin
                    r_a   <= job_desc ? r_a - 1'b1 : r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) r_got <= r_got + 1'b1;   // the word itself: sbuf, above
                // Every source read made, and nothing else to read: the
                // writes start while the last reads come back. The first
                // word is needed now when it is carried in.
                if (r_iss == r_tot && g_na == 5'd0 && g_dneed == 16'd0 && !e_bad
                    && (!w_pre || s_have != 5'd0)) begin
                    w_sw    <= r_a;
                    w_sleft <= w_sleft - g_nr;
                    go_wr;
                end else
                // (a bad access sets e_bad the clock it is seen, so only
                // "nothing left" or e_bad need looking at here: short paths).
                // With nothing but C words to read there is nothing of
                // this phase's to wait for: a write still held from the
                // last group is left to the access unit.
                if (r_got == r_iss && (r_iss == r_tot || e_bad)
                    && (!acc_held || (r_tot == 5'd0 && g_na == 5'd0))) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        w_sw    <= r_a;
                        w_sleft <= w_sleft - g_nr;
                        r_iss <= 5'd0; r_got <= 5'd0;
                        r_tot <= g_na;
                        r_a   <= w_aw;
                        es    <= (g_na != 5'd0) ? S_RA : S_DR;
                    end
                end
            end

            // the mask image's words, as S_RD
            S_RA: begin
                if (xq_take) begin
                    r_a   <= job_desc ? r_a - 1'b1 : r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    abuf[r_got] <= job_desc ? rev16(x_rd) : x_rd;
                    r_got <= r_got + 1'b1;
                end
                if (r_got == r_iss && (r_iss == r_tot || e_bad) && !acc_held) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        w_aw    <= r_a;
                        w_aleft <= w_aleft - g_na;
                        r_tot <= 5'd0; r_iss <= 5'd0; r_got <= 5'd0;
                        if (g_dneed != 16'd0) es <= S_DR;
                        else go_wr;
                    end
                end
            end

            S_DR: begin
                if (xq_take) begin
                    q_j[r_iss[3:0]] <= dr_j;
                    g_dneed[dr_j] <= 1'b0;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    dbuf[q_j[r_got[3:0]]] <= x_rd;
                    r_got <= r_got + 1'b1;
                end
                if (r_got == r_iss && (g_dneed == 16'd0 || e_bad) && !acc_held) begin
                    if (e_bad) es <= S_DRAIN;
                    else go_wr;
                end
            end

            S_WR: begin
                if (b_take) b_v <= 1'b0;
                // stage B
                if (a_move) begin
                    b_v    <= 1'b1;
                    b_w    <= a_w;
                    b_out  <= (res & mfin) | (a_d & ~mfin);
                    b_be   <= {|mfin[15:8], |mfin[7:0]};
                    b_skip <= (mfin == 16'd0);
                    a_v    <= 1'b0;
                end
                // stage A
                if (a_new) begin
                    a_v <= 1'b1;
                    a_s <= a_st;
                    a_m <= a_mt;
                    a_d <= dbuf[wj[3:0]];
                    a_a <= a_at;
                    a_w <= a_wa;
                    if (maskimg) begin
                        w_areg <= a_regi << a_k;
                        w_acnt <= (a_ins ? w_acnt + 5'd16 : w_acnt) - a_k;
                        if (a_ins) aptr <= aptr + 1'b1;
                    end
                    if (a_hasn) begin
                        w_carry <= a_B;
                        sptr    <= sptr + 1'b1;
                    end
                    wj <= wj + 1'b1;
                end
                if (e_bad) begin
                    a_v <= 1'b0; b_v <= 1'b0;
                    if (!acc_held) es <= S_DRAIN;
                end else if (!a_v && !b_v && wj == g_n && !rd_out
                             && (wr_on || !acc_held)) begin
                    // the group is done. On to the same channel's next group
                    // with the last write still waiting for its cycle: the
                    // access unit holds the next request until it is taken.
                    // Anywhere else, the write is taken first.
                    w_dw    <= job_desc ? w_dw - g_n : w_dw + g_n;
                    w_dleft <= w_dleft - g_n;
                    w_first <= 1'b0;
                    w_pre   <= 1'b0;
                    if (w_dleft == {19'd0, g_n}) begin
                        // the row is done
                        w_rows <= w_rows - 1'b1;
                        w_srow <= job_desc ? w_srow - {{8{job_bstride[15]}}, job_bstride} : w_srow + {{8{job_bstride[15]}}, job_bstride};
                        w_arow <= job_desc ? w_arow - {{8{job_bstride[15]}}, job_bstride} : w_arow + {{8{job_bstride[15]}}, job_bstride};
                        w_drow <= job_desc ? w_drow - {{8{job_dstride[15]}}, job_dstride} : w_drow + {{8{job_dstride[15]}}, job_dstride};
                        mode[cur] <= M_ROW;
                    end
                    // Carry on with the same channel when it is the only one
                    // that can run and no STOP waits: its progress stays in
                    // the w_ registers, so the save, the pick and the restore
                    // (S_SAVE, S_IDLE, S_REST) are left out. They are still
                    // taken at the end of the job, for a STOP or a pause, and
                    // when another channel waits (round robin).
                    if (wr_on)
                        es <= (w_dleft == {19'd0, g_n}) ? S_ROW1 : S_GRP;
                    else
                        es <= S_SAVE;
                end
            end

            // ---------------------------------------------------- LINE
            // E's two steps and the address's two steps, from the fixed fields
            S_LSET: if (LS) begin : lset
                reg [26:0] xs, ys;
                l_ins  <= {1'b0, l_nn, 1'b0};
                l_ind  <= {1'b0, l_nn, 1'b0} - {1'b0, l_mm, 1'b0};               // 2(N - M)
                xs = {22'd0, l_bits};
                ys = {{8{job_dstride[15]}}, job_dstride, 3'b000};
                if (l_xneg) xs = 27'd0 - xs;
                if (l_yneg) ys = 27'd0 - ys;
                l_dmaj <= l_ymaj ? ys : xs;
                l_dmin <= l_ymaj ? xs : ys;
                l_k    <= 4'd0;
                es     <= S_LPIX;
            end
            // the next pixel: drawn, left alone or clipped
            S_LPIX: if (LS) begin
                r_iss <= 5'd0; r_got <= 5'd0;
                l_c   <= 16'd0;                  // (C not read: the result does not use it)
                if (w_dleft == 24'd0 && is_e) begin
                    w_rows <= w_rows - 1'b1;     // EDGES: on to the next edge
                    w_aw   <= w_aw + 1'b1;
                    es     <= S_EFETCH;
                end else if (w_dleft == 24'd0) begin
                    if (!acc_held) begin         // the line is done, its last write taken
                        w_rows    <= 16'd0;
                        mode[cur] <= M_ROW;
                        es        <= S_SAVE;
                    end
                end else if (!l_in || l_keep)
                    es <= S_LSTEP;
                else
                    es <= l_needc ? S_LRD : S_LCMB;
            end
            S_LRD: if (LS) begin
                if (xq_take) r_iss <= 5'd1;
                if (x_rv) begin
                    l_c   <= x_rd;
                    r_got <= 5'd1;
                end
                if (e_bad) begin
                    if (!acc_held) es <= S_DRAIN;
                end else if (r_got == 5'd1 && !acc_held)
                    es <= S_LCMB;
            end
            S_LCMB: if (LS) begin
                b_out <= (l_res & l_pm) | (l_c & ~l_pm);
                b_be  <= {|l_pm[15:8], |l_pm[7:0]};
                r_iss <= 5'd0;
                es    <= S_LWR;
            end
            S_LWR: if (LS) begin
                if (xq_take) r_iss <= 5'd1;
                if (e_bad) begin
                    if (!acc_held) es <= S_DRAIN;
                end else if (r_iss == 5'd1 || xq_take)
                    es <= S_LSTEP;
            end
            // on along the line (after the last pixel the count reaches 0)
            S_LSTEP: if (LS) begin
                w_dleft <= w_dleft - 1'b1;
                w_ao    <= w_ao + 1'b1;
                w_sw    <= {5'd0, l_e + (l_minor ? l_ind : l_ins)};
                // 23-bit byte addresses, wrapping
                {w_dw, w_od} <= ({w_dw, w_od} + l_dmaj + (l_minor ? l_dmin : 27'd0)) & 27'h3FFFFFF;
                if (l_ymaj || l_minor) w_srow[15:0] <= l_yneg ? l_y - 1'b1 : l_y + 1'b1;
                if (!l_ymaj || l_minor) w_arow[15:0] <= l_xneg ? l_x - 1'b1 : l_x + 1'b1;
                l_k <= l_k + 1'b1;
                // a turn is 16 pixels, then the other channels have theirs
                es  <= (l_k == 4'd15) ? S_SAVE : S_LPIX;
            end

            // ---------------------------------------------------- EDGES
            // the next edge's word, or the end of the job
            S_EFETCH: if (ES) begin
                if (w_rows == 16'd0) begin
                    if (!acc_held) begin         // every edge done, the last write taken
                        mode[cur] <= M_ROW;
                        es        <= S_SAVE;
                    end
                end else begin
                    if (xq_take) r_iss <= 5'd1;
                    if (x_rv) begin
                        e_ab  <= {x_rd[7:0], x_rd[15:8]};   // the even byte (a) in bits 7-0
                        r_got <= 5'd1;
                    end
                    if (e_bad) begin
                        if (!acc_held) es <= S_DRAIN;
                    end else if (r_got == 5'd1 && !acc_held) begin
                        r_iss <= 5'd0; r_got <= 5'd0;
                        es    <= S_EPTS;
                    end
                end
            end
            // its two points: x and y of a, then of b (words as stored)
            S_EPTS: if (ES) begin
                if (xq_take) r_iss <= r_iss + 1'b1;
                if (x_rv) begin
                    case (r_got[1:0])
                        2'd0: e_x0 <= x_raw;
                        2'd1: e_y0 <= x_raw;
                        2'd2: e_x1 <= x_raw;
                        default: e_y1 <= x_raw;
                    endcase
                    r_got <= r_got + 1'b1;
                end
                if (e_bad) begin
                    if (!acc_held) es <= S_DRAIN;
                end else if (r_got == 5'd4 && !acc_held)
                    es <= S_ECALC;
            end
            // left out, or set up as a line
            S_ECALC: if (ES) begin
                r_iss <= 5'd0; r_got <= 5'd0;
                if (e_range || e_beyond) begin
                    w_rows <= w_rows - 1'b1;
                    w_aw   <= w_aw + 1'b1;
                    es     <= S_EFETCH;
                end else begin
                    w_le    <= {1'b0, e_dy[16], e_dx[16], e_ymaj};
                    w_carry <= e_n;
                    w_aleft <= {8'd0, e_m};
                    w_dleft <= {8'd0, e_m} + 1'b1;
                    w_sw    <= {6'd0, e_n, 1'b0} - {7'd0, e_m};        // 2N - M
                    w_ao    <= 4'd0;
                    w_arow[15:0] <= e_x0;
                    w_srow[15:0] <= e_y0;
                    e_mul   <= $signed(e_y0) * $signed(job_dstride);
                    es      <= S_EADDR;
                end
            end
            // the first pixel's bit address: origin + 8 y stride + x BPP
            S_EADDR: if (ES) begin
                {w_dw, w_od} <= ({job_daddr[22:0], 3'b000} + ({24'd0, job_dbit} << job_bpp) + {e_mul[23:0], 3'b000}
                                 + ({{11{e_x0[15]}}, e_x0} << job_bpp)) & 27'h3FFFFFF;
                es <= S_LSET;
            end

            // ---------------------------------------------------- a port job
            // Up to 8 bytes, then the next channel's turn; sooner if the FIFO
            // is not ready (a byte read for the FIFO but not sent is read
            // again next time)
            S_PORT: if (PORTJOB != 0) begin : port
                reg stp;
                if (job_bport) begin
                    if (xq_take) begin
                        w_drow  <= w_drow + 1'b1;
                        w_dleft <= w_dleft - 1'b1;
                        pc_n    <= pc_n + 1'b1;
                    end
                    stp = !xq_take && (!p_rxv || pc_n == 4'd8 || w_dleft == 24'd0);
                end else begin
                    if (xq_take) p_rd <= 1'b1;
                    if (x_rv) begin
                        p_txd  <= w_srow[0] ? x_rd[7:0] : x_rd[15:8];
                        p_have <= 1'b1;
                        p_rd   <= 1'b0;
                    end
                    if (p_txpush) begin
                        p_have  <= 1'b0;
                        w_srow  <= w_srow + 1'b1;
                        w_dleft <= w_dleft - 1'b1;
                        pc_n    <= pc_n + 1'b1;
                    end
                    stp = !p_rd && !xq_take && !x_rv && ((p_have && !p_txr) || (!p_have && (pc_n == 4'd8 || w_dleft == 24'd0)));
                end
                if ((stp || e_bad) && !acc_held && !p_rd) begin
                    p_have <= 1'b0;
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        if (w_dleft == 24'd0) begin
                            w_rows    <= 16'd0;
                            mode[cur] <= M_ROW;
                        end
                        es <= S_SAVE;
                    end
                end
            end else
                es <= S_IDLE;

            // after an error: wait for every read asked for to come back
            S_DRAIN: if (!rd_out && !acc_held) es <= S_SAVE;

            // ---------------------------------------------------- end of a group or job
            S_SAVE: begin
                st[cur] <= w_pack;
                w_live <= 1'b1;
                w_ch   <= cur;
                es <= S_IDLE;
                if (e_bad) begin
                    busy[cur]  <= 1'b0;
                    err[cur]   <= 1'b1;
                    cherr[cur] <= e_addr;
                end else if (job_end) begin
                    if (job_next != 24'd0 && !stopreq[cur]) begin
                        chdesc[cur] <= job_next;
                        mode[cur]   <= M_LOAD;
                    end else begin
                        busy[cur]    <= 1'b0;
                        done[cur]    <= 1'b1;
                        stopreq[cur] <= 1'b0;
                    end
                end else if (stopreq[cur]) begin
                    busy[cur]    <= 1'b0;
                    done[cur]    <= 1'b1;
                    stopreq[cur] <= 1'b0;
                end
            end
            default: es <= S_IDLE;
            endcase

            // ---------------------------------------------------- the channel strobes
            // After the engine's changes, so a strobe wins in the same clock
            for (i = 0; i < 4; i = i + 1) begin
                if (stop[i] && busy[i]) stopreq[i] <= 1'b1;
                if (clr_done[i]) done[i] <= 1'b0;
                if (clr_err[i])  err[i]  <= 1'b0;
                if (da_we[i] && !busy[i]) chdesc[i] <= da_d;
                if ((start_ld[i] || start_run[i]) && !busy[i]) begin
                    busy[i]    <= 1'b1;
                    stopreq[i] <= 1'b0;
                    mode[i]    <= start_ld[i] ? M_LOAD : M_SETUP;
                end
            end
        end
    end
endmodule
