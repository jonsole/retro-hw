`timescale 1ns/1ps
// sprite_fetch in lockstep with a frozen copy of its earlier self
// (ref/sprite_fetch_ref.v), on the same random settings, starts, line-start
// writes, hand-fed words, beam, pixel side and memory. Every clock the two
// must agree on every output. The two allowed differences are the change
// itself: the core has no mem_deadline, and its mem_urgent is a register,
// checked here against the reference's compare with the deadline of the
// clock before (spec 4.6); and its set_sel runs one sprite ahead, as it
// registers the settings (so this bench never writes a sprite's settings
// in its hand-over clock). The build (-P) follows a machine's: retro68k's
// by default, retro-z80's with NS 4, PW 22, LITTLE, URGENT 6, no MANUAL.
//
// The test bench stands in for the machine: a register file of sprite
// settings handed over by set_sel, and the pixel side (read pointers that
// consume words, flush acknowledges, collision lines).
module tb_lock_sprite;
    parameter NS = 8;
    parameter PW = 23;
    parameter LITTLE = 0;
    parameter URGENT = 5;
    parameter MANUAL = 1;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // The register file: each sprite's settings
    reg  [10:0] s_hstart [0:7], s_hstop [0:7], s_vstart [0:7], s_vstop [0:7];
    reg  [1:0]  s_bpp [0:7], s_depth [0:7];
    reg  [3:0]  s_pal [0:7];
    reg  [15:0] s_xstep [0:7], s_ystep [0:7];
    // ... read for the sprite each core names (the core runs one ahead)
    wire [2:0]  r_set_sel, c_set_sel;
    wire [10:0] set_hstart = s_hstart[r_set_sel], set_hstop = s_hstop[r_set_sel];
    wire [10:0] set_vstart = s_vstart[r_set_sel], set_vstop = s_vstop[r_set_sel];
    wire [1:0]  set_bpp = s_bpp[r_set_sel], set_depth = s_depth[r_set_sel];
    wire [3:0]  set_pal = s_pal[r_set_sel];
    wire [15:0] set_xstep = s_xstep[r_set_sel], set_ystep = s_ystep[r_set_sel];
    wire [10:0] cset_hstart = s_hstart[c_set_sel], cset_hstop = s_hstop[c_set_sel];
    wire [10:0] cset_vstart = s_vstart[c_set_sel], cset_vstop = s_vstop[c_set_sel];
    wire [1:0]  cset_bpp = s_bpp[c_set_sel], cset_depth = s_depth[c_set_sel];
    wire [3:0]  cset_pal = s_pal[c_set_sel];
    wire [15:0] cset_xstep = s_xstep[c_set_sel], cset_ystep = s_ystep[c_set_sel];

    reg          dma_on = 1'b1;
    reg  [7:0]   dma_mask = 8'hFF, start = 8'd0, coll_t_in = 1'b0, flush_ack_t = 8'd0;
    reg  [2:0]   sel = 3'd0;
    reg          lst_wr = 1'b0, dat_wr = 1'b0, vblank = 1'b0, coll_t = 1'b0;
    reg  [PW-1:0] lst_new = 0;
    reg  [15:0]  dat = 16'd0;
    reg  [10:0]  beam_v = 11'd1, beam_h = 11'd0;
    reg  [39:0]  fifo_ra = 40'd0;
    reg  [47:0]  rp_g = 48'd0, rp_b = 48'd0;     // to the reference (Gray, a clock later), to the core (binary)
    reg  [31:0]  coll_line = 32'd0, coll_clr = 32'd0;
    reg          ack = 1'b0, rvalid = 1'b0;
    reg  [15:0]  rdata = 16'd0;

    wire [PW-1:0] r_lst, c_lst;
    wire [5:0]    r_cnt, c_cnt;
    wire          r_req, c_req, r_urg, c_urg;
    wire [21:1]   r_addr;
    wire [20:0]   c_addr;
    wire [9:0]    r_dl;
    wire [79:0]   r_hs, c_hs, r_xe, c_xe;
    wire [7:0]    r_act, c_act, r_dma, c_dma, r_flush, c_flush;
    wire [15:0]   r_lb, c_lb, r_depth, c_depth;
    wire [127:0]  r_xstep, c_xstep, r_rd, c_rd;
    wire [31:0]   r_pal, c_pal, r_coll, c_coll;
    wire [47:0]   r_wp, c_wp;

    sprite_fetch_ref #(.NS(NS), .PW(PW), .SWAP_BYTES(LITTLE), .URGENT(URGENT), .MANUAL(MANUAL)) ref (
        .clk(clk), .rst(rst), .set_sel(r_set_sel),
        .set_hstart(set_hstart), .set_hstop(set_hstop), .set_vstart(set_vstart), .set_vstop(set_vstop),
        .set_bpp(set_bpp), .set_depth(set_depth), .set_pal(set_pal), .set_xstep(set_xstep), .set_ystep(set_ystep),
        .dma_on(dma_on), .dma_mask(dma_mask), .start(start), .sel(sel), .lst_cur(r_lst), .lst_wr(lst_wr), .lst_new(lst_new),
        .fifo_count(r_cnt), .dat_wr(dat_wr), .dat(dat), .vblank(vblank), .beam_v(beam_v), .beam_h(beam_h),
        .mem_req(r_req), .mem_addr(r_addr), .mem_deadline(r_dl), .mem_urgent(r_urg),
        .mem_ack(ack), .mem_rvalid(rvalid), .mem_rdata(rdata),
        .p_hs(r_hs), .p_xe(r_xe), .p_act(r_act), .p_lb(r_lb), .p_xstep(r_xstep), .p_depth(r_depth), .p_pal(r_pal), .p_dma(r_dma),
        .fifo_ra(fifo_ra), .fifo_rd(r_rd), .wp_g(r_wp), .rp_g(rp_g), .flush_t(r_flush), .flush_ack_t(flush_ack_t),
        .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clr), .coll(r_coll));

    sprite_fetch #(.NS(NS), .PW(PW), .AW(21), .LITTLE(LITTLE), .URGENT(URGENT), .MANUAL(MANUAL)) dut (
        .clk(clk), .rst(rst), .set_sel(c_set_sel),
        .set_hstart(cset_hstart), .set_hstop(cset_hstop), .set_vstart(cset_vstart), .set_vstop(cset_vstop),
        .set_bpp(cset_bpp), .set_depth(cset_depth), .set_pal(cset_pal), .set_xstep(cset_xstep), .set_ystep(cset_ystep),
        .dma_on(dma_on), .dma_mask(dma_mask), .start(start), .sel(sel), .lst_cur(c_lst), .lst_wr(lst_wr), .lst_new(lst_new),
        .fifo_count(c_cnt), .dat_wr(dat_wr), .dat(dat), .vblank(vblank), .beam_v(beam_v), .beam_h(beam_h),
        .mem_req(c_req), .mem_addr(c_addr), .mem_urgent(c_urg),
        .mem_ack(ack), .mem_rvalid(rvalid), .mem_rdata(rdata),
        .p_hs(c_hs), .p_xe(c_xe), .p_act(c_act), .p_lb(c_lb), .p_xstep(c_xstep), .p_depth(c_depth), .p_pal(c_pal), .p_dma(c_dma),
        .fifo_ra(fifo_ra), .fifo_rd(c_rd), .wp_g(c_wp), .rp(rp_b), .flush_t(c_flush), .flush_ack_t(flush_ack_t),
        .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clr), .coll(c_coll));

    // ---------------------------------------------------------------- memory and scheduler
    reg        sn = 0;
    reg [2:0]  rv_pipe = 0;
    reg [20:0] a_pipe [0:2];
    reg [1:0]  busy_mode = 2'd2;
    reg [8:0]  busy_left = 0;
    reg        grant;
    function [15:0] hash(input [20:0] a);
        hash = {a[20:13] ^ a[7:0] ^ 8'h5A, a[12:5] ^ {a[4:0], a[20:18]} ^ 8'hC3} ^ {a[2:0], a[15:3]};
    endfunction
    always @(posedge clk) begin
        if (busy_left == 9'd0) begin busy_mode <= {$random} % 4; busy_left <= 100 + ({$random} % 400); end
        else busy_left <= busy_left - 1'b1;
        case (busy_mode)
            2'd0: grant = ({$random} % 5 == 0);
            2'd1: grant = ({$random} % 2 == 0);
            2'd2: grant = ({$random} % 5 != 0);
            default: grant = 1'b1;
        endcase
        sn <= ~sn;
        ack <= sn && r_req && grant;
        rv_pipe <= {rv_pipe[1:0], ack};
        a_pipe[0] <= r_addr;  a_pipe[1] <= a_pipe[0];  a_pipe[2] <= a_pipe[1];
        rvalid <= rv_pipe[2];
        rdata  <= hash(a_pipe[2]);
    end

    // ---------------------------------------------------------------- the beam
    // 3.7 system clocks a pixel, 864 pixels a line, 625 lines; vblank for a
    // clock as line 0 starts
    reg [5:0] bacc = 0;
    always @(posedge clk) if (!rst) begin
        vblank <= 1'b0;
        if (bacc + 6'd10 >= 6'd37) begin
            bacc <= bacc + 6'd10 - 6'd37;
            if (beam_h == 11'd863) begin
                beam_h <= 11'd0;
                if (beam_v == 11'd624) begin beam_v <= 11'd0; vblank <= 1'b1; end
                else beam_v <= beam_v + 1'b1;
            end else beam_h <= beam_h + 1'b1;
        end else bacc <= bacc + 6'd10;
    end

    // ---------------------------------------------------------------- the pixel side
    // Read pointers that consume a word now and then while the FIFO has
    // one; a flush empties the pointer and is acknowledged a few clocks on
    reg [5:0] rp [0:7];
    reg [3:0] fl_wait [0:7];
    reg [2:0] rp_hold [0:7];
    reg [47:0] r_wp_d = 48'd0;                 // the reference's wp_g a clock ago: the core registers its own
    reg [7:0] fl_seen = 8'd0;
    function [5:0] g2b(input [5:0] gv);
        integer k;
        begin
            g2b[5] = gv[5];
            for (k = 4; k >= 0; k = k - 1) g2b[k] = g2b[k + 1] ^ gv[k];
        end
    endfunction
    integer m;
    always @(posedge clk) if (!rst)
        for (m = 0; m < 8; m = m + 1) begin
            if (r_flush[m] != fl_seen[m] && rp_hold[m] != 3'd0) rp_hold[m] <= rp_hold[m] - 1'b1;   // (the pointer just moved: wait)
            else if (r_flush[m] != fl_seen[m]) begin                  // a flush: empty, then acknowledge
                if (fl_wait[m] == 4'd0) begin
                    rp[m] <= 6'd0;
                    flush_ack_t[m] <= ~flush_ack_t[m];
                    fl_seen[m] <= r_flush[m];
                    fl_wait[m] <= {$random} % 12;
                    rp_hold[m] <= 3'd4;
                end else fl_wait[m] <= fl_wait[m] - 1'b1;
            end else if (rp_hold[m] != 3'd0) rp_hold[m] <= rp_hold[m] - 1'b1;
            else if (g2b(r_wp[6*m +: 6]) != rp[m] && ({$random} % 2 == 0)) begin
                rp[m] <= rp[m] + 1'b1 + (({$random} % 4 == 0) ? {$random} % 3 : 0);   // sometimes several words at once
                rp_hold[m] <= 3'd4;
            end
            // A pointer holds for 5 clocks, as from a slower pixel clock. The
            // core accepts it when two samples agree, a clock later than the
            // reference's Gray synchroniser, so the reference gets it a clock late
            rp_b[6*m +: 6] <= rp[m];
            rp_g[6*m +: 6] <= rp_b[6*m +: 6] ^ (rp_b[6*m +: 6] >> 1);
        end

    // ---------------------------------------------------------------- the machine
    integer cyc = 0, j;
    reg [31:0] r;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        lst_wr <= 1'b0;  dat_wr <= 1'b0;  start <= 8'd0;  coll_clr <= 32'd0;
        if (!rst) begin
            r = $random;
            sel <= $random;
            fifo_ra <= {$random, $random};
            // Settings: changed one at a time, now and then. Not in the
            // clock a sprite is handed over to the core: it registers them
            // and would see the write a visit later than the reference
            // (the one allowed difference besides urgent, spec 4.2)
            if (r[7:0] < 8'd3) begin
                j = {$random} % 8;
                if (j == c_set_sel) j = (j + 1) % 8;
                case ({$random} % 7)
                    0: s_hstart[j] <= ({$random} % 4 == 0) ? $random : 11'd16 + ({$random} % 800);
                    1: s_hstop[j]  <= ({$random} % 4 == 0) ? $random : s_hstart[j] + ({$random} % 300);
                    2: begin s_vstart[j] <= {$random} % 60; s_vstop[j] <= ({$random} % 8 == 0) ? $random : 11'd200 + ({$random} % 400); end
                    3: begin s_bpp[j] <= $random; s_depth[j] <= $random; s_pal[j] <= $random; end   // bpp 3 too: undefined, but software can write it
                    4: s_xstep[j]  <= ({$random} % 4 == 0) ? $random : 16'h0400 + ({$random} % 16'h1800);
                    5: s_ystep[j]  <= ({$random} % 4 == 0) ? $random : 16'h0400 + ({$random} % 16'h1800);
                    default: begin
                        lst_wr <= 1'b1;  lst_new <= {$random} & ((1 << PW) - 1);
                    end
                endcase
            end
            if (r[15:8] == 8'd1 && r[19:16] == 4'd0) start <= $random;           // now and then: a few sprites start again
            if (r[15:8] == 8'd2 && r[19:16] == 4'd0) dma_mask <= $random | 8'h0F;  // sprites 0-3 always on the DMA
            if (r[15:8] == 8'd3 && r[19:16] == 4'd0) dma_on <= ~dma_on;
            if (cyc == 40) start <= 8'hFF;                                        // every sprite starts
            if (r[15:8] == 8'd4) begin dat_wr <= 1'b1; dat <= $random; end
            if (r[15:8] == 8'd5) coll_clr <= $random;
            if (r[15:8] == 8'd6) begin coll_line <= $random; end
            if (r[15:8] == 8'd7 && r[16]) coll_t <= ~coll_t;
        end
    end

    // ---------------------------------------------------------------- checks
    integer errors = 0, checks = 0, n_req = 0, n_urg = 0, n_act = 0, n_flush = 0, n_words = 0, n_man = 0;
    reg [6:0] prev_dl [0:7];
    reg       exp_urg;
    integer i;
    task fail(input [8*12-1:0] what, input [127:0] got, input [127:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10) $display("ERROR @%0d (beam %0d,%0d): %0s: core %h, reference %h", cyc, beam_v, beam_h, what, got, want);
        end
    endtask
    always @(negedge clk) if (!rst) begin
        checks = checks + 1;
        if (c_set_sel !== r_set_sel + 3'd1) fail("set_sel", c_set_sel, r_set_sel + 3'd1);     // the core runs one sprite ahead
        if (c_lst !== r_lst) fail("lst_cur", c_lst, r_lst);
        if (c_cnt !== r_cnt) fail("fifo_count", c_cnt, r_cnt);
        if (c_req !== r_req) fail("mem_req", c_req, r_req);
        if (r_req && c_addr !== r_addr) fail("mem_addr", c_addr, r_addr);
        if (c_hs !== r_hs) fail("p_hs", c_hs, r_hs);
        if (c_xe !== r_xe) fail("p_xe", c_xe, r_xe);
        if (c_act !== r_act) fail("p_act", c_act, r_act);
        if (c_lb !== r_lb) fail("p_lb", c_lb, r_lb);
        if (c_xstep !== r_xstep) fail("p_xstep", c_xstep, r_xstep);
        if (c_depth !== r_depth) fail("p_depth", c_depth, r_depth);
        if (c_pal !== r_pal) fail("p_pal", c_pal, r_pal);
        if (c_dma !== r_dma) fail("p_dma", c_dma, r_dma);
        if (c_rd !== r_rd) fail("fifo_rd", c_rd, r_rd);
        if (c_wp !== r_wp_d) fail("wp_g", c_wp, r_wp_d);
        r_wp_d <= r_wp;
        if (c_flush !== r_flush) fail("flush_t", c_flush, r_flush);
        if (c_coll !== r_coll) fail("coll", c_coll, r_coll);
        // urgent: the reference's compare for this clock's request, with the deadline of the clock before
        exp_urg = r_req && (prev_dl[ref.req_s] < URGENT);
        if (c_urg !== exp_urg) fail("mem_urgent", c_urg, exp_urg);
        for (i = 0; i < 8; i = i + 1) prev_dl[i] = ref.dl[i];
        if (r_req) n_req = n_req + 1;
        if (exp_urg) n_urg = n_urg + 1;
        if (r_act != 8'd0) n_act = n_act + 1;
        if (rvalid) n_words = n_words + 1;
        if (ref.man_wr != 8'd0) n_man = n_man + 1;
        if (r_flush != fl_seen) n_flush = n_flush + 1;
    end

    initial begin
        for (m = 0; m < 8; m = m + 1) begin
            s_hstart[m] = 11'd100 + 40*m;  s_hstop[m] = 11'd140 + 40*m;  s_vstart[m] = 11'd0 + 2*m;  s_vstop[m] = 11'd500 + 30*m;
            s_bpp[m] = m % 3;  s_depth[m] = m;  s_pal[m] = m;  s_xstep[m] = 16'h0800;  s_ystep[m] = 16'h0800;
            rp[m] = 6'd0;  rp_hold[m] = 3'd0;  fl_wait[m] = 4'd0;  prev_dl[m] = 7'h7F;
        end
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        repeat (`ifdef SHORT 50000 `else 1200000 `endif) @(posedge clk);
        @(negedge clk);
        $display("NS=%0d PW=%0d LITTLE=%0d URGENT=%0d MANUAL=%0d: %0d clocks, %0d requests, %0d urgent, %0d words back, %0d clocks with a sprite shown, %0d hand-fed, %0d flush clocks",
                 NS, PW, LITTLE, URGENT, MANUAL, checks, n_req, n_urg, n_words, n_act, n_man, n_flush);
        if (n_req < 1000 || n_urg == 0 || n_act == 0 || n_flush == 0 || ((MANUAL != 0) && n_man == 0)) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
