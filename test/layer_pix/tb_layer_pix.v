`timescale 1ns/1ps
// layer_pix.v on its own. A small beam (200 pixels a line, the line's setup
// from pixel 170) and a fetcher stand-in that hands over a new group as soon
// as the last was taken. Two units: one with planar layers built (the
// defaults), one with tiles built and no planar layers. Each line, every
// pixel is checked against a model: opaque in the window only, and the
// colour index (and tile priority) of the right source pixel.
//
// Lines: chunky at 1, 2, 4 and 8 bits per pixel; planar with 1, 3, 5 and 8
// planes; fine scroll; scale 2, 4 and 8; the palette offset; a transparent
// colour 0; tiles with PAL and PRI per column; a window that starts later;
// and a fetcher that stops (overrun: the layer goes transparent and
// overrun_t toggles).
module tb_layer_pix;
    reg clk5 = 1'b0;
    always #1 clk5 = ~clk5;            // 5 x clk_pix, edges lined up
    reg clk = 1'b0;
    always #5 clk = ~clk;

    localparam H = 200, LS = 170;
    reg  [10:0] hc = 11'd0;
    wire [10:0] hn = (hc == H - 1) ? 11'd0 : hc + 1'b1;
    wire        line_start = (hc == LS);

    reg         en = 1'b0;
    reg         active, planar, transp, tile;
    reg  [10:0] xs, xe;
    reg  [1:0]  lb, hs;
    reg  [2:0]  planes;
    reg  [3:0]  pos0, palofs;

    // The fetcher stand-in: group g of the line, until "stop" groups
    reg  [127:0] dat_p, dat_t;
    reg  [9:0]   attr;
    reg          fill_p = 1'b0, fill_t = 1'b0;
    wire         take_p, take_t;
    integer      g_p, g_t, stop;

    function [15:0] word(input integer g, input integer i);
        word = (g * 16'h3B71 + i * 16'h1F35 + 16'hA5C3) ^ (16'h0101 << (g % 8));
    endfunction
    function [127:0] group(input integer g);
        integer i;
        for (i = 0; i < 8; i = i + 1) group[16*i +: 16] = word(g, i);
    endfunction
    function [9:0] gattr(input integer g);
        gattr = (g * 10'd37 + 10'd5) & 10'h3FF;
    endfunction

    always @(posedge clk) begin
        hc <= hn;
        if (line_start) begin
            fill_p <= take_p;              // empty: a spare group is dropped
            fill_t <= take_t;
            g_p <= 0;
            g_t <= 0;
        end else begin
            if (fill_p == take_p && g_p < stop) begin
                dat_p  <= group(g_p);
                fill_p <= ~fill_p;
                g_p    <= g_p + 1;
            end
            if (fill_t == take_t && g_t < stop) begin
                dat_t  <= group(g_t);
                attr   <= gattr(g_t);
                fill_t <= ~fill_t;
                g_t    <= g_t + 1;
            end
        end
    end

    wire        op_p, op_t, pri_p, pri_t, ov_p, ov_t;
    wire [7:0]  idx_p, idx_t, raw_p, raw_t;
    layer_pix u_planar (
        .clk_pix(clk), .clk_pix5(clk5), .en(en), .hc(hc), .hn(hn), .line_start(line_start), .ready(1'b1),
        .active(active), .xs(xs), .xe(xe), .planar(planar), .lb(lb), .planes(planes), .hs(hs), .pos0(pos0),
        .transp(transp), .palofs(palofs), .tile(1'b0),
        .dat(dat_p), .attr(10'd0), .fill_t(fill_p), .take_t(take_p),
        .opaque(op_p), .idx(idx_p), .pri(pri_p), .raw(raw_p), .overrun_t(ov_p)
    );
    layer_pix #(.PLANAR(0), .TILES(1)) u_tiles (
        .clk_pix(clk), .clk_pix5(clk5), .en(en), .hc(hc), .hn(hn), .line_start(line_start), .ready(1'b1),
        .active(active), .xs(xs), .xe(xe), .planar(1'b0), .lb(lb), .planes(3'd0), .hs(hs), .pos0(pos0),
        .transp(transp), .palofs(palofs), .tile(tile),
        .dat(dat_t), .attr(attr), .fill_t(fill_t), .take_t(take_t),
        .opaque(op_t), .idx(idx_t), .pri(pri_t), .raw(raw_t), .overrun_t(ov_t)
    );

    // ---------------------------------------------------------------- the model
    // Screen pixel k of the window: source pixel pos0 + k / scale
    function [7:0] value(input integer k, input pl);
        integer s, g, p, b, bitp, wi, q;
        reg [127:0] d;
        reg [15:0] w;
        begin
            s = pos0 + (k >> hs);
            g = s / 16;
            p = s % 16;
            d = group(g);
            value = 8'd0;
            if (pl) begin
                for (q = 0; q <= planes; q = q + 1) value[q] = d[16*q + 15 - p];
            end else begin
                b    = 1 << lb;
                bitp = p * b;
                wi   = (b - 1) - bitp / 16;
                w    = d[16*wi +: 16] << (bitp % 16);
                value = w[15:8] >> (8 - b);
            end
        end
    endfunction
    function [8:0] expect_px(input integer k, input pl, input tl);    // {opaque-if-transp, pri, idx}
        reg [7:0] v;
        reg [4:0] ca;
        reg       deep;
        integer   s;
        begin
            v    = value(k, pl);
            s    = pos0 + (k >> hs);
            ca   = (s % 16 >= 8) ? gattr(s / 16) >> 5 : gattr(s / 16);
            deep = pl ? planes[2] : (lb == 2'd3);
            if (deep)    expect_px = {tl && ca[4], v};
            else if (tl) expect_px = {ca[4], palofs + ca[3:0], v[3:0]};
            else         expect_px = {1'b0, palofs, v[3:0]};
        end
    endfunction

    // ---------------------------------------------------------------- checks
    integer errors = 0, checked = 0, lines = 0;
    integer cur_stop;                  // groups this line gets
    reg     chk_p, chk_t;              // which units this line checks
    task fail(input [8*20-1:0] what, input integer x, input [15:0] got, input [15:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("ERROR: line %0d, %0s at pixel %0d: got %h, expected %h", lines, what, x, got, want);
        end
    endtask
    // A pixel's output is ready one clock after the beam is on it
    integer x, k, last_k;
    reg     win, want_op;
    reg [8:0] e;
    always @(negedge clk) if (en && hc != 0 && hc < LS) begin
        x   = hc - 1;
        k   = x - xs;
        win = active && x >= xs && x < xe;
        // With "stop" groups the source pixels past them are missing
        last_k = (cur_stop * 16 - pos0) << hs;
        if (chk_p) begin
            e       = expect_px(k, planar, 1'b0);
            want_op = win && k < last_k && !(transp && value(k, planar) == 8'd0);
            if (op_p !== want_op) fail("planar unit opaque", x, op_p, want_op);
            else if (want_op && idx_p !== e[7:0]) fail("planar unit idx", x, idx_p, e[7:0]);
            if (pri_p !== 1'b0) fail("planar unit pri", x, pri_p, 0);
            checked = checked + 1;
        end
        if (chk_t) begin
            e       = expect_px(k, 1'b0, tile);
            want_op = win && k < last_k && !(transp && value(k, 1'b0) == 8'd0);
            if (op_t !== want_op) fail("tile unit opaque", x, op_t, want_op);
            else if (want_op && idx_t !== e[7:0]) fail("tile unit idx", x, idx_t, e[7:0]);
            if (want_op && pri_t !== e[8]) fail("tile unit pri", x, pri_t, e[8]);
            checked = checked + 1;
        end
    end

    // One line: the settings are set in the clock the line's setup starts,
    // and the line is checked through to the next setup
    task line(input a, input pl, input tl, input [1:0] l, input [2:0] np, input [1:0] s,
              input [3:0] p0, input [3:0] po, input tr, input [10:0] x0, input [10:0] x1,
              input integer groups, input cp, input ct);
        begin
            while (hc != LS) @(negedge clk);
            active = a; planar = pl; tile = tl; lb = l; planes = np; hs = s;
            pos0 = p0; palofs = po; transp = tr; xs = x0; xe = x1;
            stop = groups; cur_stop = groups;
            chk_p = cp; chk_t = ct;
            lines = lines + 1;
            @(negedge clk);
            while (hc != LS) @(negedge clk);
        end
    endtask

    integer ovp0, ovt0;
    initial begin
        active = 0; planar = 0; tile = 0; lb = 0; planes = 0; hs = 0; pos0 = 0; palofs = 0;
        transp = 0; xs = 0; xe = 0; stop = 99; cur_stop = 99; chk_p = 0; chk_t = 0;
        g_p = 0; g_t = 0;
        repeat (5) @(negedge clk);
        en = 1'b1;
        line(0, 0, 0, 0, 0, 0, 0,   4'h0, 0, 11'd0,  11'd0,   99, 0, 0);   // a line to start from
        //    act pl tl lb np hs pos0 pal tr  xs   xe   groups  units
        line(1, 0, 0, 0, 0, 0, 0,   4'h3, 0, 11'd0,  11'd160, 99, 1, 1);   // chunky 1 bit
        line(1, 0, 0, 1, 0, 0, 0,   4'h5, 0, 11'd0,  11'd160, 99, 1, 1);   // 2 bits
        line(1, 0, 0, 2, 0, 0, 0,   4'h9, 0, 11'd0,  11'd160, 99, 1, 1);   // 4 bits
        line(1, 0, 0, 3, 0, 0, 0,   4'hF, 0, 11'd0,  11'd160, 99, 1, 1);   // 8 bits: no offset
        line(1, 1, 0, 0, 0, 0, 0,   4'h2, 0, 11'd0,  11'd160, 99, 1, 0);   // planar, 1 plane
        line(1, 1, 0, 0, 2, 0, 0,   4'h7, 0, 11'd0,  11'd160, 99, 1, 0);   // 3 planes
        line(1, 1, 0, 0, 4, 0, 0,   4'h7, 0, 11'd0,  11'd160, 99, 1, 0);   // 5 planes: no offset
        line(1, 1, 0, 0, 7, 0, 0,   4'h1, 0, 11'd0,  11'd160, 99, 1, 0);   // 8 planes
        line(1, 0, 0, 2, 0, 0, 4'd5, 4'h0, 0, 11'd0, 11'd160, 99, 1, 1);   // fine scroll 5
        line(1, 0, 0, 1, 0, 0, 4'd15, 4'h4, 0, 11'd0, 11'd160, 99, 1, 1);  // fine scroll 15
        line(1, 1, 0, 0, 3, 0, 4'd9, 4'h6, 0, 11'd0, 11'd160, 99, 1, 0);   // planar, scrolled
        line(1, 0, 0, 2, 0, 1, 4'd3, 4'h1, 0, 11'd0, 11'd160, 99, 1, 1);   // scale 2
        line(1, 0, 0, 0, 0, 2, 0,   4'h1, 0, 11'd0,  11'd160, 99, 1, 1);   // scale 4
        line(1, 0, 0, 3, 0, 3, 4'd7, 4'h1, 0, 11'd0, 11'd160, 99, 1, 1);   // scale 8
        line(1, 0, 0, 1, 0, 0, 0,   4'h8, 1, 11'd0,  11'd160, 99, 1, 1);   // colour 0 transparent
        line(1, 1, 0, 0, 1, 0, 0,   4'h8, 1, 11'd0,  11'd160, 99, 1, 0);   // ... planar
        line(1, 0, 0, 2, 0, 0, 0,   4'h4, 0, 11'd37, 11'd101, 99, 1, 1);   // a later window
        line(1, 0, 0, 3, 0, 0, 0,   4'h4, 0, 11'd3,  11'd164, 99, 1, 1);   // a group starts with the last pixel
        line(1, 1, 0, 0, 7, 0, 0,   4'h4, 0, 11'd3,  11'd164, 99, 1, 0);   // ... planar
        line(0, 0, 0, 2, 0, 0, 0,   4'h4, 0, 11'd0,  11'd160, 99, 1, 1);   // not active
        line(1, 0, 1, 0, 0, 0, 0,   4'h2, 0, 11'd0,  11'd160, 99, 0, 1);   // tiles, 1 bit
        line(1, 0, 1, 1, 0, 0, 4'd6, 4'hC, 0, 11'd0, 11'd160, 99, 0, 1);   // tiles, 2 bits, scrolled
        line(1, 0, 1, 2, 0, 1, 0,   4'h3, 0, 11'd0,  11'd160, 99, 0, 1);   // tiles, 4 bits, scale 2
        line(1, 0, 1, 3, 0, 0, 0,   4'h3, 0, 11'd0,  11'd160, 99, 0, 1);   // tiles, 8 bits: no PAL
        line(1, 1, 1, 2, 2, 0, 0,   4'h3, 0, 11'd0,  11'd160, 99, 1, 0);   // planar unit ignores tile
        // Overrun: 3 groups only
        ovp0 = ov_p; ovt0 = ov_t;
        line(1, 0, 0, 0, 0, 0, 0,   4'h3, 0, 11'd0,  11'd160, 3, 1, 1);
        if (ov_p == ovp0 || ov_t == ovt0) begin
            errors = errors + 1;
            $display("ERROR: no overrun reported");
        end
        line(1, 1, 0, 0, 3, 0, 4'd2, 4'h3, 0, 11'd0, 11'd160, 2, 1, 0);
        // And back to a full line
        line(1, 0, 0, 2, 0, 0, 0,   4'h9, 0, 11'd0,  11'd160, 99, 1, 1);
        $display("%0d lines, %0d pixels checked", lines, checked);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
