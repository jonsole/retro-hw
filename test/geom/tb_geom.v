`timescale 1ns/1ps
// The geometry engine against a bit-exact model of its spec (docs/spec/geom.md
// 4.4). The test bench is the wrapper: it holds the job as 8 long words (its
// own descriptor format) and stores the long words the core hands over on a
// descriptor load. Memory is bytes, read and written as 16-bit words in the
// machine's byte order (LE), with random waits.
//
// For every job the model transforms the points on its own copy of the
// memory and notes the bytes of the results. The core's writes must only
// touch those, and after the job the two memories must be equal.
//
// Random jobs: matrices from near rotations to anything, points from small
// to the extremes, values that saturate, points behind and just in front
// of the near plane, both job_persp settings, results over the points.
// Directed: the spec's worked example, the identity, a chain, count 0,
// stop, the error.
module tb_geom;
    parameter LE = 0;
    localparam AW = 15;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // L0: {persp, irq, bad, 13'b0, count}    L1: vaddr    L2: oaddr    L3: maddr    L7: next
    reg  [31:0] jr [0:7];
    wire        job_persp = jr[0][31];
    wire        job_irq   = jr[0][30];
    wire        job_bad   = jr[0][29];
    wire [15:0] job_count = jr[0][15:0];
    wire [23:0] job_vaddr = jr[1][23:0];
    wire [23:0] job_oaddr = jr[2][23:0];
    wire [23:0] job_maddr = jr[3][23:0];
    wire [23:0] job_next  = jr[7][23:0];

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

    geom #(.AW(AW)) dut (
        .clk(clk), .rst(rst), .enable(enable), .start_ld(start_ld), .start_run(start_run), .stop(stop),
        .da_we(da_we), .da_d(da_d), .da_q(da_q), .busy(busy), .done(done), .err(err),
        .su_v(su_v), .su_i(su_i),
        .job_count(job_count), .job_vaddr(job_vaddr), .job_oaddr(job_oaddr), .job_maddr(job_maddr),
        .job_persp(job_persp), .job_irq(job_irq), .job_next(job_next), .job_bad(job_bad),
        .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(dl_wait),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata));

    always @(posedge clk) begin
        if (dl_v) begin jr[dl_i] <= {dl_w0, dl_w1};  dl_wait <= ({$random} % 3 == 0); end
        else dl_wait <= 1'b0;
    end

    // ---------------------------------------------------------------- memory
    reg [7:0] dm [0:65535];
    reg [7:0] mm [0:65535];
    reg       al [0:65535];
    integer   errors = 0, n_wr = 0, n_rd = 0, n_jobs = 0, n_pts = 0, n_behind = 0, n_sat = 0;
    reg [15:0] rq_d [0:15];
    reg [3:0]  rq_h = 0, rq_t = 0;
    reg [2:0]  rq_wait = 0;
    wire [15:0] ea = {mem_addr, 1'b0};
    task fail(input [8*30-1:0] what, input integer a, input integer b);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("ERROR @%0t: %0s: %0h, %0h (job %0d: persp %b count %0d v %h o %h m %h)", $time, what, a, b,
                                       n_jobs, jr[0][31], jr[0][15:0], jr[1][23:0], jr[2][23:0], jr[3][23:0]);
        end
    endtask
    // A 16-bit word at an even address, in the machine's byte order
    function [15:0] rdw(input integer a);
        rdw = (LE != 0) ? {mm[(a + 1) & 65535], mm[a & 65535]} : {mm[a & 65535], mm[(a + 1) & 65535]};
    endfunction
    integer touched [0:8191];
    integer n_touched = 0;
    task wrw(input integer a, input [15:0] v);          // the model's write
        integer b0, b1;
        begin
            b0 = a & 65535;  b1 = (a + 1) & 65535;
            if (LE != 0) begin mm[b0] = v[7:0];  mm[b1] = v[15:8]; end
            else         begin mm[b0] = v[15:8]; mm[b1] = v[7:0];  end
            if (!al[b0]) begin al[b0] = 1'b1;  touched[n_touched] = b0;  n_touched = n_touched + 1; end
            if (!al[b1]) begin al[b1] = 1'b1;  touched[n_touched] = b1;  n_touched = n_touched + 1; end
        end
    endtask
    always @(posedge clk) begin
        mem_ack    <= mem_req && !mem_ack && ({$random} % 3 != 0);
        mem_rvalid <= 1'b0;
        if (mem_req && mem_ack) begin
            if (mem_we) begin
                n_wr = n_wr + 1;
                if (mem_be !== 2'b11) fail("write byte enables", mem_be, 3);
                if (LE != 0) begin dm[ea] = mem_wdata[7:0];  dm[ea + 16'd1] = mem_wdata[15:8]; end
                else         begin dm[ea] = mem_wdata[15:8]; dm[ea + 16'd1] = mem_wdata[7:0];  end
                if (!al[ea] || !al[ea + 16'd1]) fail("write outside the results", ea, mem_wdata);
            end else begin
                n_rd = n_rd + 1;
                rq_d[rq_t] = (LE != 0) ? {dm[ea + 16'd1], dm[ea]} : {dm[ea], dm[ea + 16'd1]};
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

    // ---------------------------------------------------------------- the model (spec 4.4)
    function integer s16(input [15:0] v);  s16 = v[15] ? v - 65536 : v;  endfunction
    function signed [63:0] sat(input signed [63:0] v, input signed [63:0] lo, input signed [63:0] hi);
        sat = (v < lo) ? lo : (v > hi) ? hi : v;
    endfunction
    function signed [63:0] fdiv(input signed [63:0] a, input signed [63:0] b);   // floor(a / b), b > 0
        begin
            fdiv = a / b;
            if ((a % b) != 0 && a < 0) fdiv = fdiv - 1;
        end
    endfunction
    task model_job;
        integer n, i, x, y, z, d, cx, cy, zn;
        integer m [0:8];
        integer t [0:2];
        reg signed [63:0] v [0:2];
        reg signed [63:0] acc, sx, sy;
        begin
            #1;
            if (job_count != 0) begin
                for (i = 0; i < 9; i = i + 1) m[i] = s16(rdw(job_maddr + 2 * i));
                for (i = 0; i < 3; i = i + 1) t[i] = s16(rdw(job_maddr + 18 + 2 * i));
                d  = rdw(job_maddr + 24);  cx = s16(rdw(job_maddr + 26));  cy = s16(rdw(job_maddr + 28));  zn = s16(rdw(job_maddr + 30));
                for (n = 0; n < job_count; n = n + 1) begin
                    x = s16(rdw(job_vaddr + 6 * n));  y = s16(rdw(job_vaddr + 6 * n + 2));  z = s16(rdw(job_vaddr + 6 * n + 4));
                    for (i = 0; i < 3; i = i + 1) begin
                        acc  = $signed(m[3*i]) * x + $signed(m[3*i + 1]) * y + $signed(m[3*i + 2]) * z;
                        acc  = (acc >>> 14) + t[i];
                        if (acc > 32767 || acc < -32768) n_sat = n_sat + 1;
                        v[i] = sat(acc, -32768, 32767);
                    end
                    if (job_persp && v[2] < zn) begin
                        sx = -32768;  sy = -32768;  n_behind = n_behind + 1;
                    end else if (job_persp) begin
                        sx = sat(cx + fdiv(v[0] * d, v[2]), -32767, 32767);
                        sy = sat(cy + fdiv(v[1] * d, v[2]), -32767, 32767);
                    end else begin
                        sx = sat(cx + v[0], -32767, 32767);  sy = sat(cy + v[1], -32767, 32767);
                    end
                    wrw(job_oaddr + 6 * n, sx[15:0]);  wrw(job_oaddr + 6 * n + 2, sy[15:0]);  wrw(job_oaddr + 6 * n + 4, v[2][15:0]);
                    n_pts = n_pts + 1;
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
            for (a = 0; a < 65536; a = a + 1)
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
    task put(input integer a, input [15:0] v);          // a word in both memories
        begin
            if (LE != 0) begin dm[a] = v[7:0];  dm[a + 1] = v[15:8]; end
            else         begin dm[a] = v[15:8]; dm[a + 1] = v[7:0];  end
            mm[a] = dm[a];  mm[a + 1] = dm[a + 1];
        end
    endtask
    task set_job(input persp, input irq, input integer count, input [23:0] va, input [23:0] oa, input [23:0] ma, input [23:0] next);
        begin
            jr[0] = {persp, irq, 1'b0, 13'd0, count[15:0]};
            jr[1] = {8'd0, va};  jr[2] = {8'd0, oa};  jr[3] = {8'd0, ma};
            jr[4] = 32'd0;  jr[5] = 32'd0;  jr[6] = 32'd0;  jr[7] = {8'd0, next};
        end
    endtask
    task put_desc(input integer a);
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) begin put(a + 4 * q, jr[q][31:16]);  put(a + 4 * q + 2, jr[q][15:0]); end
        end
    endtask
    task wait_idle;
        begin
            guard = 0;
            @(negedge clk);
            while (busy && guard < 2000000) begin @(negedge clk);  guard = guard + 1; end
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

    // Random: a view block at 0x3000, points at 0x1000, results at 0x2000 or over the points
    integer t, i, kind, cnt;
    function [15:0] rnd_coord(input integer kind_);
        case (kind_)
            0:       rnd_coord = ({$random} % 601) - 300;
            1:       rnd_coord = $random;
            default: rnd_coord = ({$random} % 4 == 0) ? (({$random} % 2) ? 16'h7FFF : 16'h8000) : ({$random} % 4001) - 2000;
        endcase
    endfunction
    task random_job;
        begin
            kind = {$random} % 3;
            for (i = 0; i < 9; i = i + 1)       // a matrix: near the identity scaled, or anything
                put(16'h3000 + 2 * i, (kind == 0) ? (((i % 4) == 0) ? 16'h4000 : 16'h0000) + ({$random} % 4097) - 2048
                                    : (kind == 1) ? $random : ({$random} % 32769) - 16384);
            for (i = 0; i < 3; i = i + 1) put(16'h3000 + 18 + 2 * i, (kind == 1) ? $random : ({$random} % 2001) - 1000);
            if (kind != 1) put(16'h3000 + 22, 300 + {$random} % 800);                    // tz in front, mostly
            put(16'h3000 + 24, ({$random} % 4 == 0) ? $random : 64 + {$random} % 512);    // d
            put(16'h3000 + 26, ({$random} % 641) - 160);  put(16'h3000 + 28, ({$random} % 401) - 100);
            put(16'h3000 + 30, 1 + {$random} % 64);                                       // znear
            cnt = 1 + {$random} % 12;
            for (i = 0; i < 3 * cnt; i = i + 1) put(16'h1000 + 2 * i, rnd_coord({$random} % 3));
            set_job({$random} % 4 != 0, 1'b0, cnt, 24'h001000, ({$random} % 4 == 0) ? 24'h001000 : 24'h002000, 24'h003000, 24'd0);
            run;
        end
    endtask

    integer a, d0, q;
    initial begin
        for (a = 0; a < 65536; a = a + 1) begin dm[a] = $random;  mm[a] = dm[a];  al[a] = 1'b0; end
        for (a = 0; a < 8; a = a + 1) jr[a] = 32'd0;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        for (t = 0; t < 4000; t = t + 1) random_job;
        $display("%0d random jobs: %0d points, %0d behind the near plane, %0d view values saturated", n_jobs, n_pts, n_behind, n_sat);
        if (n_behind < 100 || n_sat < 100) fail("a case never came up", n_behind, n_sat);

        // ---- the spec's worked example (4.5): 30 degrees about y
        put(16'h3000, 16'h376D);  put(16'h3002, 16'h0000);  put(16'h3004, 16'h2000);
        put(16'h3006, 16'h0000);  put(16'h3008, 16'h4000);  put(16'h300A, 16'h0000);
        put(16'h300C, 16'hE000);  put(16'h300E, 16'h0000);  put(16'h3010, 16'h376D);
        put(16'h3012, 0);  put(16'h3014, 0);  put(16'h3016, 400);
        put(16'h3018, 256);  put(16'h301A, 160);  put(16'h301C, 100);  put(16'h301E, 16);
        put(16'h1000, 100);   put(16'h1002, -50);  put(16'h1004, 200);
        put(16'h1006, -100);  put(16'h1008, 50);   put(16'h100A, -200);
        put(16'h100C, 0);     put(16'h100E, 0);    put(16'h1010, -390);
        put(16'h1012, 0);     put(16'h1014, 0);    put(16'h1016, -460);
        set_job(1'b1, 1'b0, 4, 24'h001000, 24'h002000, 24'h003000, 24'd0);  run;
        if (s16(rdw(16'h2000)) != 251  || s16(rdw(16'h2002)) != 75  || s16(rdw(16'h2004)) != 523) fail("example point 1", rdw(16'h2000), rdw(16'h2002));
        if (s16(rdw(16'h2006)) != -14  || s16(rdw(16'h2008)) != 146 || s16(rdw(16'h200A)) != 276) fail("example point 2", rdw(16'h2006), rdw(16'h2008));
        if (s16(rdw(16'h200C)) != -646 || s16(rdw(16'h200E)) != 100 || s16(rdw(16'h2010)) != 62)  fail("example point 3", rdw(16'h200C), rdw(16'h200E));
        if (rdw(16'h2012) !== 16'h8000 || rdw(16'h2014) !== 16'h8000 || s16(rdw(16'h2016)) != 1)  fail("example point 4 (behind)", rdw(16'h2012), rdw(16'h2016));

        // ---- the identity, no perspective: the points come back with the centre added; the extremes limit at +-32767
        for (i = 0; i < 9; i = i + 1) put(16'h3000 + 2 * i, ((i % 4) == 0) ? 16'h4000 : 16'h0000);
        for (i = 9; i < 16; i = i + 1) put(16'h3000 + 2 * i, 0);
        put(16'h301A, 10);  put(16'h301C, -10);
        put(16'h1000, 5);  put(16'h1002, 6);  put(16'h1004, 7);
        put(16'h1006, 16'h7FFF);  put(16'h1008, 16'h8000);  put(16'h100A, 16'h8000);
        set_job(1'b0, 1'b0, 2, 24'h001000, 24'h002000, 24'h003000, 24'd0);  run;
        if (s16(rdw(16'h2000)) != 15 || s16(rdw(16'h2002)) != -4 || s16(rdw(16'h2004)) != 7) fail("identity", rdw(16'h2000), rdw(16'h2002));
        if (s16(rdw(16'h2006)) != 32767 || s16(rdw(16'h2008)) != -32767 || s16(rdw(16'h200A)) != -32768) fail("identity at the limits", rdw(16'h2006), rdw(16'h2008));

        // ---- a chain: two jobs from descriptors (the second in place), then one with count 0; the first has job_irq
        d0 = n_done;
        set_job(1'b1, 1'b0, 0, 24'h001000, 24'h002000, 24'h003000, 24'd0);            put_desc(16'h3840);
        set_job(1'b0, 1'b0, 2, 24'h001000, 24'h001000, 24'h003000, 24'h003840);       put_desc(16'h3820);
        set_job(1'b0, 1'b1, 2, 24'h001000, 24'h002100, 24'h003000, 24'h003820);       put_desc(16'h3800);
        model_job;
        set_job(1'b0, 1'b0, 2, 24'h001000, 24'h001000, 24'h003000, 24'h003840);       model_job;
        for (a = 0; a < 8; a = a + 1) jr[a] = 32'hFFFF_FFFF;
        @(negedge clk) begin da_d = 24'h003800;  da_we = 1'b1; end
        @(negedge clk) begin da_we = 1'b0;  start_ld = 1'b1; end
        @(negedge clk) start_ld = 1'b0;
        wait_idle;
        compare("memory after the chain");  clear_allowed;
        if (n_done - d0 != 2) fail("chain: done strobes", n_done - d0, 2);
        if (da_q !== 24'h003840) fail("chain: da_q", da_q, 24'h3840);

        // ---- stop mid-job: it ends early with done and no error
        for (i = 0; i < 600; i = i + 1) put(16'h1000 + 2 * i, $random);
        set_job(1'b1, 1'b0, 200, 24'h001000, 24'h002000, 24'h003000, 24'd0);
        model_job;  d0 = n_done;  q = n_wr;
        @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;
        repeat (2000) @(negedge clk);
        stop = 1'b1;  @(negedge clk) stop = 1'b0;
        wait_idle;
        if (n_done - d0 != 1 || err) fail("stop: done strobes, err", n_done - d0, err);
        if (n_wr - q == 0 || n_wr - q >= 600 || (n_wr - q) % 3 != 0) fail("stop: writes (whole points, not all)", n_wr - q, 0);
        for (a = 0; a < 65536; a = a + 1) mm[a] = dm[a];
        clear_allowed;

        // ---- the error: nothing is read or written
        q = n_wr + n_rd;
        set_job(1'b1, 1'b0, 3, 24'h001000, 24'h002000, 24'h003000, 24'd0);  jr[0][29] = 1'b1;
        @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;  wait_idle;
        if (!err) fail("job_bad is not an error", 0, 0);
        if (n_wr + n_rd != q) fail("an error job used the memory", n_wr + n_rd - q, 0);
        random_job;

        $display("LE=%0d: %0d jobs, %0d writes, %0d reads", LE, n_jobs, n_wr, n_rd);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
