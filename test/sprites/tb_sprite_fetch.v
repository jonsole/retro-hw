// Unit test for sprite_fetch.v: two sprites fetched from a memory model
// over four lines, their FIFOs checked word by word; the line start moved
// on by YSTEP; the byte swap; a sprite fed by hand (MANUAL); the
// collisions gathered and cleared.
//
// Two cores see the same inputs: one with SWAP_BYTES 0, one with 1. The
// beam moves on a pixel every 4 clocks. The FIFOs are never read (the read
// pointers stay at 0), so all the words fetched stay in them.
`timescale 1ns/1ps
module tb_sprite_fetch;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---- the beam
    reg  [10:0] beam_h = 11'd0, beam_v = 11'd0;
    reg  [1:0]  sub = 2'd0;
    reg         vblank = 1'b0;
    always @(posedge clk) begin
        sub <= sub + 1'b1;
        if (sub == 2'd3) begin
            if (beam_h == 11'd863) begin
                beam_h <= 11'd0;
                beam_v <= (beam_v == 11'd624) ? 11'd0 : beam_v + 1'b1;
            end else
                beam_h <= beam_h + 1'b1;
        end
    end

    // ---- the settings, as a machine's registers would hold them
    reg  [10:0] r_hs [0:7], r_he [0:7], r_vs [0:7], r_ve [0:7];
    reg  [1:0]  r_bpp [0:7];
    reg  [15:0] r_xs [0:7], r_ys [0:7];
    wire [2:0]  set_sel, set_sel1;
    integer k;
    initial for (k = 0; k < 8; k = k + 1) begin
        r_hs[k] = 0; r_he[k] = 0; r_vs[k] = 0; r_ve[k] = 0; r_bpp[k] = 0; r_xs[k] = 0; r_ys[k] = 0;
    end

    reg  [7:0]  dma_mask = 8'h03;
    reg  [7:0]  start = 8'd0;
    reg  [2:0]  sel = 3'd0;
    reg         lst_wr = 1'b0;
    reg  [22:0] lst_new = 23'd0;
    reg         dat_wr = 1'b0;
    reg  [15:0] dat = 16'd0;
    reg  [31:0] coll_line = 32'd0, coll_clr = 32'd0;
    reg         coll_t = 1'b0;
    reg  [39:0] fifo_ra = 40'd0;

    // ---- the memory model: ack a clock after a request, the word 3 clocks after that
    wire        mem_req, mem_req1;
    wire [21:1] mem_addr, mem_addr1;
    reg         mem_ack = 1'b0;
    reg  [2:0]  rv = 3'd0;
    reg  [21:1] ra0, ra1, ra2;
    wire        mem_rvalid = rv[2];
    function [15:0] word_at(input [21:1] a);
        word_at = {a[8:1], 8'h00} ^ {8'h5A, a[8:1]} ^ {a[16:9], 8'h00};
    endfunction
    wire [15:0] mem_rdata = word_at(ra2);
    integer fetched = 0;
    always @(posedge clk) begin
        mem_ack <= mem_req && !mem_ack;
        rv      <= {rv[1:0], mem_ack};
        ra1     <= ra0;
        ra2     <= ra1;
        if (mem_ack) begin
            ra0     <= mem_addr;
            fetched <= fetched + 1;
        end
    end

    // ---- the flush handshake: the pixel side answers a few clocks later
    wire [7:0]  flush_t, flush_t1;
    reg  [7:0]  fa1 = 8'd0, fa2 = 8'd0, flush_ack_t = 8'd0;
    always @(posedge clk) begin
        fa1 <= flush_t; fa2 <= fa1; flush_ack_t <= fa2;
    end

    wire [22:0]  lst_cur, lst_cur1;
    wire [5:0]   fifo_count, fifo_count1;
    wire [127:0] fifo_rd, fifo_rd1;
    wire [31:0]  coll, coll1;
    wire [7:0]   p_act;
    wire [79:0]  p_hs;

    sprite_fetch #(.NS(8), .PW(23), .SWAP_BYTES(0), .URGENT(5), .MANUAL(1)) dut (
        .clk(clk), .rst(rst),
        .set_sel(set_sel),
        .set_hstart(r_hs[set_sel]), .set_hstop(r_he[set_sel]),
        .set_vstart(r_vs[set_sel]), .set_vstop(r_ve[set_sel]),
        .set_bpp(r_bpp[set_sel]), .set_depth(2'd0), .set_pal(4'd0),
        .set_xstep(r_xs[set_sel]), .set_ystep(r_ys[set_sel]),
        .dma_on(1'b1), .dma_mask(dma_mask),
        .start(start), .sel(sel), .lst_cur(lst_cur), .lst_wr(lst_wr), .lst_new(lst_new),
        .fifo_count(fifo_count), .dat_wr(dat_wr), .dat(dat),
        .vblank(vblank), .beam_v(beam_v), .beam_h(beam_h),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_deadline(), .mem_urgent(),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .p_hs(p_hs), .p_xe(), .p_act(p_act), .p_lb(), .p_xstep(), .p_depth(), .p_pal(), .p_dma(),
        .fifo_ra(fifo_ra), .fifo_rd(fifo_rd), .wp_g(), .rp_g(48'd0),
        .flush_t(flush_t), .flush_ack_t(flush_ack_t),
        .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clr), .coll(coll)
    );
    // the same, with the bytes swapped (its memory requests are not answered:
    // it sees the first core's acks and data, and asks for the same words)
    sprite_fetch #(.NS(8), .PW(23), .SWAP_BYTES(1), .URGENT(6), .MANUAL(0)) dut1 (
        .clk(clk), .rst(rst),
        .set_sel(set_sel1),
        .set_hstart(r_hs[set_sel1]), .set_hstop(r_he[set_sel1]),
        .set_vstart(r_vs[set_sel1]), .set_vstop(r_ve[set_sel1]),
        .set_bpp(r_bpp[set_sel1]), .set_depth(2'd0), .set_pal(4'd0),
        .set_xstep(r_xs[set_sel1]), .set_ystep(r_ys[set_sel1]),
        .dma_on(1'b1), .dma_mask(dma_mask),
        .start(start), .sel(sel), .lst_cur(lst_cur1), .lst_wr(lst_wr), .lst_new(lst_new),
        .fifo_count(fifo_count1), .dat_wr(dat_wr), .dat(dat),
        .vblank(vblank), .beam_v(beam_v), .beam_h(beam_h),
        .mem_req(mem_req1), .mem_addr(mem_addr1), .mem_deadline(), .mem_urgent(),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .p_hs(), .p_xe(), .p_act(), .p_lb(), .p_xstep(), .p_depth(), .p_pal(), .p_dma(),
        .fifo_ra(fifo_ra), .fifo_rd(fifo_rd1), .wp_g(), .rp_g(48'd0),
        .flush_t(flush_t1), .flush_ack_t(flush_ack_t),
        .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clr), .coll(coll1)
    );

    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %0s: got %h, want %h", what, got, want);
            errors = errors + 1;
        end
    endtask

    // the two cores must ask for the same words
    always @(posedge clk) if (!rst && (mem_req !== mem_req1 || (mem_req && mem_addr !== mem_addr1))) begin
        $display("FAIL the two cores asked differently at %0t", $time);
        errors = errors + 1;
    end

    task wait_line(input [10:0] v, input [10:0] h);
        begin
            while (!(beam_v == v && beam_h == h)) @(posedge clk);
        end
    endtask

    task set_lst(input [2:0] s, input [22:0] v);
        begin
            @(negedge clk); sel = s; lst_new = v; lst_wr = 1'b1;
            @(negedge clk); lst_wr = 1'b0;
        end
    endtask

    task go(input [2:0] s);
        begin
            @(negedge clk); start = 8'd1 << s;
            @(negedge clk); start = 8'd0;
        end
    endtask

    // the words a FIFO should hold
    task check_fifo(input [2:0] s, input integer i, input [21:1] a);
        reg [15:0] w;
        begin
            @(negedge clk);
            fifo_ra[5*s +: 5] = i[4:0];
            #1;
            w = word_at(a);
            check("FIFO word", {s, i[4:0], fifo_rd[16*s +: 16]}, {s, i[4:0], w});
            check("FIFO word, swapped", {s, i[4:0], fifo_rd1[16*s +: 16]}, {s, i[4:0], w[7:0], w[15:8]});
        end
    endtask

    integer n;
    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;
        // the frame starts: every sprite stopped
        @(negedge clk); vblank = 1'b1;
        @(negedge clk); vblank = 1'b0;

        // sprite 0: 16 pixels at 4 bits (4 words a line), lines 2-3, steps 1:1
        r_hs[0] = 11'd200; r_he[0] = 11'd216; r_vs[0] = 11'd2; r_ve[0] = 11'd4;
        r_bpp[0] = 2'd1; r_xs[0] = 16'h0800; r_ys[0] = 16'h0000;   // 0: taken as 1:1
        // sprite 1: 32 screen pixels at XSTEP 1/2 (16 source pixels, 8 bits:
        // 8 words a line), lines 2-3, YSTEP 1/2 (line 3 shows line 2 again)
        r_hs[1] = 11'd300; r_he[1] = 11'd332; r_vs[1] = 11'd2; r_ve[1] = 11'd4;
        r_bpp[1] = 2'd2; r_xs[1] = 16'h0400; r_ys[1] = 16'h0400;
        set_lst(3'd0, 23'h001000);
        set_lst(3'd1, 23'h002001);     // bit 0 is taken as 0
        go(3'd0);
        go(3'd1);
        @(negedge clk); sel = 3'd1; #1;
        check("line start, bit 0 cleared", lst_cur, 23'h002000);

        // sprite 2, DMA off, fed by hand (MANUAL)
        @(negedge clk); sel = 3'd2;
        for (n = 0; n < 3; n = n + 1) begin
            @(negedge clk); dat = 16'hC000 + n; dat_wr = 1'b1;
        end
        @(negedge clk); dat_wr = 1'b0;
        // ... and a word by hand to sprite 0, whose DMA is on: dropped
        @(negedge clk); sel = 3'd0; dat = 16'hDEAD; dat_wr = 1'b1;
        @(negedge clk); dat_wr = 1'b0;
        @(negedge clk); sel = 3'd2; #1;
        check("hand-fed count", {26'd0, fifo_count}, 32'd3);
        check("no hand-fed words without MANUAL", {26'd0, fifo_count1}, 32'd0);
        for (n = 0; n < 3; n = n + 1) begin
            @(negedge clk); fifo_ra[10 +: 5] = n; #1;
            check("hand-fed word", {16'd0, fifo_rd[32 +: 16]}, 16'hC000 + n);
        end
        @(negedge clk); sel = 3'd0; #1;
        check("no word by hand with the DMA on", {26'd0, fifo_count}, 32'd0);

        // line 1: started but not shown, nothing fetched
        wait_line(11'd1, 11'd400);
        check("nothing fetched before VSTART", fetched, 0);
        check("not shown on line 1", {24'd0, p_act}, 32'd0);
        check("HSTART to the pixel side", {22'd0, p_hs[9:0]}, 32'd200);

        wait_line(11'd2, 11'd400);
        check("shown on line 2", {24'd0, p_act & 8'h03}, 32'd3);
        check("words of line 2", fetched, 12);
        wait_line(11'd4, 11'd400);
        check("words of lines 2 and 3", fetched, 24);
        check("not shown on line 4", {24'd0, p_act}, 32'd0);

        @(negedge clk); sel = 3'd0; #1;
        check("sprite 0 FIFO count", {26'd0, fifo_count}, 32'd8);
        check("sprite 0 line start, moved on a line", lst_cur, 23'h001008);
        @(negedge clk); sel = 3'd1; #1;
        check("sprite 1 FIFO count", {26'd0, fifo_count}, 32'd16);
        check("sprite 1 line start, kept by YSTEP 1/2", lst_cur, 23'h002000);
        // sprite 0: 0x1000-0x1006, then 0x1008-0x100E
        for (n = 0; n < 8; n = n + 1) check_fifo(3'd0, n, (21'h001000 >> 1) + n);
        // sprite 1: 0x2000-0x200E twice
        for (n = 0; n < 16; n = n + 1) check_fifo(3'd1, n, (21'h002000 >> 1) + (n % 8));

        // a start again empties the FIFO
        go(3'd1);
        @(negedge clk); sel = 3'd1; #1;
        check("emptied by a start", {26'd0, fifo_count}, 32'd0);

        // collisions: a line's worth added, then cleared bit by bit
        @(negedge clk); coll_line = 32'h0000_0103; coll_t = ~coll_t;
        repeat (6) @(negedge clk);
        check("collisions", coll, 32'h0000_0103);
        coll_line = 32'h0001_0000; coll_t = ~coll_t;
        coll_clr = 32'h0000_0001;
        @(negedge clk); coll_clr = 32'd0;
        repeat (6) @(negedge clk);
        check("collisions cleared and added", coll, 32'h0001_0102);
        check("collisions, second core", coll1, 32'h0001_0102);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
