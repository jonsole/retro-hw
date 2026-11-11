// The blitter (docs/spec/blitter.md, revision 2): rectangles of pixels in
// memory, one job at a time, with a chain to the next descriptor. Each
// destination pixel D is job_minterm of A (a 1-bit mask), B (the source)
// and C (the destination's old contents). No registers: the machine's
// wrapper holds the job and drives it as ports; the core reads descriptors
// from memory and hands them over a long word at a time.
//
// Inside, every word is held with the even byte in bits 15-8, so that a
// word's bits from 15 down are its pixels in address order. A row worked
// right to left (job_rtl) has every word bit-reversed on the way in and
// back again on the way out: then the same left-to-right datapath works,
// with only the word addresses counting down.
//
// A destination word: its mask bits if they have run out (read A), then
// its source and old contents (read B, read C, asked for one after the
// other), then the combine and the write. B is lined up with D by a barrel
// shifter over the last two source words; when the source starts further
// into its word than the destination, one source word is read ahead at the
// row's start.
module blitter #(
    parameter AW      = 21,                    // word address width, 15 to 23
    parameter LE      = 0,                     // 1: memory words little-endian
    parameter MASKIMG = 1                      // 0: no 1-bit mask image (job_mask 1 is an error)
) (
    input  wire          clk,
    input  wire          rst,

    // Control
    input  wire          enable,
    input  wire          start_ld,
    input  wire          start_run,
    input  wire          stop,
    input  wire          da_we,
    input  wire [23:0]   da_d,
    output wire [23:0]   da_q,
    output reg           busy,
    output reg           done,
    output reg           err,

    // The job (the wrapper's decode, steady from the last su_v clock)
    output wire          su_v,
    output reg  [2:0]    su_i,
    input  wire [7:0]    job_minterm,
    input  wire [1:0]    job_mask,
    input  wire [1:0]    job_bpp,
    input  wire          job_rtl,
    input  wire          job_bconst,
    input  wire          job_irq,
    input  wire [15:0]   job_value,
    input  wire [7:0]    job_key,
    input  wire [15:0]   job_astride,
    input  wire [15:0]   job_bstride,
    input  wire [15:0]   job_dstride,
    input  wire [15:0]   job_width,
    input  wire [15:0]   job_height,
    input  wire [23:0]   job_aaddr,
    input  wire [23:0]   job_baddr,
    input  wire [23:0]   job_daddr,
    input  wire [2:0]    job_abit,
    input  wire [2:0]    job_bbit,
    input  wire [2:0]    job_dbit,
    input  wire [23:0]   job_next,
    input  wire          job_bad,

    // Descriptor load
    output reg           dl_v,
    output reg  [2:0]    dl_i,
    output reg  [15:0]   dl_w0,
    output reg  [15:0]   dl_w1,
    input  wire          dl_wait,

    // Memory
    output reg           mem_req,
    output reg           mem_we,
    output reg  [AW-1:0] mem_addr,
    output reg  [15:0]   mem_wdata,
    output reg  [1:0]    mem_be,
    input  wire          mem_ack,
    input  wire          mem_rvalid,
    input  wire [15:0]   mem_rdata
);
    // ---------------------------------------------------------------- helpers
    function [15:0] rev16(input [15:0] v);
        integer i;
        for (i = 0; i < 16; i = i + 1) rev16[i] = v[15 - i];
    endfunction
    // A's bits for a word: bit 15 - j of t to the whole of pixel j
    function [15:0] widen(input [15:0] t, input [1:0] lb);
        integer i;
        case (lb)
            2'd3:    for (i = 0; i < 16; i = i + 1) widen[15 - i] = t[15 - (i >> 3)];
            2'd2:    for (i = 0; i < 16; i = i + 1) widen[15 - i] = t[15 - (i >> 2)];
            2'd1:    for (i = 0; i < 16; i = i + 1) widen[15 - i] = t[15 - (i >> 1)];
            default: widen = t;
        endcase
    endfunction
    // Each pixel all ones where any of its bits is set
    function [15:0] pixor(input [15:0] v, input [1:0] lb);
        integer i;
        case (lb)
            2'd3:    pixor = {{8{|v[15:8]}}, {8{|v[7:0]}}};
            2'd2:    for (i = 0; i < 4; i = i + 1) pixor[4*i +: 4] = {4{|v[4*i +: 4]}};
            2'd1:    for (i = 0; i < 8; i = i + 1) pixor[2*i +: 2] = {2{|v[2*i +: 2]}};
            default: pixor = v;
        endcase
    endfunction
    // The key colour in every pixel of a word
    function [15:0] keyword(input [7:0] k, input [1:0] lb);
        case (lb)
            2'd3:    keyword = {2{k}};
            2'd2:    keyword = {4{k[3:0]}};
            2'd1:    keyword = {8{k[1:0]}};
            default: keyword = {16{k[0]}};
        endcase
    endfunction
    function [15:0] minterm(input [7:0] m, input [15:0] a, input [15:0] b, input [15:0] c);
        minterm = ({16{m[7]}} &  a &  b &  c) | ({16{m[6]}} &  a &  b & ~c)
                | ({16{m[5]}} &  a & ~b &  c) | ({16{m[4]}} &  a & ~b & ~c)
                | ({16{m[3]}} & ~a &  b &  c) | ({16{m[2]}} & ~a &  b & ~c)
                | ({16{m[1]}} & ~a & ~b &  c) | ({16{m[0]}} & ~a & ~b & ~c);
    endfunction

    // ---------------------------------------------------------------- state
    localparam [3:0] S_IDLE = 4'd0,  S_DLR = 4'd1,  S_DLW = 4'd2,  S_SU  = 4'd3,
                     S_CHK  = 4'd4,  S_ROW = 4'd5,  S_BL  = 4'd6,  S_BLW = 4'd7,
                     S_A    = 4'd8,  S_AW  = 4'd9,  S_BC  = 4'd10, S_BCW = 4'd11,
                     S_CALC = 4'd12, S_WR  = 4'd13, S_NXT = 4'd14, S_END = 4'd15;
    reg  [3:0]    st;
    reg  [AW:0]   da;                          // the descriptor address (bytes)
    assign da_q = {{(23-AW){1'b0}}, da};
    reg           stop_p;                      // a stop is asked
    reg  [3:0]    dlc;                         // descriptor words asked for
    reg  [1:0]    dl_got;                      // words of the pair back
    assign su_v = (st == S_SU);

    // What the job needs, from its minterm (with no mask A is all ones)
    wire [7:0]    mt   = job_minterm;
    wire [7:0]    mte  = (job_mask == 2'd0) ? {mt[7:4], mt[7:4]} : mt;
    wire          dep_c = (mte[7] ^ mte[6]) | (mte[5] ^ mte[4]) | (mte[3] ^ mte[2]) | (mte[1] ^ mte[0]);
    wire          dep_b = (mte[7] ^ mte[5]) | (mte[6] ^ mte[4]) | (mte[3] ^ mte[1]) | (mte[2] ^ mte[0]);
    wire          dep_a = (mte[7:4] != mte[3:0]);
    wire          rdb   = !job_bconst && (dep_b || job_mask == 2'd2);
    wire          rda   = (MASKIMG != 0) && job_mask == 2'd1 && dep_a;
    wire [1:0]    lb    = job_bpp;
    wire [4:0]    bits  = 5'd1 << lb;

    // The rows: byte addresses of the first pixel worked, and rows left
    reg  [AW:0]   ra, rb, rd;
    reg  [15:0]   rows;
    reg  [1:0]    nx;                          // row end: which address is being moved

    // The row in hand
    reg  [AW-1:0] awa, bwa, dwa;               // word addresses
    reg  [3:0]    od, oa, sh;                  // D's first bit in its word; A's; the shifter's
    reg           lead;                        // B starts further in than D: one word read ahead
    reg  [18:0]   rem;                         // bits of the row still to write
    reg  [15:0]   bprev, bcur, creg;
    reg  [31:0]   areg;                        // mask bits, from bit 31
    reg  [5:0]    acnt;                        // ... how many
    reg           afirst;
    reg           q_b, q_c;                    // B, C still to ask for (this word)
    reg           x_b, x_c;                    // B, C asked for and not back
    reg           w_up;                        // the word's write has been put up

    // Positions of the first pixel in its word (left to right: its first
    // bit; right to left: the same in the bit-reversed word)
    wire [4:0]    qd  = {1'b0, rd[0], 3'b000} + ({2'b00, job_dbit} << lb);
    wire [4:0]    qb  = {1'b0, rb[0], 3'b000} + ({2'b00, job_bbit} << lb);
    wire [4:0]    qa  = {1'b0, ra[0], 3'b000} + {2'b00, job_abit};
    wire [4:0]    od0 = job_rtl ? 5'd16 - bits - qd : qd;
    wire [4:0]    ob0 = job_rtl ? 5'd16 - bits - qb : qb;
    wire [4:0]    oa0 = job_rtl ? 5'd15 - qa : qa;

    // This word: its bits, pixels and mask
    wire [4:0]    room = 5'd16 - {1'b0, od};
    wire [4:0]    cnt  = (rem < {14'd0, room}) ? rem[4:0] : room;
    wire [4:0]    npx  = cnt >> lb;
    wire [4:0]    oe   = {1'b0, od} + cnt;                     // one past the last bit, up to 16
    wire [16:0]   m_lo = 17'h0FFFF >> oe;
    wire [15:0]   m    = (16'hFFFF >> od) & ~m_lo[15:0];       // the row's bits (as worked)
    wire [15:0]   m_r  = job_rtl ? rev16(m) : m;               // ... as in memory, even byte high
    wire          be_e = |m_r[15:8];
    wire          be_o = |m_r[7:0];
    wire          part = (be_e && !(&m_r[15:8])) || (be_o && !(&m_r[7:0]));
    wire          rdc  = dep_c || part;

    // Words in and out
    wire [15:0]   rd_s = (LE != 0) ? {mem_rdata[7:0], mem_rdata[15:8]} : mem_rdata;
    wire [15:0]   win  = job_rtl ? rev16(rd_s) : rd_s;

    // Combine
    wire [31:0]   bsh   = {bprev, bcur} << sh;
    wire [15:0]   b_mem = (sh == 4'd0) ? bcur : bsh[31:16];
    wire [15:0]   b_al  = job_bconst ? (job_rtl ? rev16(job_value) : job_value) : b_mem;
    wire [15:0]   kw    = keyword(job_key, lb);
    wire [15:0]   a_key = pixor(b_al ^ (job_rtl ? rev16(kw) : kw), lb);
    wire [15:0]   a_img = widen(areg[31:16], lb) >> od;
    wire [15:0]   a_al  = (job_mask == 2'd2) ? a_key : rda ? a_img : 16'hFFFF;
    wire [15:0]   d_w   = (minterm(mt, a_al, b_al, creg) & m) | (creg & ~m);
    wire [15:0]   d_r   = job_rtl ? rev16(d_w) : d_w;

    wire [AW:0]   sx_a = {{(AW-15){job_astride[15]}}, job_astride};
    wire [AW:0]   sx_b = {{(AW-15){job_bstride[15]}}, job_bstride};
    wire [AW:0]   sx_d = {{(AW-15){job_dstride[15]}}, job_dstride};
    wire [AW-1:0] one  = job_rtl ? {AW{1'b1}} : {{(AW-1){1'b0}}, 1'b1};   // the next word: -1 or +1

    wire          can  = enable && !mem_req;                   // a request may be put up
    wire          empty = (job_width == 16'd0) || (job_height == 16'd0);
    wire          bad   = job_bad || job_mask == 2'd3 || (job_mask == 2'd1 && MASKIMG == 0);

    task ask(input w, input [AW-1:0] a);
        begin
            mem_req <= 1'b1;  mem_we <= w;  mem_addr <= a;
            if (!w) mem_be <= 2'b11;
        end
    endtask
    task finish(input e);                       // go idle
        begin
            st <= S_IDLE;  busy <= 1'b0;  done <= 1'b1;  err <= e;  stop_p <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        done <= 1'b0;
        dl_v <= 1'b0;
        if (mem_ack) mem_req <= 1'b0;
        if (rst) begin
            st <= S_IDLE;  busy <= 1'b0;  err <= 1'b0;  stop_p <= 1'b0;
            da <= {(AW+1){1'b0}};
            mem_req <= 1'b0;  mem_we <= 1'b0;  mem_be <= 2'b11;
            x_b <= 1'b0;  x_c <= 1'b0;  q_b <= 1'b0;  q_c <= 1'b0;
            // (so a first job that reads no C, B or mask writes no unknowns in simulation)
            creg <= 16'd0;  bprev <= 16'd0;  bcur <= 16'd0;  areg <= 32'd0;
            su_i <= 3'd0;  dl_i <= 3'd0;  w_up <= 1'b0;  dlc <= 4'd0;  dl_got <= 2'd0;
        end else begin
            if (stop && busy) stop_p <= 1'b1;
            case (st)
            S_IDLE: begin
                if (da_we) da <= {da_d[AW:1], 1'b0};
                if (start_ld) begin
                    st <= S_DLR;  busy <= 1'b1;  err <= 1'b0;  dlc <= 4'd0;  dl_got <= 2'd0;  dl_i <= 3'd0;
                end else if (start_run) begin
                    st <= S_SU;  busy <= 1'b1;  err <= 1'b0;  su_i <= 3'd0;
                end
            end

            // The descriptor: two words asked for, both back and the
            // wrapper ready, then the long word is handed over
            S_DLR: begin
                if (mem_rvalid) begin
                    if (dl_got == 2'd0) dl_w0 <= mem_rdata; else dl_w1 <= mem_rdata;
                    dl_got <= dl_got + 1'b1;
                end
                if (stop_p && !dlc[0]) finish(1'b0);
                else if (can) begin
                    ask(1'b0, da[AW:1] + {{(AW-4){1'b0}}, dlc});
                    dlc <= dlc + 1'b1;
                    if (dlc[0]) st <= S_DLW;
                end
            end
            S_DLW: begin
                if (mem_rvalid) begin
                    if (dl_got == 2'd0) dl_w0 <= mem_rdata; else dl_w1 <= mem_rdata;
                    dl_got <= dl_got + 1'b1;
                end
                if (dl_got == 2'd2 && !dl_wait) begin
                    dl_v   <= 1'b1;
                    dl_got <= 2'd0;
                    if (dlc == 4'd0) begin st <= S_SU;  su_i <= 3'd0; end   // all 16 words (the count has wrapped)
                    else st <= S_DLR;
                end
            end

            S_SU: begin
                su_i <= su_i + 1'b1;
                if (su_i == 3'd7) st <= S_CHK;
            end
            S_CHK: begin
                if (stop_p)     finish(1'b0);
                else if (bad)   finish(1'b1);
                else if (empty) st <= S_END;
                else begin
                    ra <= job_aaddr[AW:0];  rb <= job_baddr[AW:0];  rd <= job_daddr[AW:0];
                    rows <= job_height;
                    st <= S_ROW;
                end
            end

            S_ROW: begin
                awa <= ra[AW:1];  bwa <= rb[AW:1];  dwa <= rd[AW:1];
                od  <= od0[3:0];  oa <= oa0[3:0];
                sh  <= ob0[3:0] - od0[3:0];
                lead <= rdb && (ob0 > od0);
                rem <= {3'd0, job_width} << lb;
                afirst <= 1'b1;  acnt <= 6'd0;
                st <= (rdb && (ob0 > od0)) ? S_BL : S_A;
            end

            // One source word ahead
            S_BL: if (can) begin
                ask(1'b0, bwa);  bwa <= bwa + one;  st <= S_BLW;
            end
            S_BLW: if (mem_rvalid) begin
                bcur <= win;  st <= S_A;
            end

            // The mask bits this word needs
            S_A: begin
                if (rda && acnt < {1'b0, npx}) begin
                    if (can) begin ask(1'b0, awa);  awa <= awa + one;  st <= S_AW; end
                end else begin
                    q_b <= rdb;  q_c <= rdc;  st <= S_BC;
                end
            end
            S_AW: if (mem_rvalid) begin
                if (afirst) begin
                    areg  <= {win, 16'h0000} << oa;
                    acnt  <= 6'd16 - {2'b00, oa};
                end else begin
                    areg  <= areg | ({win, 16'h0000} >> acnt);
                    acnt  <= acnt + 6'd16;
                end
                afirst <= 1'b0;
                st <= S_A;
            end

            // B and C: asked for one after the other, then both awaited
            S_BC: begin
                if (q_b) begin
                    if (can) begin ask(1'b0, bwa);  bwa <= bwa + one;  q_b <= 1'b0;  x_b <= 1'b1; end
                end else if (q_c) begin
                    if (can) begin ask(1'b0, dwa);  q_c <= 1'b0;  x_c <= 1'b1; end
                end else st <= S_BCW;
                if (mem_rvalid) begin
                    if (x_b) begin bprev <= bcur;  bcur <= win;  x_b <= 1'b0; end
                    else     begin creg <= win;  x_c <= 1'b0; end
                end
            end
            S_BCW: begin
                if (mem_rvalid) begin
                    if (x_b) begin bprev <= bcur;  bcur <= win;  x_b <= 1'b0; end
                    else     begin creg <= win;  x_c <= 1'b0; end
                end
                if (!x_b && !x_c) st <= S_CALC;
            end

            S_CALC: begin
                mem_wdata <= (LE != 0) ? {d_r[7:0], d_r[15:8]} : d_r;
                mem_be    <= (LE != 0) ? {be_o, be_e} : {be_e, be_o};
                if (rda) begin
                    areg <= areg << npx;
                    acnt <= acnt - {1'b0, npx};
                end
                st <= S_WR;
            end
            S_WR: begin
                if (can && !w_up) begin
                    ask(1'b1, dwa);  w_up <= 1'b1;
                end
                if (mem_ack && w_up) begin
                    w_up   <= 1'b0;
                    mem_we <= 1'b0;
                    rem <= rem - {14'd0, cnt};
                    dwa <= dwa + one;
                    od  <= 4'd0;
                    if (rem == {14'd0, cnt}) begin st <= S_NXT;  nx <= 2'd0; end
                    else if (stop_p) finish(1'b0);
                    else st <= S_A;
                end
            end

            // The row's end: the three addresses move on, one a clock
            S_NXT: begin
                nx <= nx + 1'b1;
                case (nx)
                    2'd0: ra <= ra + sx_a;
                    2'd1: rb <= rb + sx_b;
                    default: begin
                        rd   <= rd + sx_d;
                        rows <= rows - 1'b1;
                        if (rows == 16'd1) st <= S_END;
                        else if (stop_p)   finish(1'b0);
                        else               st <= S_ROW;
                    end
                endcase
            end

            // The job's end: the chain, or idle
            default: begin   // S_END
                if (!stop_p && job_next[AW:1] != {AW{1'b0}}) begin
                    da   <= {job_next[AW:1], 1'b0};
                    done <= job_irq;
                    st   <= S_DLR;  dlc <= 4'd0;  dl_got <= 2'd0;  dl_i <= 3'd0;
                end else finish(1'b0);
            end
            endcase

            if (dl_v) dl_i <= dl_i + 1'b1;                          // the next long word's number
        end
    end
endmodule
