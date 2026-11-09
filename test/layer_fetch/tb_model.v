`timescale 1ns/1ps
// layer_fetch against a model of what should reach the data registers and
// where the pointers should end up, for builds the machines don't have:
// set with -P (the Makefile runs several). Memory is a hash of the word
// address, so every expected word can be worked out from the pointer
// rules alone (spec 4.2, 4.3, 4.5):
//   - each group that fills (fill_t toggles) must hold the words of the
//     model's pointers, laid into the data registers as the spec says, and
//     for a tile layer the rows the map entries pick (and attr);
//   - at each line start, once the core's catch-up moves are made, every
//     pointer that started the previous line must be at its start + stride
//     if adv, else back at its start, within the wrap block, whether the
//     line finished or not (revision 3): a finished line's move uses the
//     stride and wrap of its last word, a catch-up move those of the new
//     line; a tile layer's pointer does not move;
//   - lines are made short on purpose: a layer whose groups stop being
//     taken (as when a scale made wider mid-line leaves groups owed), a
//     memory that stops answering for the rest of a line, and (DATWRITE)
//     dma_en cleared mid-line; and a pointer written just after line_go
//     cancels its catch-up move;
//   - a stride written mid-line applies at that line's end; ngroups and
//     act changed mid-line apply only from the next line;
//   - depth and hscale written mid-line reach gset with some group of the
//     line, old settings then new (revision 2), and the group's words are
//     laid out to the depth gset says it was fetched with.
// The pixel side is a stand-in that takes each group as soon as it is full
// (away from the line start), so every group of every line is fetched and
// the pointer rules apply.
module tb_model;
    parameter NL = 4;
    parameter PLANAR = 0;
    parameter TILES = 0;
    parameter LITTLE = 0;
    parameter DATWRITE = 0;
    localparam PW = 22, AW = 21;
    localparam LW = (NL > 1) ? $clog2(NL) : 1;
    localparam NP_M = (PLANAR != 0) ? (1 << (LW + 3)) : (1 << LW);   // the core's pointer count

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg               enable = 1'b1;
    reg               line_t = 1'b0;
    reg  [NL-1:0]     act = 0, adv = 0, planar = 0, tile = 0, take_t = 0;
    reg  [3*NL-1:0]   depth = 0;
    reg  [2*NL-1:0]   hscale = 0, mapw = 0;
    reg  [4*NL-1:0]   wrap = 0;
    reg  [16*NL-1:0]  stride = 0;
    reg  [12*NL-1:0]  ngroups = 0;
    reg  [10*NL-1:0]  ty = 0;
    reg  [7*NL-1:0]   tcol = 0;
    reg  [PW*NL-1:0]  mappt = 0, patpt = 0;
    reg  [LW+2:0]     ptr_sel = 0;
    reg               ptr_wr = 0;
    reg  [PW-1:0]     ptr_wdata = 0;
    wire [PW-1:0]     ptr_rdata;
    reg               ack = 0, rvalid = 0;
    reg  [15:0]       rdata = 0;
    wire              line_go, line_gen, req, urgent;
    wire [AW-1:0]     addr;
    wire [128*NL-1:0] dat;
    wire [10*NL-1:0]  attr;
    wire [NL-1:0]     fill_t;
    wire [6*NL-1:0]   gset;
    wire [15:0]       dat_rdata;

    reg  [8*NL-1:0]   dma_en = {8*NL{1'b1}};
    layer_fetch #(.NL(NL), .AW(AW), .PW(PW), .PLANAR(PLANAR), .TILES(TILES), .DATWRITE(DATWRITE), .LITTLE(LITTLE)) dut (
        .clk(clk), .rst(rst), .enable(enable), .line_t(line_t), .line_go(line_go), .line_gen(line_gen),
        .act(act), .adv(adv), .depth(depth), .planar(planar), .hscale(hscale), .wrap(wrap), .stride(stride),
        .ngroups(ngroups), .tile(tile), .mapw(mapw), .ty(ty), .tcol(tcol), .mappt(mappt), .patpt(patpt),
        .ptr_sel(ptr_sel), .ptr_wr(ptr_wr), .ptr_wdata(ptr_wdata), .ptr_rdata(ptr_rdata),
        .dat_wr(1'b0), .dat_sel({(LW+3){1'b0}}), .dat_wdata(16'd0), .dat_be(2'd0), .dma_en(dma_en),
        .dat_rdata(dat_rdata), .dat(dat), .attr(attr), .gset(gset), .fill_t(fill_t), .take_t(take_t),
        .req(req), .urgent(urgent), .addr(addr), .ack(ack), .rvalid(rvalid), .rdata(rdata));

    // ---------------------------------------------------------------- memory
    function [15:0] hash(input [20:0] a);
        hash = {a[20:13] ^ a[7:0] ^ 8'h5A, a[12:5] ^ {a[4:0], a[20:18]} ^ 8'hC3} ^ {a[2:0], a[15:3]};
    endfunction
    function [15:0] word_at(input [PW-1:0] ba);                 // the word a byte address falls in, as stored
        reg [15:0] w;
        begin
            w = hash(ba[21:1]);
            word_at = (LITTLE != 0) ? {w[7:0], w[15:8]} : w;
        end
    endfunction
    function [15:0] entry_at(input [PW-1:0] ba);                // a map entry: the word as read
        entry_at = hash(ba[21:1]);
    endfunction
    reg        sn = 0, starve = 0;
    reg [2:0]  rv_pipe = 0;
    reg [20:0] a_pipe [0:2];
    always @(posedge clk) begin
        sn <= ~sn;
        ack <= sn && req && ({$random} % 4 != 0) && !starve;
        rv_pipe <= {rv_pipe[1:0], ack};
        a_pipe[0] <= addr;  a_pipe[1] <= a_pipe[0];  a_pipe[2] <= a_pipe[1];
        rvalid <= rv_pipe[2];
        rdata  <= hash(a_pipe[2]);
    end

    // ---------------------------------------------------------------- the model
    reg [PW-1:0] m_pt   [0:8*NL-1];      // the pointers as software sees them, at the line's start
    reg [PW-1:0] m_run  [0:8*NL-1];      // walking through the current line
    reg [11:0]   m_ngr  [0:NL-1];        // the line's settings, as copied at its start
    reg          m_act  [0:NL-1], m_adv [0:NL-1], m_tile [0:NL-1], m_planar [0:NL-1];
    reg [2:0]    m_depth [0:NL-1];       // the depth the line started with, then the last group's
    reg [2:0]    m_dep0 [0:NL-1], m_dep2 [0:NL-1];   // the line's first settings and the mid-line ones
    reg [1:0]    m_hs0  [0:NL-1], m_hs2  [0:NL-1];
    reg          m_new  [0:NL-1];        // a group with the mid-line settings has filled
    reg [1:0]    m_mw   [0:NL-1];
    reg [6:0]    m_row  [0:NL-1], m_col [0:NL-1];
    reg [2:0]    m_trow [0:NL-1];
    reg [PW-1:0] m_map  [0:NL-1], m_pat [0:NL-1];
    reg [11:0]   m_grp  [0:NL-1];        // groups filled so far this line
    // The line end's pointer check, made once the core's catch-up is done
    reg [PW-1:0] e_start [0:8*NL-1];     // each pointer's start on the line that ended
    reg [PW-1:0] e_fin   [0:8*NL-1];     // ... where its own last word would have put it
    reg [PW-1:0] e_fin2  [0:8*NL-1];     // ... the same with the stride and wrap at line_go: the last
                                         // word set up after the toggle, which already sets them for the next line
    integer      smode = 0;              // the line's way of ending short: 0 none, 1 stop taking, 2 starve, 3 dma_en
    reg          e_chk   [0:8*NL-1];     // ... checked (a pointer the line used)
    reg [1:0]    e_how   [0:8*NL-1];     // 0: finished, 1: started, maybe not finished, 2: maybe not started
    reg          e_adv   [0:NL-1];       // the ended line's adv
    reg          e_pend = 0, e_seen = 0;
    reg [NP_M-1:0] e_owe;                // the core's owed pointers at line_go
    reg          cx_v = 0;               // a pointer written just after line_go, cancelling its move
    reg [15:0]   e_cstr [0:NP_M-1];      // the stride in the clock each catch-up move is made
    integer      cx_m;
    reg [PW-1:0] cx_val;
    integer      stop_l = -1;            // a layer whose groups stop being taken this line
    reg [NL-1:0] nochk = 0;              // layers whose data aren't checked for the rest of the line
    reg [15:0]   m_ent0 [0:NL-1], m_ent1 [0:NL-1];   // the entries the next group uses
    integer      n, w, c, j, t;

    function [PW-1:0] wrapadd(input [PW-1:0] p, input [PW-1:0] d, input [3:0] wr);
        reg [PW-1:0] m;
        begin
            m = (wr == 4'd0) ? {PW{1'b1}} : ~({PW{1'b1}} << ({1'b0, wr} + 5'd9));
            wrapadd = (p & ~m) | ((p + d) & m);
        end
    endfunction
    function [1:0] lb_of(input [2:0] d);
        lb_of = d[2] ? 2'd3 : d[1] ? 2'd2 : d[0] ? 2'd1 : 2'd0;
    endfunction
    function [15:0] pixrev(input [15:0] v, input [1:0] lb);
        integer b;
        begin
            pixrev = 16'd0;
            case (lb)
                2'd1:    for (b = 0; b < 8; b = b + 1) pixrev[2*b +: 2] = v[2*(7-b) +: 2];
                2'd2:    for (b = 0; b < 4; b = b + 1) pixrev[4*b +: 4] = v[4*(3-b) +: 4];
                default: pixrev = {v[7:0], v[15:8]};
            endcase
        end
    endfunction
    function [7:0] rev8(input [7:0] v);
        integer b;
        for (b = 0; b < 8; b = b + 1) rev8[b] = v[7-b];
    endfunction
    function [6:0] colmask(input [1:0] mw);
        colmask = (mw == 2'd0) ? 7'h1F : (mw == 2'd1) ? 7'h3F : 7'h7F;
    endfunction
    function [PW-1:0] entaddr(input integer l, input [6:0] col);
        reg [3:0] sh;
        begin
            sh = 4'd6 + ((m_mw[l] == 2'd3) ? 4'd2 : {2'd0, m_mw[l]});
            entaddr = m_map[l] + ({{(PW-7){1'b0}}, m_row[l]} << sh) + {{(PW-8){1'b0}}, col, 1'b0};
        end
    endfunction
    function [PW-1:0] rowaddr(input integer l, input [15:0] e);        // a column's pattern row
        reg [2:0] tr;
        reg [1:0] lb;
        begin
            lb = lb_of(m_depth[l]);
            tr = e[14] ? ~m_trow[l] : m_trow[l];
            rowaddr = m_pat[l] + ({{(PW-9){1'b0}}, e[8:0]} << (3'd3 + {1'b0, lb})) + ({{(PW-3){1'b0}}, tr} << lb);
        end
    endfunction
    task read_entries(input integer l);                         // the next group's two entries
        begin
            m_ent0[l] = entry_at(entaddr(l, m_col[l]));
            m_col[l]  = (m_col[l] + 1) & colmask(m_mw[l]);
            m_ent1[l] = entry_at(entaddr(l, m_col[l]));
            m_col[l]  = (m_col[l] + 1) & colmask(m_mw[l]);
        end
    endtask

    // Expected data registers of layer l's next group, from the model's
    // running pointers (which it moves on), or from the tile entries
    reg [127:0] exp_dat;
    reg [7:0]   exp_used;                // the data registers the group fills; the others keep their old value
    reg [9:0]   exp_attr;
    task expect_group(input integer l);
        reg [15:0] e, wv;
        reg [7:0]  bv;
        reg [PW-1:0] ra;
        reg [2:0] kc, base;
        reg [1:0] lb;
        begin
            exp_dat  = 128'd0;
            exp_used = 8'd0;
            exp_attr = 10'd0;
            if ((TILES != 0) && m_tile[l]) begin
                lb = lb_of(m_depth[l]);
                kc = (lb == 2'd0) ? 3'd1 : 3'd1 << (lb - 1'b1);
                for (c = 0; c < 2; c = c + 1) begin
                    e    = (c == 0) ? m_ent0[l] : m_ent1[l];
                    ra   = rowaddr(l, e);
                    base = (c == 0) ? kc : 3'd0;
                    exp_used = (lb == 2'd0) ? 8'h01 : (8'hFF >> (4'd8 - 2*kc));
                    if (lb == 2'd0) begin
                        wv = hash(ra[21:1]);                                    // the byte the address names
                        bv = ra[0] ? ((LITTLE != 0) ? wv[15:8] : wv[7:0]) : ((LITTLE != 0) ? wv[7:0] : wv[15:8]);
                        if (e[13]) bv = rev8(bv);
                        if (c == 0) exp_dat[15:8] = bv; else exp_dat[7:0] = bv;
                    end else
                        for (j = 0; j < kc; j = j + 1) begin
                            wv = word_at(ra + 2*j);
                            if (e[13]) exp_dat[16*(base + j) +: 16] = pixrev(wv, lb);
                            else       exp_dat[16*(base + kc - 1 - j) +: 16] = wv;
                        end
                end
                exp_attr = {m_ent1[l][15], m_ent1[l][12:9], m_ent0[l][15], m_ent0[l][12:9]};
                if (m_grp[l] + 1 < m_ngr[l]) read_entries(l);      // none after the last group
            end else if ((PLANAR != 0) && m_planar[l]) begin
                exp_used = 8'hFF >> (3'd7 - m_depth[l]);
                for (w = 0; w <= m_depth[l]; w = w + 1) begin
                    exp_dat[16*w +: 16] = word_at(m_run[8*l + w]);
                    m_run[8*l + w] = wrapadd(m_run[8*l + w], 22'd2, wrap[4*l +: 4]);
                end
            end else begin
                exp_used = 8'hFF >> (3'd7 - m_depth[l]);
                for (w = m_depth[l]; w >= 0; w = w - 1) begin                 // the high register first
                    exp_dat[16*w +: 16] = word_at(m_run[8*l]);
                    m_run[8*l] = wrapadd(m_run[8*l], 22'd2, wrap[4*l +: 4]);
                end
            end
            m_grp[l] = m_grp[l] + 1;
        end
    endtask

    // ---------------------------------------------------------------- stimulus
    integer   cyc = 0, line = 0, lines_left = 0, line_len = 0, ptr_ld = 0, p;
    integer   errors = 0, n_groups = 0, n_tiles = 0, n_ptr_checks = 0, n_stride_mid = 0, n_unfinished = 0;
    integer   n_caught = 0, n_cancel = 0, n_stop = 0, n_starve = 0, n_enclr = 0, q;
    integer   n_set_mid = 0, n_set_new = 0, set_at = 0, set_layer = 0;
    reg       first_line = 1;
    reg [31:0] r;
    task fail(input [8*12-1:0] what, input integer l, input [127:0] got, input [127:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10) $display("ERROR @%0d line %0d layer %0d: %0s: got %h, expected %h", cyc, line, l, what, got, want);
        end
    endtask

    always @(posedge clk) begin
        cyc <= cyc + 1;
        ptr_wr <= 1'b0;
        if (!rst && ptr_ld == 0) begin
            // The line end's pointer check, once line_go is seen and the
            // core's catch-up moves are made
            if (e_pend && dut.line_go) begin
                e_seen = 1'b1;  e_owe = dut.owe;
                for (n = 0; n < NL; n = n + 1)
                    for (w = 0; w < 8; w = w + 1)
                        e_fin2[8*n + w] = wrapadd(e_start[8*n + w],
                                                  e_adv[n] ? {{(PW-16){stride[16*n + 15]}}, stride[16*n + 15 -: 15], 1'b0} : {PW{1'b0}},
                                                  wrap[4*n +: 4]);
                // Now and then a pointer written just after line_go: its
                // catch-up move is cancelled and the written value stands
                if (dut.owe != 0 && {$random} % 3 == 0) begin
                    for (q = NP_M - 1; q >= 0; q = q - 1) if (dut.owe[q]) cx_m = q;
                    cx_val    = {$random} & {{(PW-1){1'b1}}, 1'b0};
                    ptr_wr   <= 1'b1;
                    ptr_sel  <= (PLANAR != 0) ? cx_m : cx_m << 3;
                    ptr_wdata <= cx_val;
                    cx_m = (PLANAR != 0) ? cx_m : 8*cx_m;
                    cx_v = 1'b1;
                end
            end else if (e_pend && e_seen && dut.c_v && !ptr_wr) begin
                // A catch-up move is made in this clock: with the stride of now
                e_cstr[dut.c_q] = stride[16*((PLANAR != 0) ? dut.c_q / 8 : dut.c_q) +: 16];
            end else if (e_pend && e_seen && !dut.cu_busy) begin
                e_pend = 1'b0;
                for (n = 0; n < NL; n = n + 1)
                    for (w = 0; w < 8; w = w + 1) if (e_chk[8*n + w]) begin
                        q = (PLANAR != 0) ? 8*n + w : n;
                        if (cx_v && cx_m == 8*n + w) begin
                            m_pt[8*n + w] = cx_val;  n_cancel = n_cancel + 1;
                        end else if (e_owe[q]) begin
                            // A catch-up move: the stride of the clock it was made in, the new line's wrap
                            if (e_how[8*n + w] == 2'd0 || e_how[8*n + w] == 2'd3)
                                fail("owed, finished", n, {{(128-NP_M){1'b0}}, e_owe}, {126'd0, e_how[8*n + w]});
                            m_pt[8*n + w] = wrapadd(e_start[8*n + w],
                                                    e_adv[n] ? {{(PW-16){e_cstr[q][15]}}, e_cstr[q][15:1], 1'b0} : {PW{1'b0}},
                                                    wrap[4*n +: 4]);
                            n_caught = n_caught + 1;
                        end else case (e_how[8*n + w])
                            // Not owed: its last word was set up, before the
                            // toggle (all groups taken), or maybe after it
                            2'd0:    m_pt[8*n + w] = e_fin[8*n + w];
                            2'd1:    m_pt[8*n + w] = (dut.pt[q] == e_fin2[8*n + w]) ? e_fin2[8*n + w] : e_fin[8*n + w];
                            2'd2:    m_pt[8*n + w] = (dut.pt[q] == e_fin[8*n + w])  ? e_fin[8*n + w]
                                                   : (dut.pt[q] == e_fin2[8*n + w]) ? e_fin2[8*n + w] : e_start[8*n + w];
                            default: m_pt[8*n + w] = e_start[8*n + w];        // not used: no move
                        endcase
                        if (dut.pt[q] !== m_pt[8*n + w]) fail("pointer", n, dut.pt[q], m_pt[8*n + w]);
                        m_run[8*n + w] = m_pt[8*n + w];
                        n_ptr_checks = n_ptr_checks + 1;
                    end
            end
        end
        if (!rst) begin
            if (ptr_ld != 0) begin
                // Load every pointer the build has, in both the core and the model
                ptr_ld <= ptr_ld - 1;
                if (ptr_ld[0]) begin
                    p = (ptr_ld - 1) / 2;
                    ptr_wr    <= 1'b1;
                    ptr_sel   <= (PLANAR != 0) ? p : p << 3;
                    ptr_wdata <= (p * 22'h4C8C + 22'h2000) & 22'h3FFFFE;
                    m_pt[(PLANAR != 0) ? p : 8*p] = (p * 22'h4C8C + 22'h2000) & 22'h3FFFFE;
                end
            end else if (lines_left == 0) begin
                // The line ends: what each pointer the line used should come
                // to, checked once the core's catch-up is done (below)
                for (q = 0; q < 8*NL; q = q + 1) e_chk[q] = 1'b0;
                if (!first_line)
                    for (n = 0; n < NL; n = n + 1) begin
                        e_adv[n] = m_adv[n];
                        if (m_grp[n] < m_ngr[n] && m_act[n] && !m_tile[n]) n_unfinished = n_unfinished + 1;
                        for (w = 0; w < ((PLANAR != 0) && m_planar[n] ? m_depth[n] + 1 : 1); w = w + 1) begin
                            e_chk[8*n + w]   = 1'b1;
                            e_start[8*n + w] = m_pt[8*n + w];
                            e_fin[8*n + w]   = wrapadd(m_pt[8*n + w],
                                                       m_adv[n] ? {{(PW-16){stride[16*n + 15]}}, stride[16*n + 15 -: 15], 1'b0} : {PW{1'b0}},
                                                       wrap[4*n +: 4]);
                            e_how[8*n + w]   = !(enable && m_act[n] && m_ngr[n] != 0 && !m_tile[n]) ? 2'd3
                                             : (m_grp[n] == m_ngr[n] && !nochk[n]) ? 2'd0 : (m_grp[n] != 0) ? 2'd1 : 2'd2;
                        end
                    end
                e_pend = !first_line;  e_seen = 1'b0;  cx_v = 1'b0;
                first_line <= 1'b0;
                starve <= 1'b0;  nochk <= {NL{1'b0}};  dma_en <= {8*NL{1'b1}};
                // The next line's settings, in place before its line_go
                line_t <= ~line_t;
                line_len = 800 + ({$random} % 400);
                lines_left <= line_len;
                line <= line + 1;
                for (n = 0; n < NL; n = n + 1) begin
                    m_act[n]    = ({$random} % 4 != 0);               act[n] <= m_act[n];
                    m_adv[n]    = {$random} % 2;                     adv[n] <= m_adv[n];
                    m_tile[n]   = (TILES != 0) && ({$random} % 2);   tile[n] <= m_tile[n];
                    m_planar[n] = (PLANAR != 0) && ({$random} % 2);  planar[n] <= m_planar[n];
                    r = $random;
                    m_depth[n]  = m_planar[n] ? r[2:0] : (r[1:0] == 2'd0 ? 3'd0 : r[1:0] == 2'd1 ? 3'd1 : r[1:0] == 2'd2 ? 3'd3 : 3'd7);
                    depth[3*n +: 3] <= m_depth[n];
                    m_dep0[n] = m_depth[n];  m_dep2[n] = m_depth[n];
                    m_hs0[n]  = {$random} % 4;  m_hs2[n] = m_hs0[n];  hscale[2*n +: 2] <= m_hs0[n];
                    m_new[n]  = 1'b0;
                    m_ngr[n]    = 1 + ({$random} % 4);                ngroups[12*n +: 12] <= m_ngr[n];
                    wrap[4*n +: 4]   <= ({$random} % 2) ? 4'd0 : 4'd1 + ({$random} % 4);
                    stride[16*n +: 16] <= $random;
                    m_mw[n]     = {$random} % 4;                     mapw[2*n +: 2] <= m_mw[n];
                    m_row[n]    = $random;  m_trow[n] = $random;     ty[10*n +: 10] <= {m_row[n], m_trow[n]};
                    m_col[n]    = $random;                           tcol[7*n +: 7] <= m_col[n];
                    m_map[n]    = {$random} & 22'h3FFFFE;            mappt[PW*n +: PW] <= m_map[n];
                    m_pat[n]    = {$random} & 22'h3FFFFE;            patpt[PW*n +: PW] <= m_pat[n];
                    m_grp[n]    = 0;
                    for (w = 0; w < 8; w = w + 1) m_run[8*n + w] = m_pt[8*n + w];
                    if (m_tile[n]) read_entries(n);                  // the first group's entries, read ahead
                end
                set_at    = 12 + ({$random} % 160);                  // a depth and scale change, early in the line
                set_layer = {$random} % NL;
                // This line's way of ending short, if any: a layer whose
                // groups stop being taken (not the one whose settings change),
                // a memory that stops answering, dma_en cleared
                case ({$random} % 8)
                    4, 5:    smode = 1;
                    6:       smode = 2;
                    7:       smode = (DATWRITE != 0) ? 3 : 1;
                    default: smode = 0;
                endcase
                stop_l = (smode == 1) ? ((NL > 1) ? (set_layer + 1 + {$random} % (NL - 1)) % NL : 0) : -1;
                if (smode == 1) n_stop = n_stop + 1;
            end else begin
                lines_left <= lines_left - 1;
                // Just after the line start: a new stride for a layer whose
                // last word is still to come, so it applies at this line's
                // end. Later: ngroups and act changes that must not touch
                // this line.
                if (lines_left == line_len - 5) begin          // 3 clocks after line_go: a layer with words still to ask for
                    n = {$random} % NL;
                    // (planar: every plane's last word is in the last group, so that must not be the first)
                    if (!m_tile[n] && (m_planar[n] ? (m_ngr[n] >= 2 && m_depth[n] >= 2) : (m_depth[n] + 1) * m_ngr[n] >= 6)) begin
                        stride[16*n +: 16] <= $random;  n_stride_mid = n_stride_mid + 1;
                    end
                end
                if (lines_left == line_len - set_at && !m_planar[set_layer]) begin
                    // New depth (chunky, or a tile layer's) and scale for one
                    // layer: the groups still to start fetch with them
                    n = set_layer;  r = $random;
                    m_dep2[n] = (r[1:0] == 2'd0 ? 3'd0 : r[1:0] == 2'd1 ? 3'd1 : r[1:0] == 2'd2 ? 3'd3 : 3'd7);
                    m_hs2[n]  = r[3:2];
                    depth[3*n +: 3] <= m_dep2[n];  hscale[2*n +: 2] <= m_hs2[n];
                    n_set_mid = n_set_mid + 1;
                end
                if (lines_left == line_len - 30 && smode == 2) begin                   // the memory stops answering
                    starve <= 1'b1;  n_starve = n_starve + 1;
                end
                if (lines_left == line_len - 60 && smode == 3) begin
                    // dma_en cleared mid-line, for a layer that has started:
                    // one plane of a planar layer, else the whole layer
                    n = {$random} % NL;
                    if (m_grp[n] != 0 && m_grp[n] < m_ngr[n] && !m_tile[n]) begin
                        if (m_planar[n]) dma_en[8*n + ({$random} % (m_depth[n] + 1))] <= 1'b0;
                        else             dma_en[8*n +: 8] <= 8'h00;
                        nochk[n] <= 1'b1;  n_enclr = n_enclr + 1;
                    end
                end
                if (lines_left == 250) begin
                    n = {$random} % NL;  ngroups[12*n +: 12] <= 12'd40;  act[n] <= ~act[n];
                end
            end
        end
    end

    // The pixel side: take each group as soon as it is full, but not around
    // the line start, where the fetch empties the handshake; check it
    always @(posedge clk) if (!rst && ptr_ld == 0 && lines_left > 8 && lines_left < line_len - 8)
        for (t = 0; t < NL; t = t + 1)
            if (fill_t[t] != take_t[t] && !(t == stop_l && m_grp[t] != 0)) begin
                take_t[t] <= ~take_t[t];
                if (nochk[t]) m_grp[t] = m_grp[t] + 1;        // dma_en cleared: not checked
                else if (m_grp[t] < m_ngr[t] && m_act[t]) begin
                    // The group's settings: the line's, or the mid-line ones
                    // from some group on, and the planar flag as set
                    if (gset[6*t] !== ((PLANAR != 0) && m_planar[t])) fail("gset planar", t, {127'd0, gset[6*t]}, {127'd0, m_planar[t]});
                    if (!m_new[t] && gset[6*t + 1 +: 5] == {m_hs0[t], m_dep0[t]}) m_depth[t] = m_dep0[t];
                    else if (gset[6*t + 1 +: 5] == {m_hs2[t], m_dep2[t]}) begin
                        if (!m_new[t] && {m_hs2[t], m_dep2[t]} != {m_hs0[t], m_dep0[t]}) n_set_new = n_set_new + 1;
                        m_new[t] = 1'b1;  m_depth[t] = m_dep2[t];
                    end else fail("gset", t, {122'd0, gset[6*t +: 6]}, {122'd0, m_hs2[t], m_dep2[t], 1'b0});
                    expect_group(t);
                    n_groups = n_groups + 1;
                    if (m_tile[t]) n_tiles = n_tiles + 1;
                    for (j = 0; j < 8; j = j + 1) if (!exp_used[j]) exp_dat[16*j +: 16] = dat[128*t + 16*j +: 16];
                    if (dat[128*t +: 128] !== exp_dat) fail("group", t, dat[128*t +: 128], exp_dat);
                    if (m_tile[t] && attr[10*t +: 10] !== exp_attr) fail("attr", t, {118'd0, attr[10*t +: 10]}, {118'd0, exp_attr});
                end else fail("extra group", t, 128'd0, 128'd0);
            end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        ptr_ld = (PLANAR != 0) ? 16 * NL : 2 * NL;
        repeat (300000) @(posedge clk);
        @(negedge clk);
        $display("NL=%0d PLANAR=%0d TILES=%0d LITTLE=%0d DATWRITE=%0d: %0d lines, %0d groups checked (%0d tile), %0d pointer checks, %0d mid-line strides, %0d mid-line settings (%0d reached a group)",
                 NL, PLANAR, TILES, LITTLE, DATWRITE, line, n_groups, n_tiles, n_ptr_checks, n_stride_mid, n_set_mid, n_set_new);
        $display("  short lines: %0d layer-lines unfinished (%0d stopped taking, %0d starved, %0d dma_en cleared), %0d catch-up moves checked, %0d cancelled by a write",
                 n_unfinished, n_stop, n_starve, n_enclr, n_caught, n_cancel);
        if (n_groups < 200 || n_ptr_checks < 50 || ((TILES != 0) && n_tiles == 0) || n_set_new < 10
            || n_caught < 10 || n_cancel < 3 || ((DATWRITE != 0) && n_enclr < 5)) begin
            errors = errors + 1;
            $display("ERROR: a case never came up, or too many lines ran out");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
