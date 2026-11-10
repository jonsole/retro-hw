`timescale 1ns/1ps
// The blitter against a pixel-exact model of its spec (docs/spec/blitter.md
// 4.8). The test bench is the wrapper: it holds the job as 8 long words (its
// own descriptor format), decodes them onto the job ports, and stores the
// long words the core hands over on a descriptor load. Memory answers
// after random waits and reads come back in order a few clocks later.
//
// For every job the model works the pixels one by one, in the order the
// spec gives, on its own copy of the memory, and notes every byte that
// holds a pixel of the job. The core's writes must only touch those bytes,
// and after the job the two memories must be equal.
//
// Random jobs: every depth, bit position, mask kind, minterm, direction and
// stride sign, constant and memory B, with source, mask and destination
// apart. Directed: overlapping copies in the four directions, chains with
// an empty job, access counts, stop, enable held low, the errors.
module tb_blitter;
    parameter LE = 0;
    parameter MASKIMG = 1;
    localparam AW = 15;                      // 64 KB of memory

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---------------------------------------------------------------- the wrapper
    reg  [31:0] jr [0:7];                    // the job, as 8 long words
    // L0: {minterm, mask, bpp, rtl, bconst, irq, bad}, value    L1: height, {key, 8'b0}
    // L2: astride, bstride    L3: dstride, width
    // L4: {5'b0, abit, aaddr}    L5: {5'b0, bbit, baddr}    L6: {5'b0, dbit, daddr}    L7: next
    wire [7:0]  job_minterm = jr[0][31:24];
    wire [1:0]  job_mask    = jr[0][23:22];
    wire [1:0]  job_bpp     = jr[0][21:20];
    wire        job_rtl     = jr[0][19];
    wire        job_bconst  = jr[0][18];
    wire        job_irq     = jr[0][17];
    wire        job_bad     = jr[0][16];
    wire [15:0] job_value   = jr[0][15:0];
    wire [15:0] job_height  = jr[1][31:16];
    wire [7:0]  job_key     = jr[1][15:8];
    wire [15:0] job_astride = jr[2][31:16];
    wire [15:0] job_bstride = jr[2][15:0];
    wire [15:0] job_dstride = jr[3][31:16];
    wire [15:0] job_width   = jr[3][15:0];
    wire [2:0]  job_abit    = jr[4][26:24];
    wire [23:0] job_aaddr   = jr[4][23:0];
    wire [2:0]  job_bbit    = jr[5][26:24];
    wire [23:0] job_baddr   = jr[5][23:0];
    wire [2:0]  job_dbit    = jr[6][26:24];
    wire [23:0] job_daddr   = jr[6][23:0];
    wire [23:0] job_next    = jr[7][23:0];

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

    blitter #(.AW(AW), .LE(LE), .MASKIMG(MASKIMG)) dut (
        .clk(clk), .rst(rst), .enable(enable), .start_ld(start_ld), .start_run(start_run), .stop(stop),
        .da_we(da_we), .da_d(da_d), .da_q(da_q), .busy(busy), .done(done), .err(err),
        .su_v(su_v), .su_i(su_i),
        .job_minterm(job_minterm), .job_mask(job_mask), .job_bpp(job_bpp), .job_rtl(job_rtl),
        .job_bconst(job_bconst), .job_irq(job_irq), .job_value(job_value), .job_key(job_key),
        .job_astride(job_astride), .job_bstride(job_bstride), .job_dstride(job_dstride),
        .job_width(job_width), .job_height(job_height),
        .job_aaddr(job_aaddr), .job_baddr(job_baddr), .job_daddr(job_daddr),
        .job_abit(job_abit), .job_bbit(job_bbit), .job_dbit(job_dbit), .job_next(job_next), .job_bad(job_bad),
        .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(dl_wait),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata));

    // A descriptor long word is stored a clock or two after it is handed over
    always @(posedge clk) begin
        if (dl_v) begin jr[dl_i] <= {dl_w0, dl_w1};  dl_wait <= ({$random} % 3 == 0); end
        else dl_wait <= 1'b0;
    end

    // ---------------------------------------------------------------- memory
    reg [7:0] dm [0:65535];                  // the core's memory
    reg [7:0] mm [0:65535];                  // the model's
    reg       al [0:65535];                  // bytes the job may write
    integer   errors = 0, n_wr = 0, n_rd = 0, n_bad_wr = 0, slow = 0, n_jobs = 0;
    reg [15:0] rq_d [0:15];                  // reads on their way
    reg [3:0]  rq_h = 0, rq_t = 0;
    reg [2:0]  rq_wait = 0;
    wire [15:0] ea = {mem_addr, 1'b0};       // the even byte's address
    task fail(input [8*30-1:0] what, input integer a, input integer b);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("ERROR @%0t: %0s: %0h, %0h", $time, what, a, b);
            if (errors <= 3)
                $display("   job %0d: mt %h mask %0d bpp %0d rtl %b bconst %b val %h key %h w %0d h %0d a %h.%0d/%0d b %h.%0d/%0d d %h.%0d/%0d",
                         n_jobs, jr[0][31:24], jr[0][23:22], jr[0][21:20], jr[0][19], jr[0][18], jr[0][15:0], jr[1][15:8], jr[3][15:0], jr[1][31:16],
                         jr[4][23:0], jr[4][26:24], $signed(jr[2][31:16]), jr[5][23:0], jr[5][26:24], $signed(jr[2][15:0]),
                         jr[6][23:0], jr[6][26:24], $signed(jr[3][31:16]));
        end
    endtask
    always @(posedge clk) begin
        mem_ack    <= mem_req && !mem_ack && (slow ? ({$random} % 6 == 0) : ({$random} % 3 != 0));
        mem_rvalid <= 1'b0;
        if (mem_req && mem_ack) begin
            if (mem_we) begin
                n_wr = n_wr + 1;
                // even byte: bits 15-8 big-endian (be[1]), bits 7-0 little-endian (be[0])
                if (LE != 0) begin
                    if (mem_be[0]) begin dm[ea] = mem_wdata[7:0];       if (!al[ea])          begin n_bad_wr = n_bad_wr + 1; fail("write outside the job", ea, mem_wdata); end end
                    if (mem_be[1]) begin dm[ea + 16'd1] = mem_wdata[15:8]; if (!al[ea + 16'd1]) begin n_bad_wr = n_bad_wr + 1; fail("write outside the job", ea + 1, mem_wdata); end end
                end else begin
                    if (mem_be[1]) begin dm[ea] = mem_wdata[15:8];      if (!al[ea])          begin n_bad_wr = n_bad_wr + 1; fail("write outside the job", ea, mem_wdata); end end
                    if (mem_be[0]) begin dm[ea + 16'd1] = mem_wdata[7:0];  if (!al[ea + 16'd1]) begin n_bad_wr = n_bad_wr + 1; fail("write outside the job", ea + 1, mem_wdata); end end
                end
            end else begin
                n_rd = n_rd + 1;
                rq_d[rq_t] = (LE != 0) ? {dm[ea + 16'd1], dm[ea]} : {dm[ea], dm[ea + 16'd1]};
                rq_t = rq_t + 1'b1;
                if (mem_be !== 2'b11) fail("read byte enables", mem_be, 3);
            end
        end
        if (rq_h != rq_t) begin
            if (rq_wait == 0) begin
                mem_rvalid <= 1'b1;  mem_rdata <= rq_d[rq_h];  rq_h = rq_h + 1'b1;
                rq_wait = {$random} % 4;
            end else rq_wait = rq_wait - 1'b1;
        end
    end

    // ---------------------------------------------------------------- the model (spec 4.8)
    integer touched [0:8191];
    integer n_touched = 0;
    function integer sx16(input [15:0] v);  sx16 = v[15] ? v - 65536 : v;  endfunction
    task model_job;                          // the job in jr, on mm
        integer bits, r, i, k, pd, pb, pa, pos, sh, C, B, A, D, j, msk, by, wq;
        begin
            #1;                                  // (the job's wires follow jr)
            bits = 1 << job_bpp;  msk = (1 << bits) - 1;
            for (r = 0; r < job_height; r = r + 1) begin
                pd = 8 * (job_daddr + r * sx16(job_dstride)) + job_dbit * bits;
                pb = 8 * (job_baddr + r * sx16(job_bstride)) + job_bbit * bits;
                pa = 8 * (job_aaddr + r * sx16(job_astride)) + job_abit;
                for (i = 0; i < job_width; i = i + 1) begin
                    k   = job_rtl ? -i : i;
                    pos = pd + k * bits;
                    by  = (pos >> 3) & 65535;  sh = 8 - (pos & 7) - bits;
                    C   = (mm[by] >> sh) & msk;
                    if (job_bconst) begin
                        wq = pos & 15;
                        B  = (job_value >> (16 - wq - bits)) & msk;
                    end else begin
                        pos = pb + k * bits;
                        B   = (mm[(pos >> 3) & 65535] >> (8 - (pos & 7) - bits)) & msk;
                    end
                    if (job_mask == 2'd0) A = 1;
                    else if (job_mask == 2'd1) begin
                        pos = pa + k;
                        A   = (mm[(pos >> 3) & 65535] >> (7 - (pos & 7))) & 1;
                    end else A = (B != (job_key & msk));
                    D = 0;
                    for (j = 0; j < bits; j = j + 1)
                        if (job_minterm[4 * A + 2 * ((B >> j) & 1) + ((C >> j) & 1)]) D = D | (1 << j);
                    mm[by] = (mm[by] & ~(msk << sh)) | (D << sh);
                    if (!al[by]) begin al[by] = 1'b1;  touched[n_touched] = by;  n_touched = n_touched + 1; end
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
    task compare(input [8*20-1:0] what);
        integer a, bad;
        begin
            bad = 0;
            for (a = 0; a < 65536; a = a + 1)
                if (dm[a] !== mm[a]) begin
                    if (bad == 0) begin
                        fail(what, a, {dm[a], mm[a]});
                        if (errors <= 12)
                            $display("   job: mt %h mask %0d bpp %0d rtl %b bconst %b val %h key %h w %0d h %0d a %h.%0d/%0d b %h.%0d/%0d d %h.%0d/%0d",
                                     job_minterm, job_mask, job_bpp, job_rtl, job_bconst, job_value, job_key, job_width, job_height,
                                     job_aaddr, job_abit, sx16(job_astride), job_baddr, job_bbit, sx16(job_bstride),
                                     job_daddr, job_dbit, sx16(job_dstride));
                    end
                    bad = bad + 1;
                    dm[a] = mm[a];                       // carry on from the model's memory
                end
        end
    endtask

    // ---------------------------------------------------------------- running jobs
    integer n_done = 0, guard;
    always @(posedge clk) if (done) n_done = n_done + 1;
    task set_job(input [7:0] mt, input [1:0] mask, input [1:0] bpp, input rtl, input bconst, input irq,
                 input [15:0] value, input [7:0] key, input integer w, input integer h,
                 input [23:0] aa, input [2:0] ab, input integer as,
                 input [23:0] ba, input [2:0] bb, input integer bs,
                 input [23:0] daa, input [2:0] db, input integer ds, input [23:0] next);
        begin
            jr[0] = {mt, mask, bpp, rtl, bconst, irq, 1'b0, value};
            jr[1] = {h[15:0], key, 8'h00};
            jr[2] = {as[15:0], bs[15:0]};
            jr[3] = {ds[15:0], w[15:0]};
            jr[4] = {5'd0, ab, aa};  jr[5] = {5'd0, bb, ba};  jr[6] = {5'd0, db, daa};
            jr[7] = {8'd0, next};
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
    task run;                                // the job in jr: model, then the core, then compare
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
    // A descriptor in both memories, as the wrapper's 8 long words
    task put_word(input [15:0] a, input [15:0] v);
        begin
            if (LE != 0) begin dm[a] = v[7:0];  dm[a + 16'd1] = v[15:8]; end
            else         begin dm[a] = v[15:8]; dm[a + 16'd1] = v[7:0];  end
            mm[a] = dm[a];  mm[a + 16'd1] = dm[a + 16'd1];
        end
    endtask
    task put_desc(input [15:0] a);           // from jr
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) begin
                put_word(a + 4 * q, jr[q][31:16]);  put_word(a + 4 * q + 2, jr[q][15:0]);
            end
        end
    endtask

    // Random jobs: A, B and D in their own parts of the memory
    integer lb, bits, w, h, t;
    reg [7:0] mt;
    reg [1:0] mk;
    task random_job;
        begin
            lb = {$random} % 4;  bits = 1 << lb;
            w  = ({$random} % 4 == 0) ? 1 + {$random} % 3 : 1 + {$random} % 70;
            h  = 1 + {$random} % 5;
            case ({$random} % 12)
                0: mt = 8'hCC;  1: mt = 8'hCA;  2: mt = 8'h66;  3: mt = 8'hEE;  4: mt = 8'h88;
                5: mt = 8'h0A;  6: mt = 8'hFF;  7: mt = 8'h00;  default: mt = $random;
            endcase
            mk = {$random} % 3;
            if (MASKIMG == 0 && mk == 2'd1) mk = 2'd0;
            set_job(mt, mk, lb[1:0], {$random} % 2, {$random} % 3 == 0, 1'b0, $random, $random, w, h,
                    24'h003400 + {$random} % 64, {$random} % 8, ({$random} % 97) - 48,
                    24'h002800 + {$random} % 64, {$random} % (8 / bits), ({$random} % 97) - 48,
                    24'h001000 + {$random} % 64, {$random} % (8 / bits), ({$random} % 97) - 48, 24'd0);
            run;
        end
    endtask

    integer a, wr0, rd0, d0, q;
    initial begin
        for (a = 0; a < 65536; a = a + 1) begin dm[a] = $random;  mm[a] = dm[a];  al[a] = 1'b0; end
        for (a = 0; a < 8; a = a + 1) jr[a] = 32'd0;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // ---- random jobs, fast memory then slow
        for (t = 0; t < 3000; t = t + 1) random_job;
        slow = 1;
        for (t = 0; t < 400; t = t + 1) random_job;
        slow = 0;
        $display("%0d random jobs", n_jobs);

        // ---- access counts (spec 4.3): an 8-bit 32 x 2 rectangle on word boundaries
        wr0 = n_wr;  rd0 = n_rd;
        set_job(8'hCC, 0, 3, 0, 1, 0, 16'h0707, 0, 32, 2, 0, 0, 0, 0, 0, 0, 24'h001000, 0, 64, 0);  run;
        if (n_wr - wr0 != 32 || n_rd - rd0 != 0) fail("fill: writes, reads", n_wr - wr0, n_rd - rd0);
        wr0 = n_wr;  rd0 = n_rd;
        set_job(8'hCC, 0, 3, 0, 0, 0, 0, 0, 32, 2, 0, 0, 0, 24'h002800, 0, 32, 24'h001000, 0, 64, 0);  run;
        if (n_wr - wr0 != 32 || n_rd - rd0 != 32) fail("copy: writes, reads", n_wr - wr0, n_rd - rd0);
        wr0 = n_wr;  rd0 = n_rd;
        set_job(8'hCA, 2, 3, 0, 0, 0, 0, 0, 32, 2, 0, 0, 0, 24'h002800, 0, 32, 24'h001000, 0, 64, 0);  run;
        if (n_wr - wr0 != 32 || n_rd - rd0 != 64) fail("key cut: writes, reads", n_wr - wr0, n_rd - rd0);

        // ---- overlapping copies, each in its safe direction (4 bits a pixel, 40 bytes a row)
        // left 3 pixels; up 2 rows; right 5 pixels (right to left); right 37 pixels; down 2 rows (bottom up)
        set_job(8'hCC, 0, 2, 0, 0, 0, 0, 0, 60, 6, 0, 0, 0, 24'h001001, 1, 40, 24'h001000, 0, 40, 0);  run;
        set_job(8'hCC, 0, 2, 0, 0, 0, 0, 0, 60, 6, 0, 0, 0, 24'h001050, 0, 40, 24'h001000, 0, 40, 0);  run;
        set_job(8'hCC, 0, 2, 1, 0, 0, 0, 0, 60, 6, 0, 0, 0, 24'h00101D, 1, 40, 24'h001020, 0, 40, 0);  run;
        set_job(8'hCC, 0, 2, 1, 0, 0, 0, 0, 60, 6, 0, 0, 0, 24'h00101D, 1, 40, 24'h001030, 0, 40, 0);  run;
        set_job(8'hCC, 0, 2, 0, 0, 0, 0, 0, 60, 6, 0, 0, 0, 24'h0010C8, 0, -40, 24'h001118, 0, -40, 0);  run;
        // the same at 1 bit and 8 bits, right by less than a word and by more
        set_job(8'hCC, 0, 0, 1, 0, 0, 0, 0, 200, 3, 0, 0, 0, 24'h001018, 7, 40, 24'h001019, 4, 40, 0);  run;
        set_job(8'hCC, 0, 3, 1, 0, 0, 0, 0, 30, 3, 0, 0, 0, 24'h00101D, 0, 40, 24'h001020, 0, 40, 0);  run;

        // ---- a chain of three jobs from descriptors, the middle one empty, the first with job_irq
        d0 = n_done;
        set_job(8'h66, 0, 3, 0, 1, 0, 16'hFFFF, 0, 20, 2, 0, 0, 0, 0, 0, 0, 24'h001200, 0, 64, 0);          put_desc(16'h3C40);
        model_job;                                                                                             // (the third job)
        set_job(8'hCC, 0, 3, 0, 1, 0, 16'h1111, 0, 0, 5, 0, 0, 0, 0, 0, 0, 24'h001000, 0, 64, 24'h003C40);   put_desc(16'h3C20);
        set_job(8'hCC, 0, 1, 0, 1, 1, 16'h5555, 0, 33, 3, 0, 0, 0, 0, 0, 0, 24'h001100, 1, 16, 24'h003C20);  put_desc(16'h3C00);
        model_job;                                                                                             // (the first)
        for (a = 0; a < 8; a = a + 1) jr[a] = 32'hFFFF_FFFF;                                                  // the wrapper's job is junk until loaded
        @(negedge clk) begin da_d = 24'h003C00;  da_we = 1'b1; end
        @(negedge clk) begin da_we = 1'b0;  start_ld = 1'b1; end
        @(negedge clk) start_ld = 1'b0;
        wait_idle;
        compare("memory after the chain");  clear_allowed;
        if (n_done - d0 != 2) fail("chain: done strobes", n_done - d0, 2);
        if (da_q !== 24'h003C40) fail("chain: da_q", da_q, 24'h3C40);
        if (err) fail("chain: err", 1, 0);

        // ---- enable held low mid-job: no new request while it is low
        set_job(8'hCA, 2, 3, 0, 0, 0, 0, 8'h11, 64, 8, 0, 0, 0, 24'h002800, 0, 64, 24'h001000, 0, 64, 0);
        model_job;
        @(negedge clk) start_run = 1'b1;
        @(negedge clk) start_run = 1'b0;
        repeat (200) @(negedge clk);
        enable = 1'b0;
        repeat (4) @(negedge clk);
        wr0 = n_wr + n_rd;
        while (mem_req) @(negedge clk);
        for (q = 0; q < 100; q = q + 1) begin @(negedge clk); if (mem_req) fail("request while enable is low", q, 0); end
        if (!busy) fail("enable low ended the job", 0, 0);
        enable = 1'b1;
        wait_idle;
        compare("memory after enable low");  clear_allowed;

        // ---- stop mid-job: it ends early, with done and no error, writing only inside the job
        set_job(8'hCC, 0, 3, 0, 1, 0, 16'hA5A5, 0, 64, 40, 0, 0, 0, 0, 0, 0, 24'h001000, 0, 64, 0);
        model_job;
        d0 = n_done;
        @(negedge clk) start_run = 1'b1;
        @(negedge clk) start_run = 1'b0;
        repeat (300) @(negedge clk);
        stop = 1'b1;  @(negedge clk) stop = 1'b0;
        wait_idle;
        if (n_done - d0 != 1) fail("stop: done strobes", n_done - d0, 1);
        if (err) fail("stop: err", 1, 0);
        q = 0;
        for (a = 16'h1000; a < 16'h1000 + 64 * 40; a = a + 1) if (dm[a] !== mm[a]) q = q + 1;
        if (q == 0 || q >= 64 * 40 - 64) fail("stop: bytes left unwritten", q, 0);
        for (a = 0; a < 65536; a = a + 1) mm[a] = dm[a];                                                      // carry on from what was written
        clear_allowed;

        // ---- errors: a bad job, mask 3, and the mask image where it is not built; nothing is written
        wr0 = n_wr;
        set_job(8'hCC, 3, 3, 0, 1, 0, 16'h0000, 0, 16, 2, 0, 0, 0, 0, 0, 0, 24'h001000, 0, 64, 0);
        @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;  wait_idle;
        if (!err) fail("mask 3 is not an error", 0, 0);
        set_job(8'hCC, 0, 3, 0, 1, 0, 16'h0000, 0, 16, 2, 0, 0, 0, 0, 0, 0, 24'h001000, 0, 64, 0);
        jr[0][16] = 1'b1;
        @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;  wait_idle;
        if (!err) fail("job_bad is not an error", 0, 0);
        set_job(8'hCA, 1, 3, 0, 1, 0, 16'h0000, 0, 16, 2, 24'h003400, 0, 2, 0, 0, 0, 24'h001000, 0, 64, 0);
        if (MASKIMG == 0) begin
            @(negedge clk) start_run = 1'b1;  @(negedge clk) start_run = 1'b0;  wait_idle;
            if (!err) fail("mask 1 without MASKIMG is not an error", 0, 0);
        end
        if (n_wr != wr0) fail("an error job wrote", n_wr - wr0, 0);
        // ... and the next start clears the flag
        set_job(8'hCC, 0, 3, 0, 1, 0, 16'h3C3C, 0, 16, 2, 0, 0, 0, 0, 0, 0, 24'h001000, 0, 64, 0);  run;

        $display("LE=%0d MASKIMG=%0d: %0d jobs, %0d writes, %0d reads", LE, MASKIMG, n_jobs, n_wr, n_rd);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
