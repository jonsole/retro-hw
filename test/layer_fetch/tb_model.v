`timescale 1ns/1ps
// layer_fetch against a model of what should reach the data registers and
// where the pointers should end up, for builds the machines don't have:
// set with -P (the Makefile runs several). Memory is a hash of the word
// address, so every expected word can be worked out from the pointer
// rules alone (spec 4.2, 4.3, 4.5):
//   - each group that fills (fill_t toggles) must hold the words of the
//     model's pointers, laid into the data registers as the spec says, and
//     for a tile layer the rows the map entries pick (and attr);
//   - at each line start, every pointer must be where the previous line's
//     last word left it: start + stride if adv, else back to the start,
//     within the wrap block; a tile layer's does not move;
//   - a stride written mid-line applies at that line's end; ngroups and
//     act changed mid-line apply only from the next line.
// The pixel side is a stand-in that takes each group as soon as it is full
// (away from the line start), so every group of every line is fetched and
// the pointer rules apply.
module tb_model;
    parameter NL = 4;
    parameter PLANAR = 0;
    parameter TILES = 0;
    parameter LITTLE = 0;
    localparam PW = 22, AW = 21;
    localparam LW = (NL > 1) ? $clog2(NL) : 1;

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
    wire [15:0]       dat_rdata;

    layer_fetch #(.NL(NL), .AW(AW), .PW(PW), .PLANAR(PLANAR), .TILES(TILES), .DATWRITE(0), .LITTLE(LITTLE)) dut (
        .clk(clk), .rst(rst), .enable(enable), .line_t(line_t), .line_go(line_go), .line_gen(line_gen),
        .act(act), .adv(adv), .depth(depth), .planar(planar), .hscale(hscale), .wrap(wrap), .stride(stride),
        .ngroups(ngroups), .tile(tile), .mapw(mapw), .ty(ty), .tcol(tcol), .mappt(mappt), .patpt(patpt),
        .ptr_sel(ptr_sel), .ptr_wr(ptr_wr), .ptr_wdata(ptr_wdata), .ptr_rdata(ptr_rdata),
        .dat_wr(1'b0), .dat_sel({(LW+3){1'b0}}), .dat_wdata(16'd0), .dat_be(2'd0), .dma_en({8*NL{1'b1}}),
        .dat_rdata(dat_rdata), .dat(dat), .attr(attr), .fill_t(fill_t), .take_t(take_t),
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
    reg        sn = 0;
    reg [2:0]  rv_pipe = 0;
    reg [20:0] a_pipe [0:2];
    always @(posedge clk) begin
        sn <= ~sn;
        ack <= sn && req && ({$random} % 4 != 0);
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
    reg [2:0]    m_depth [0:NL-1];
    reg [1:0]    m_mw   [0:NL-1];
    reg [6:0]    m_row  [0:NL-1], m_col [0:NL-1];
    reg [2:0]    m_trow [0:NL-1];
    reg [PW-1:0] m_map  [0:NL-1], m_pat [0:NL-1];
    reg [11:0]   m_grp  [0:NL-1];        // groups filled so far this line
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
                // The line ends: every pointer must be where the model says
                if (!first_line)
                    for (n = 0; n < NL; n = n + 1)
                        for (w = 0; w < ((PLANAR != 0) && m_planar[n] ? m_depth[n] + 1 : 1); w = w + 1) begin
                            if (enable && m_act[n] && m_ngr[n] != 0 && !m_tile[n]) begin
                                if (m_grp[n] == m_ngr[n])
                                    m_pt[8*n + w] = wrapadd(m_pt[8*n + w],
                                                            m_adv[n] ? {{(PW-16){stride[16*n + 15]}}, stride[16*n + 15 -: 15], 1'b0} : {PW{1'b0}},
                                                            wrap[4*n +: 4]);
                                else begin                      // the line ran out before its last word: not checked
                                    m_pt[8*n + w] = dut.pt[(PLANAR != 0) ? 8*n + w : n];
                                    n_unfinished = n_unfinished + 1;
                                end
                            end
                            if (dut.pt[(PLANAR != 0) ? 8*n + w : n] !== m_pt[8*n + w])
                                fail("pointer", n, dut.pt[(PLANAR != 0) ? 8*n + w : n], m_pt[8*n + w]);
                            n_ptr_checks = n_ptr_checks + 1;
                        end
                first_line <= 1'b0;
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
                    m_ngr[n]    = 1 + ({$random} % 4);                ngroups[12*n +: 12] <= m_ngr[n];
                    hscale[2*n +: 2] <= {$random} % 4;
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
            if (fill_t[t] != take_t[t]) begin
                take_t[t] <= ~take_t[t];
                if (m_grp[t] < m_ngr[t] && m_act[t]) begin
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
        repeat (150000) @(posedge clk);
        @(negedge clk);
        $display("NL=%0d PLANAR=%0d TILES=%0d LITTLE=%0d: %0d lines, %0d groups checked (%0d tile), %0d pointer checks (%0d unfinished lines), %0d mid-line strides",
                 NL, PLANAR, TILES, LITTLE, line, n_groups, n_tiles, n_ptr_checks, n_unfinished, n_stride_mid);
        if (n_groups < 200 || n_ptr_checks < 50 || ((TILES != 0) && n_tiles == 0) || n_unfinished > n_ptr_checks / 20) begin
            errors = errors + 1;
            $display("ERROR: a case never came up, or too many lines ran out");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
