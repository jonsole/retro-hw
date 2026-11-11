`timescale 1ns/1ps
// The rasteriser against a pixel-exact model of its spec (docs/spec/raster.md
// 4.5). The test bench is the wrapper: it holds the job as 8 long words (its
// own descriptor format) and the clip window, and stores the long words the
// core hands over on a descriptor load. Memory answers after random waits.
//
// For every job the model plots the spec's pixels on its own copy of the
// memory and notes every byte that holds a plotted pixel. The core's
// writes must only touch those bytes, and after the job the two memories
// must be equal.
//
// Random lines and triangles at every depth, with points inside and far
// outside random windows, every minterm, patterns, job_nolast, both stride
// signs. Properties: a triangle XORed in two different point orders leaves
// the bitmap as it was; a line and nothing else changes under a window.
// Directed: the spec's worked examples, flat and one-pixel shapes, a chain,
// stop, the errors.
module tb_raster;
    parameter LE = 0;
    parameter TRI = 1;
    localparam AW = 16;                      // 128 KB of memory
    localparam MB = 131072;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------------------------------------------------------- the wrapper
    reg  [31:0] jr [0:7];
    // L0: {minterm, bpp, tri, nolast, irq, bad, 2'b0, pattern}    L1: x0, y0    L2: x1, y1    L3: x2, y2
    // L4: {value, daddr}    L5: {16'b0, dstride}    L6: -    L7: next
    wire [7:0]  job_minterm = jr[0][31:24];
    wire [1:0]  job_bpp     = jr[0][23:22];
    wire        job_tri     = jr[0][21];
    wire        job_nolast  = jr[0][20];
    wire        job_irq     = jr[0][19];
    wire        job_bad     = jr[0][18];
    wire [15:0] job_pattern = jr[0][15:0];
    wire [15:0] job_x0 = jr[1][31:16], job_y0 = jr[1][15:0];
    wire [15:0] job_x1 = jr[2][31:16], job_y1 = jr[2][15:0];
    wire [15:0] job_x2 = jr[3][31:16], job_y2 = jr[3][15:0];
    wire [7:0]  job_value   = jr[4][31:24];
    wire [23:0] job_daddr   = jr[4][23:0];
    wire [15:0] job_dstride = jr[5][15:0];
    wire [23:0] job_next    = jr[7][23:0];
    reg  [15:0] clip_xmin = 0, clip_xmax = 0, clip_ymin = 0, clip_ymax = 0;

    reg         enable = 1'b1, start_ld = 0, start_run = 0, stop = 0, da_we = 0;
    reg  [23:0] da_d = 0;
    wire [23:0] da_q;
    wire        busy, done, err, su_v, dl_v, mem_req, mem_we;
    wire [2:0]  su_i, dl_i;
    wire [15:0] dl_w0, dl_w1, mem_wdata;
    wire [AW-1:0] mem_addr;
    wire [1:0]  mem_be;
    reg         dl_wait = 0, mem_ack = 0, mem_rvalid = 0;
    reg  [15:0] mem_rdata = 0;

    raster #(.AW(AW), .LE(LE), .TRI(TRI)) dut (
        .clk(clk), .rst(rst), .enable(enable), .start_ld(start_ld), .start_run(start_run), .stop(stop),
        .da_we(da_we), .da_d(da_d), .da_q(da_q), .busy(busy), .done(done), .err(err),
        .su_v(su_v), .su_i(su_i),
        .job_tri(job_tri), .job_minterm(job_minterm), .job_bpp(job_bpp), .job_value(job_value),
        .job_pattern(job_pattern), .job_nolast(job_nolast), .job_irq(job_irq),
        .job_x0(job_x0), .job_y0(job_y0), .job_x1(job_x1), .job_y1(job_y1), .job_x2(job_x2), .job_y2(job_y2),
        .job_daddr(job_daddr), .job_dstride(job_dstride),
        .clip_xmin(clip_xmin), .clip_xmax(clip_xmax), .clip_ymin(clip_ymin), .clip_ymax(clip_ymax),
        .job_next(job_next), .job_bad(job_bad),
        .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(dl_wait),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata));

    always @(posedge clk) begin
        if (dl_v) begin jr[dl_i] <= {dl_w0, dl_w1};  dl_wait <= ({$random} % 3 == 0); end
        else dl_wait <= 1'b0;
    end

    // ---------------------------------------------------------------- memory
    reg [7:0] dm [0:MB-1];
    reg [7:0] mm [0:MB-1];
    reg       al [0:MB-1];
    integer   errors = 0, n_wr = 0, n_rd = 0, slow = 0, n_jobs = 0;
    reg [15:0] rq_d [0:15];
    reg [3:0]  rq_h = 0, rq_t = 0;
    reg [2:0]  rq_wait = 0;
    wire [16:0] ea = {mem_addr, 1'b0};
    task fail(input [8*30-1:0] what, input integer a, input integer b);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("ERROR @%0t: %0s: %0h, %0h", $time, what, a, b);
            if (errors <= 3)
                $display("   job %0d: %0s mt %h bpp %0d val %h pat %h nolast %b (%0d,%0d) (%0d,%0d) (%0d,%0d) d %h/%0d clip x %0d..%0d y %0d..%0d",
                         n_jobs, jr[0][21] ? "TRI" : "LINE", jr[0][31:24], jr[0][23:22], jr[4][31:24], jr[0][15:0], jr[0][20],
                         $signed(jr[1][31:16]), $signed(jr[1][15:0]), $signed(jr[2][31:16]), $signed(jr[2][15:0]),
                         $signed(jr[3][31:16]), $signed(jr[3][15:0]), jr[4][23:0], $signed(jr[5][15:0]),
                         $signed(clip_xmin), $signed(clip_xmax), $signed(clip_ymin), $signed(clip_ymax));
        end
    endtask
    task wbyte(input [16:0] a, input [7:0] v);
        begin
            dm[a] = v;
            if (!al[a]) fail("write outside the job", a, v);
        end
    endtask
    always @(posedge clk) begin
        mem_ack    <= mem_req && !mem_ack && (slow ? ({$random} % 6 == 0) : ({$random} % 3 != 0));
        mem_rvalid <= 1'b0;
        if (mem_req && mem_ack) begin
            if (mem_we) begin
                n_wr = n_wr + 1;
                if ((mem_be[0] && ^mem_wdata[7:0] === 1'bx) || (mem_be[1] && ^mem_wdata[15:8] === 1'bx)) fail("unknown bits written", ea, mem_wdata);
                if (LE != 0) begin
                    if (mem_be[0]) wbyte(ea, mem_wdata[7:0]);
                    if (mem_be[1]) wbyte(ea + 17'd1, mem_wdata[15:8]);
                end else begin
                    if (mem_be[1]) wbyte(ea, mem_wdata[15:8]);
                    if (mem_be[0]) wbyte(ea + 17'd1, mem_wdata[7:0]);
                end
            end else begin
                n_rd = n_rd + 1;
                rq_d[rq_t] = (LE != 0) ? {dm[ea + 17'd1], dm[ea]} : {dm[ea], dm[ea + 17'd1]};
                rq_t = rq_t + 1'b1;
            end
        end
        if (rq_h != rq_t) begin
            if (rq_wait == 0) begin
                mem_rvalid <= 1'b1;  mem_rdata <= rq_d[rq_h];  rq_h = rq_h + 1'b1;
                rq_wait = {$random} % 4;
            end else rq_wait = rq_wait - 1'b1;
        end
    end

    // ---------------------------------------------------------------- the model (spec 4.5)
    integer touched [0:65535];
    integer n_touched = 0, n_plot = 0;
    function integer sx16(input [15:0] v);  sx16 = v[15] ? v - 65536 : v;  endfunction
    function integer fdiv(input integer a, input integer b);          // floor(a / b), b > 0 (in 64 bits)
        reg signed [63:0] p, q;
        begin
            p = a;  p = p * 65536;  q = p / b;
            if ((p % b) != 0 && p < 0) q = q - 1;
            fdiv = q;
        end
    endfunction
    task plot(input integer x, input integer y, input integer A);
        integer bits, msk, pos, by, sh, C, B, D, j;
        begin
            if (x >= sx16(clip_xmin) && x <= sx16(clip_xmax) && y >= sx16(clip_ymin) && y <= sx16(clip_ymax)) begin
                bits = 1 << job_bpp;  msk = (1 << bits) - 1;
                pos  = 8 * (job_daddr + y * sx16(job_dstride)) + x * bits;
                by   = (pos >>> 3) & (MB - 1);  sh = 8 - (pos & 7) - bits;
                C = (mm[by] >> sh) & msk;  B = job_value & msk;  D = 0;
                for (j = 0; j < bits; j = j + 1)
                    if (job_minterm[4 * A + 2 * ((B >> j) & 1) + ((C >> j) & 1)]) D = D | (1 << j);
                mm[by] = (mm[by] & ~(msk << sh)) | (D << sh);
                if (!al[by]) begin al[by] = 1'b1;  touched[n_touched] = by;  n_touched = n_touched + 1; end
                n_plot = n_plot + 1;
            end
        end
    endtask
    function integer ceil16(input reg signed [63:0] v);               // ceil(v / 65536)
        reg signed [63:0] t;
        begin t = v + 65535;  ceil16 = t >>> 16; end
    endfunction
    task model_job;
        integer x0, y0, x1, y1, x2, y2, dx, dy, sx, sy, xmaj, major, minor, e, x, y, i, t;
        integer xt, yt, xm, ym, xb, yb, sl, s1, s2, l, r;
        reg signed [63:0] XL, XS, lo, hi;
        begin
            #1;
            x0 = sx16(job_x0);  y0 = sx16(job_y0);  x1 = sx16(job_x1);  y1 = sx16(job_y1);  x2 = sx16(job_x2);  y2 = sx16(job_y2);
            if (!job_tri) begin
                dx = (x1 > x0) ? x1 - x0 : x0 - x1;  dy = (y1 > y0) ? y1 - y0 : y0 - y1;
                sx = (x1 >= x0) ? 1 : -1;  sy = (y1 >= y0) ? 1 : -1;
                xmaj = (dx >= dy);  major = xmaj ? dx : dy;  minor = xmaj ? dy : dx;
                e = major / 2;  x = x0;  y = y0;
                for (i = 0; i <= major; i = i + 1) begin
                    if (!(job_nolast && i == major)) plot(x, y, job_pattern[15 - (i % 16)]);
                    e = e - minor;
                    if (e < 0) begin
                        e = e + major;
                        if (xmaj) y = y + sy; else x = x + sx;
                    end
                    if (xmaj) x = x + sx; else y = y + sy;
                end
            end else begin
                xt = x0;  yt = y0;  xm = x1;  ym = y1;  xb = x2;  yb = y2;
                if (ym < yt) begin t = xt; xt = xm; xm = t;  t = yt; yt = ym; ym = t; end
                if (yb < ym) begin t = xm; xm = xb; xb = t;  t = ym; ym = yb; yb = t; end
                if (ym < yt) begin t = xt; xt = xm; xm = t;  t = yt; yt = ym; ym = t; end
                sl = (yb > yt) ? fdiv(xb - xt, yb - yt) : 0;
                s1 = (ym > yt) ? fdiv(xm - xt, ym - yt) : 0;
                s2 = (yb > ym) ? fdiv(xb - xm, yb - ym) : 0;
                for (y = yt; y < yb; y = y + 1) begin
                    XL = xt;  XL = XL * 65536 + $signed(sl) * (y - yt);
                    if (y < ym) begin XS = xt;  XS = XS * 65536 + $signed(s1) * (y - yt); end
                    else        begin XS = xm;  XS = XS * 65536 + $signed(s2) * (y - ym); end
                    lo = (XL < XS) ? XL : XS;  hi = (XL < XS) ? XS : XL;
                    l = ceil16(lo);  r = ceil16(hi);
                    // (only the part inside the window is walked: plot would drop the rest)
                    if (l < sx16(clip_xmin)) l = sx16(clip_xmin);
                    if (r > sx16(clip_xmax) + 1) r = sx16(clip_xmax) + 1;
                    for (x = l; x < r; x = x + 1) plot(x, y, 1);
                end
            end
        end
    endtask
    task clear_allowed;
        integer q;
        begin
            for (q = 0; q < n_touched; q = q + 1) al[touched[q]] = 1'b0;
            n_touched = 0;
        end
    endtask
    task compare(input [8*24-1:0] what);
        integer a, bad;
        begin
            bad = 0;
            for (a = 16'h3000; a < 16'h6000; a = a + 1)
                if (dm[a] !== mm[a]) begin
                    if (bad == 0) fail(what, a, {dm[a], mm[a]});
                    bad = bad + 1;
                    dm[a] = mm[a];
                end
        end
    endtask

    // ---------------------------------------------------------------- running jobs
    integer n_done = 0, guard;
    always @(posedge clk) if (done) n_done = n_done + 1;
    task set_job(input tr, input [7:0] mt, input [1:0] bpp, input [7:0] value, input [15:0] pattern, input nolast, input irq,
                 input integer x0, input integer y0, input integer x1, input integer y1, input integer x2, input integer y2,
                 input [23:0] daddr, input integer ds, input [23:0] next);
        begin
            jr[0] = {mt, bpp, tr, nolast, irq, 1'b0, 2'b00, pattern};
            jr[1] = {x0[15:0], y0[15:0]};  jr[2] = {x1[15:0], y1[15:0]};  jr[3] = {x2[15:0], y2[15:0]};
            jr[4] = {value, daddr};  jr[5] = {16'd0, ds[15:0]};  jr[6] = 32'd0;  jr[7] = {8'd0, next};
        end
    endtask
    task wait_idle;
        begin
            guard = 0;
            @(negedge clk);
            while (busy && guard < 4000000) begin @(negedge clk);  guard = guard + 1; end
            if (busy) fail("job never ended", guard, 0);
            repeat (2) @(negedge clk);
        end
    endtask
    task run;
        begin
            model_job;
            @(negedge clk) start_run = 1'b1;
            @(negedge clk) start_run = 1'b0;
            wait_idle;
            if (err) fail("unexpected error flag", 1, 0);
            compare("memory after the job");
            clear_allowed;
            n_jobs = n_jobs + 1;
        end
    endtask
    task put_word(input [16:0] a, input [15:0] v);
        begin
            if (LE != 0) begin dm[a] = v[7:0];  dm[a + 17'd1] = v[15:8]; end
            else         begin dm[a] = v[15:8]; dm[a + 17'd1] = v[7:0];  end
            mm[a] = dm[a];  mm[a + 17'd1] = dm[a + 17'd1];
        end
    endtask
    task put_desc(input [16:0] a);
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) begin
                put_word(a + 4 * q, jr[q][31:16]);  put_word(a + 4 * q + 2, jr[q][15:0]);
            end
        end
    endtask

    // A bitmap of 40 bytes a row and 60 rows at 0x4000 (rows upwards from its end, for a negative stride)
    integer lb, bits, W, t, neg, far;
    reg [7:0] mt;
    function integer coord(input integer span, input integer far_);
        coord = far_ ? ({$random} % 6000) - 3000 : ({$random} % (span + 40)) - 20;
    endfunction
    task window(input integer w_);
        integer xa, xb_, ya, yb_;
        begin
            xa = {$random} % w_;  xb_ = {$random} % w_;  ya = {$random} % 60;  yb_ = {$random} % 60;
            if ({$random} % 4 == 0) begin xa = 0;  xb_ = w_ - 1;  ya = 0;  yb_ = 59; end
            clip_xmin = (xa < xb_) ? xa : xb_;  clip_xmax = (xa < xb_) ? xb_ : xa;
            clip_ymin = (ya < yb_) ? ya : yb_;  clip_ymax = (ya < yb_) ? yb_ : ya;
        end
    endtask
    task random_job(input tr);
        begin
            lb = {$random} % 4;  bits = 1 << lb;  W = 320 / bits;
            window(W);
            case ({$random} % 8)
                0: mt = 8'hCC;  1: mt = 8'hCA;  2: mt = 8'h66;  3: mt = 8'h0A;  default: mt = $random;
            endcase
            neg = {$random} % 2;  far = ({$random} % 10 == 0);
            set_job(tr, mt, lb[1:0], $random, ({$random} % 3 == 0) ? 16'hFFFF : $random, {$random} % 2, 1'b0,
                    coord(W, far), coord(60, far), coord(W, far), coord(60, far), coord(W, 0), coord(60, 0),
                    neg ? 24'h004000 + 59 * 40 : 24'h004000, neg ? -40 : 40, 24'd0);
            run;
        end
    endtask

    integer a, d0, q, p0;
    reg [7:0] snap [0:16'h1FFF];
    initial begin
        for (a = 0; a < MB; a = a + 1) begin dm[a] = $random;  mm[a] = dm[a];  al[a] = 1'b0; end
        for (a = 0; a < 8; a = a + 1) jr[a] = 32'd0;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // ---- random lines, and triangles where they are built
        for (t = 0; t < 2500; t = t + 1) random_job(1'b0);
        if (TRI != 0) for (t = 0; t < 2500; t = t + 1) random_job(1'b1);
        slow = 1;
        for (t = 0; t < 200; t = t + 1) random_job(1'b0);
        if (TRI != 0) for (t = 0; t < 200; t = t + 1) random_job(1'b1);
        slow = 0;
        $display("%0d random jobs, %0d pixels plotted by the model", n_jobs, n_plot);

        // ---- the spec's worked examples (4.6), 8 bits a pixel, the whole bitmap as the window
        clip_xmin = 0;  clip_xmax = 39;  clip_ymin = 0;  clip_ymax = 59;
        p0 = n_plot;
        set_job(0, 8'hCC, 3, 8'h55, 16'hFFFF, 0, 0, 2, 1, 9, 4, 0, 0, 24'h004000, 40, 0);  run;
        if (n_plot - p0 != 8) fail("the example line's pixels", n_plot - p0, 8);
        if (mm[16'h4000 + 1*40 + 2] !== 8'h55 || mm[16'h4000 + 2*40 + 4] !== 8'h55 || mm[16'h4000 + 4*40 + 9] !== 8'h55)
            fail("the example line's ends", 0, 0);
        p0 = n_plot;
        set_job(0, 8'hCC, 3, 8'h66, 16'hFFFF, 1, 0, 2, 1, 9, 4, 0, 0, 24'h004000, 40, 0);  run;
        if (n_plot - p0 != 7 || mm[16'h4000 + 4*40 + 9] !== 8'h55) fail("job_nolast", n_plot - p0, 7);
        if (TRI != 0) begin
            p0 = n_plot;
            set_job(1, 8'hCC, 3, 8'h77, 0, 0, 0, 3, 6, 14, 9, 10, 2, 24'h004000, 40, 0);  run;
            // rows 3 to 8: 2 + 5 + 7 + 10 + 6 + 3 pixels
            if (n_plot - p0 != 33) fail("the example triangle's pixels", n_plot - p0, 33);
            if (mm[16'h4000 + 6*40 + 3] !== 8'h77 || mm[16'h4000 + 6*40 + 12] !== 8'h77 || mm[16'h4000 + 6*40 + 13] === 8'h77
                || mm[16'h4000 + 8*40 + 11] !== 8'h77 || mm[16'h4000 + 9*40 + 14] === 8'h77)
                fail("the example triangle's corners", 0, 0);
        end

        // ---- a triangle XORed in two different point orders leaves the bitmap as it was
        if (TRI != 0) for (t = 0; t < 200; t = t + 1) begin
            for (a = 0; a < 16'h2000; a = a + 1) snap[a] = mm[16'h3000 + a];
            lb = {$random} % 4;  bits = 1 << lb;  W = 320 / bits;  window(W);
            set_job(1, 8'h66, lb[1:0], 8'hFF, 0, 0, 0, coord(W, 0), coord(60, 0), coord(W, 0), coord(60, 0), coord(W, 0), coord(60, 0), 24'h004000, 40, 0);
            run;
            case ({$random} % 5)                                   // another order of the same points
                0: begin jr[1] <= jr[2];  jr[2] <= jr[1]; end
                1: begin jr[1] <= jr[3];  jr[3] <= jr[1]; end
                2: begin jr[2] <= jr[3];  jr[3] <= jr[2]; end
                3: begin jr[1] <= jr[2];  jr[2] <= jr[3];  jr[3] <= jr[1]; end
                default: begin jr[1] <= jr[3];  jr[3] <= jr[2];  jr[2] <= jr[1]; end
            endcase
            @(negedge clk);
            run;
            q = 0;
            for (a = 0; a < 16'h2000; a = a + 1) if (snap[a] !== mm[16'h3000 + a]) q = q + 1;
            if (q != 0) fail("point order changes a triangle", q, t);
        end

        // ---- flat and tiny shapes: single pixels, horizontal, vertical, zero-area
        clip_xmin = 0;  clip_xmax = 39;  clip_ymin = 0;  clip_ymax = 59;
        set_job(0, 8'hCC, 3, 8'h11, 16'hFFFF, 0, 0, 5, 5, 5, 5, 0, 0, 24'h004000, 40, 0);  run;
        set_job(0, 8'hCC, 3, 8'h12, 16'hF0F0, 0, 0, 0, 7, 39, 7, 0, 0, 24'h004000, 40, 0);  run;
        set_job(0, 8'hCC, 3, 8'h13, 16'hAAAA, 0, 0, 7, 59, 7, 0, 0, 0, 24'h004000, 40, 0);  run;
        set_job(0, 8'hCC, 0, 8'h01, 16'hFFFF, 0, 0, 0, 0, 319, 59, 0, 0, 24'h004000, 40, 0);
        clip_xmax = 319;  run;  clip_xmax = 39;
        if (TRI != 0) begin
            p0 = n_plot;
            set_job(1, 8'hCC, 3, 8'h21, 0, 0, 0, 4, 4, 4, 4, 4, 4, 24'h004000, 40, 0);  run;
            set_job(1, 8'hCC, 3, 8'h22, 0, 0, 0, 1, 9, 30, 9, 12, 9, 24'h004000, 40, 0);  run;
            set_job(1, 8'hCC, 3, 8'h23, 0, 0, 0, 1, 1, 9, 9, 20, 20, 24'h004000, 40, 0);  run;
            if (n_plot != p0) fail("a triangle with no area drew", n_plot - p0, 0);
            set_job(1, 8'hCC, 3, 8'h24, 0, 0, 0, 3, 3, 20, 3, 3, 30, 24'h004000, 40, 0);  run;    // flat top
            set_job(1, 8'hCC, 3, 8'h25, 0, 0, 0, 10, 3, 3, 30, 25, 30, 24'h004000, 40, 0);  run;  // flat bottom
        end

        // ---- a chain of three lines from descriptors, the first with job_irq
        d0 = n_done;
        set_job(0, 8'h66, 3, 8'hFF, 16'hFFFF, 0, 0, 30, 2, 2, 50, 0, 0, 24'h004000, 40, 0);              put_desc(17'h7040);
        model_job;
        set_job(0, 8'hCC, 3, 8'h31, 16'hFFFF, 0, 0, 0, 20, 39, 25, 0, 0, 24'h004000, 40, 24'h007040);    put_desc(17'h7020);
        model_job;
        set_job(0, 8'hCC, 3, 8'h32, 16'hFFFF, 0, 1, 0, 0, 39, 59, 0, 0, 24'h004000, 40, 24'h007020);     put_desc(17'h7000);
        model_job;
        // (the model ran them last to first; these three don't depend on the order where they cross: redo in order)
        for (a = 16'h3000; a < 16'h6000; a = a + 1) mm[a] = dm[a];
        put_desc(17'h7000);  model_job;
        jr[7] = 32'd0;  set_job(0, 8'hCC, 3, 8'h31, 16'hFFFF, 0, 0, 0, 20, 39, 25, 0, 0, 24'h004000, 40, 24'h007040);  model_job;
        set_job(0, 8'h66, 3, 8'hFF, 16'hFFFF, 0, 0, 30, 2, 2, 50, 0, 0, 24'h004000, 40, 0);  model_job;
        for (a = 0; a < 8; a = a + 1) jr[a] = 32'hFFFF_FFFF;
        @(negedge clk) begin da_d = 24'h007000;  da_we = 1'b1; end
        @(negedge clk) begin da_we = 1'b0;  start_ld = 1'b1; end
        @(negedge clk) start_ld = 1'b0;
        wait_idle;
        compare("memory after the chain");  clear_allowed;
        if (n_done - d0 != 2) fail("chain: done strobes", n_done - d0, 2);
        if (da_q !== 24'h007040) fail("chain: da_q", da_q, 24'h7040);

        // ---- stop mid-job
        clip_xmax = 319;
        set_job(0, 8'hCC, 0, 8'h01, 16'hFFFF, 0, 0, 0, 0, 319, 59, 0, 0, 24'h004000, 40, 0);
        model_job;  d0 = n_done;
        @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;
        repeat (300) @(negedge clk);
        stop = 1'b1;  @(negedge clk) stop = 1'b0;
        wait_idle;
        if (n_done - d0 != 1 || err) fail("stop: done strobes, err", n_done - d0, err);
        for (a = 16'h3000; a < 16'h6000; a = a + 1) mm[a] = dm[a];
        clear_allowed;

        // ---- errors: a bad job, and a triangle where they are not built
        q = n_wr;
        set_job(0, 8'hCC, 3, 8'h41, 16'hFFFF, 0, 0, 1, 1, 9, 9, 0, 0, 24'h004000, 40, 0);  jr[0][18] = 1'b1;
        @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;  wait_idle;
        if (!err) fail("job_bad is not an error", 0, 0);
        if (TRI == 0) begin
            set_job(1, 8'hCC, 3, 8'h42, 0, 0, 0, 1, 1, 9, 9, 3, 20, 24'h004000, 40, 0);
            @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;  wait_idle;
            if (!err) fail("TRI without TRI is not an error", 0, 0);
        end
        if (n_wr != q) fail("an error job wrote", n_wr - q, 0);
        set_job(0, 8'hCC, 3, 8'h43, 16'hFFFF, 0, 0, 1, 1, 9, 9, 0, 0, 24'h004000, 40, 0);  clip_xmax = 39;  run;

        $display("LE=%0d TRI=%0d: %0d jobs, %0d writes, %0d reads", LE, TRI, n_jobs, n_wr, n_rd);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
