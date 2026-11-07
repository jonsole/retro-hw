// Unit test for dmx_core: directed jobs against a memory model.
// The testbench is the wrapper: it keeps each channel's job in plain
// arrays and puts the running channel's on the job ports while the core
// sets it up. Memory answers after a random wait, reads come back in order
// a few clocks later. Each job's result is checked byte by byte against a
// model of the pixels. Run with LE = 0 and LE = 1 (-DLE=1), LINE and
// EDGES built; and with them left out (-DLINES=0), where OP 2 and OP 3
// must be errors.
`timescale 1ns/1ps
`ifndef LE
`define LE 0
`endif
`ifndef LINES
`define LINES 1
`endif
module tb_dmx_core;
    localparam LE = `LE;
    localparam LINES = `LINES;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- the jobs, per channel
    reg [2:0]  c_op [0:3];   reg [7:0]  c_mt [0:3];   reg c_sat [0:3]; reg c_sgn [0:3];
    reg [1:0]  c_mask [0:3]; reg [1:0]  c_lb [0:3];   reg c_desc [0:3]; reg c_irq [0:3]; reg c_bc [0:3];
    reg        c_ymaj [0:3]; reg c_xneg [0:3]; reg c_yneg [0:3];
    reg [31:0] c_val [0:3];  reg [15:0] c_bstr [0:3]; reg [15:0] c_dstr [0:3];
    reg [23:0] c_w [0:3];    reg [15:0] c_h [0:3];
    reg [23:0] c_a [0:3];    reg [23:0] c_b [0:3];    reg [23:0] c_d [0:3];
    reg [2:0]  c_abit [0:3]; reg [2:0]  c_bbit [0:3]; reg [2:0]  c_dbit [0:3];
    reg [23:0] c_next [0:3]; reg c_bport [0:3]; reg c_dport [0:3];

    reg [2:0]  job_op;   reg [7:0]  job_minterm; reg job_sat, job_signed;
    reg [1:0]  job_mask, job_bpp; reg job_desc, job_irq, job_bconst, job_ymaj, job_xneg, job_yneg;
    reg [31:0] job_value; reg [15:0] job_bstride, job_dstride, job_height;
    reg [23:0] job_width, job_aaddr, job_baddr, job_daddr, job_next;
    reg [2:0]  job_abit, job_bbit, job_dbit; reg job_bport, job_dport;
    reg [15:0] clip_xmin = 16'h8000, clip_xmax = 16'h7FFF, clip_ymin = 16'h8000, clip_ymax = 16'h7FFF;

    reg  [3:0]  start_ld = 0, start_run = 0, stop = 0, clr_done = 0, clr_err = 0, pause = 0, da_we = 0;
    reg  [23:0] da_d = 0;
    wire [3:0]  busy, done, err, irq_set;
    wire [95:0] da_q, ea_q;
    wire        idle, su_v, dl_v;
    wire [1:0]  cur;
    wire [2:0]  su_i, dl_i;
    wire [15:0] dl_w0, dl_w1;

    // ---------------------------------------------------------------- memory: 16 KB on the memory port,
    // 2 KB on the other port at word 0x10000
    reg  [15:0] mem [0:8191];
    reg  [15:0] xmem [0:1023];
    wire        mem_req, mem_we, xp_req, xp_we;
    wire [21:1] mem_addr;
    wire [22:0] xp_addr, acc_a;
    wire [15:0] mem_wdata, xp_wdata;
    wire [1:0]  mem_be, xp_be;
    wire        acc_we;
    reg         gnt = 0, xgnt = 0;
    wire        mem_ack = mem_req && gnt;
    wire        xp_ack  = xp_req && xgnt;
    wire        xp_ok   = acc_a >= 23'h10000 && acc_a < 23'h10400;
    // reads back in order, 2-5 clocks after they are taken
    reg  [15:0] q_d [0:63];  reg [31:0] q_t [0:63];  reg q_x [0:63];
    integer     q_w = 0, q_r = 0, now = 0;
    reg         mem_rvalid = 0, xp_rvalid = 0;
    reg  [15:0] mem_rdata = 0, xp_rdata = 0;
    always @(posedge clk) begin
        now = now + 1;
        gnt  <= ($random & 3) != 0;
        xgnt <= ($random & 1) != 0;
        mem_rvalid <= 1'b0; xp_rvalid <= 1'b0;
        if (q_r != q_w && q_t[q_r % 64] <= now) begin
            if (q_x[q_r % 64]) begin xp_rvalid <= 1'b1; xp_rdata <= q_d[q_r % 64]; end
            else begin mem_rvalid <= 1'b1; mem_rdata <= q_d[q_r % 64]; end
            q_r = q_r + 1;
        end
        if (mem_ack) begin
            if (mem_addr >= 21'd8192) begin $display("FAIL: memory port address %h", mem_addr); $finish; end
            if (mem_we) begin
                if (mem_be[1]) mem[mem_addr][15:8] <= mem_wdata[15:8];
                if (mem_be[0]) mem[mem_addr][7:0]  <= mem_wdata[7:0];
            end else begin
                q_d[q_w % 64] = mem[mem_addr]; q_t[q_w % 64] = now + 1 + ($random & 3); q_x[q_w % 64] = 0;
                q_w = q_w + 1;
            end
        end
        if (xp_ack) begin
            if (xp_we) begin
                if (xp_be[1]) xmem[xp_addr - 23'h10000][15:8] <= xp_wdata[15:8];
                if (xp_be[0]) xmem[xp_addr - 23'h10000][7:0]  <= xp_wdata[7:0];
            end else begin
                q_d[q_w % 64] = xmem[xp_addr - 23'h10000]; q_t[q_w % 64] = now + 1 + ($random & 3); q_x[q_w % 64] = 1;
                q_w = q_w + 1;
            end
        end
    end

    // ---------------------------------------------------------------- the FIFO of a port job
    reg  [7:0] rxq [0:63]; integer rx_w = 0, rx_r = 0;
    reg  [7:0] txq [0:63]; integer tx_n = 0;
    reg        txr = 0;
    wire       p_rxpop, p_txpush;
    wire [7:0] p_txd;
    always @(posedge clk) begin
        txr <= ($random & 1) != 0;
        if (p_rxpop) rx_r <= rx_r + 1;
        if (p_txpush) begin txq[tx_n] = p_txd; tx_n = tx_n + 1; end
    end

    dmx_core #(.CHIP_WORDS(24'd8192), .LE(LE), .MASKIMG(1), .XPORT(1), .PORTJOB(1),
               .LINE(LINES), .EDGES(LINES)) dut (
        .clk(clk), .rst(rst),
        .enable(1'b1), .pause(pause), .start_ld(start_ld), .start_run(start_run), .stop(stop),
        .clr_done(clr_done), .clr_err(clr_err), .da_we(da_we), .da_d(da_d),
        .busy(busy), .done(done), .err(err), .da_q(da_q), .ea_q(ea_q), .irq_set(irq_set), .idle(idle), .cur(cur),
        .su_v(su_v), .su_i(su_i),
        .job_op(job_op), .job_minterm(job_minterm), .job_sat(job_sat), .job_signed(job_signed),
        .job_mask(job_mask), .job_bpp(job_bpp), .job_desc(job_desc), .job_irq(job_irq), .job_bconst(job_bconst),
        .job_ymaj(job_ymaj), .job_xneg(job_xneg), .job_yneg(job_yneg),
        .job_value(job_value), .job_bstride(job_bstride), .job_dstride(job_dstride),
        .job_width(job_width), .job_height(job_height),
        .job_aaddr(job_aaddr), .job_baddr(job_baddr), .job_daddr(job_daddr),
        .job_abit(job_abit), .job_bbit(job_bbit), .job_dbit(job_dbit), .job_next(job_next),
        .job_bport(job_bport), .job_dport(job_dport), .job_bad(1'b0),
        .clip_xmin(clip_xmin), .clip_xmax(clip_xmax), .clip_ymin(clip_ymin), .clip_ymax(clip_ymax),
        .dl_xok(1'b0), .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(1'b0),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .acc_a(acc_a), .acc_we(acc_we), .xp_ok(xp_ok),
        .xp_req(xp_req), .xp_we(xp_we), .xp_addr(xp_addr), .xp_wdata(xp_wdata), .xp_be(xp_be),
        .xp_ack(xp_ack), .xp_rvalid(xp_rvalid), .xp_rdata(xp_rdata),
        .p_rxv(rx_r != rx_w), .p_rxd(rxq[rx_r % 64]), .p_rxpop(p_rxpop), .p_txr(txr), .p_txpush(p_txpush), .p_txd(p_txd)
    );

    // The wrapper's part: the running channel's job onto the ports during
    // set-up; a loaded descriptor's long word 0 is VALUE, 1 DPT (this
    // testbench's own layout), and the loaded job has no next
    integer dl_n = 0;
    function [15:0] le16(input [15:0] w);       // a word as stored, as a little-endian number
        le16 = (LE != 0) ? w : {w[7:0], w[15:8]};
    endfunction
    function [7:0] lo8(input [15:0] w);
        lo8 = (LE != 0) ? w[7:0] : w[15:8];
    endfunction
    always @(posedge clk) begin
        if (su_v && su_i == 3'd0) begin
            job_op <= c_op[cur]; job_minterm <= c_mt[cur]; job_sat <= c_sat[cur]; job_signed <= c_sgn[cur];
            job_mask <= c_mask[cur]; job_bpp <= c_lb[cur]; job_desc <= c_desc[cur]; job_irq <= c_irq[cur];
            job_bconst <= c_bc[cur]; job_ymaj <= c_ymaj[cur]; job_xneg <= c_xneg[cur]; job_yneg <= c_yneg[cur];
            job_value <= c_val[cur]; job_bstride <= c_bstr[cur]; job_dstride <= c_dstr[cur];
            job_width <= c_w[cur]; job_height <= c_h[cur]; job_aaddr <= c_a[cur]; job_baddr <= c_b[cur];
            job_daddr <= c_d[cur]; job_abit <= c_abit[cur]; job_bbit <= c_bbit[cur]; job_dbit <= c_dbit[cur];
            job_next <= c_next[cur]; job_bport <= c_bport[cur]; job_dport <= c_dport[cur];
        end
        if (dl_v) begin
            dl_n = dl_n + 1;
            if (dl_i == 3'd0) c_val[cur] = {dl_w1, dl_w0};
            if (dl_i == 3'd1) c_d[cur]   = {lo8(dl_w1), le16(dl_w0)};
            c_next[cur] = 24'd0;
        end
    end

    // ---------------------------------------------------------------- the model
    integer fails = 0;
    reg [7:0] ref [0:16383];           // bytes, as they should end up
    reg [7:0] img [0:16383];           // bytes before the job
    function [7:0] rdb(input integer a);
        rdb = (LE != 0) == (a % 2 == 0) ? mem[a / 2][7:0] : mem[a / 2][15:8];
    endfunction
    task wrb(input integer a, input [7:0] v);
        if ((LE != 0) == (a % 2 == 0)) mem[a / 2][7:0] = v; else mem[a / 2][15:8] = v;
    endtask
    task wr16(input integer a, input [15:0] v);      // a 16-bit number, as the memory stores it
        if (LE != 0) begin wrb(a, v[7:0]); wrb(a + 1, v[15:8]); end
        else begin wrb(a, v[15:8]); wrb(a + 1, v[7:0]); end
    endtask
    task snap;
        integer a;
        for (a = 0; a < 16384; a = a + 1) begin img[a] = rdb(a); ref[a] = img[a]; end
    endtask
    // pixel at bit address ba (bits from the msb of byte 0), bpp bits
    function [7:0] getp(input integer ba, input integer bpp);
        reg [7:0] b;
        begin
            b = img[ba / 8];
            getp = (b >> (8 - (ba % 8) - bpp)) & ((1 << bpp) - 1);
        end
    endfunction
    task setp(input integer ba, input integer bpp, input [7:0] v);
        reg [7:0] m;
        begin
            m = ((1 << bpp) - 1) << (8 - (ba % 8) - bpp);
            ref[ba / 8] = (ref[ba / 8] & ~m) | ((v << (8 - (ba % 8) - bpp)) & m);
        end
    endtask
    function [7:0] mint(input [7:0] m, input [7:0] a, input [7:0] b, input [7:0] c);
        integer i;
        for (i = 0; i < 8; i = i + 1) mint[i] = m[{a[i], b[i], c[i]}];
    endfunction
    // The expected result of BLIT or ADD on channel ch (forwards order; the
    // tests keep sources and destinations apart, or copy as memmove would)
    task model(input integer ch);
        integer r, x, bpp, ba, bb, bd, bs, ds, ones;
        reg [7:0] a, b, c, d, key;
        reg [8:0] s;
        begin
            bpp = 1 << c_lb[ch]; ones = (1 << bpp) - 1;
            bs = $signed(c_bstr[ch]); ds = $signed(c_dstr[ch]);
            key = c_val[ch][7:0] & ones;
            for (r = 0; r < c_h[ch]; r = r + 1)
                for (x = 0; x < c_w[ch]; x = x + 1) begin
                    ba = (c_a[ch] + r * bs) * 8 + c_abit[ch] + x;
                    bb = (c_b[ch] + r * bs) * 8 + (c_bbit[ch] + x) * bpp;
                    bd = (c_d[ch] + r * ds) * 8 + (c_dbit[ch] + x) * bpp;
                    if (c_bc[ch]) begin
                        if (bpp == 8) b = LE ? c_val[ch][8 * ((c_d[ch] + r * ds + c_dbit[ch] + x) % 4) +: 8]
                                             : c_val[ch][8 * (3 - (c_d[ch] + r * ds + c_dbit[ch] + x) % 4) +: 8];
                        else b = c_val[ch][7:0] & ones;
                    end else b = getp(bb, bpp);
                    c = getp(bd, bpp);
                    a = (c_mask[ch] == 1) ? (getp(ba, 1) ? 8'hFF : 8'h00)
                      : (c_mask[ch] == 2) ? ((b != key) ? 8'hFF : 8'h00) : 8'hFF;
                    if (c_op[ch] == 1) begin
                        s = c + b;                      // unsigned saturating at bpp
                        d = (c_sat[ch] && s > ones) ? ones : s & ones;
                        if (a == 0) d = c;
                    end else d = mint(c_mt[ch], a, b, c) & ones;
                    setp(bd, bpp, d);
                end
        end
    endtask
    task check(input [8*24-1:0] name);
        integer a, n;
        begin
            n = 0;
            for (a = 0; a < 16384; a = a + 1)
                if (rdb(a) !== ref[a]) begin
                    if (n < 8) $display("  %0s: byte %h is %h, want %h (was %h)", name, a, rdb(a), ref[a], img[a]);
                    n = n + 1;
                end
            if (n != 0) begin fails = fails + 1; $display("FAIL %0s: %0d bytes wrong", name, n); end
            else $display("ok   %0s", name);
        end
    endtask

    task clear(input integer ch);
        begin
            c_op[ch] = 0; c_mt[ch] = 8'hCC; c_sat[ch] = 0; c_sgn[ch] = 0; c_mask[ch] = 0; c_lb[ch] = 3;
            c_desc[ch] = 0; c_irq[ch] = 0; c_bc[ch] = 0; c_ymaj[ch] = 0; c_xneg[ch] = 0; c_yneg[ch] = 0;
            c_val[ch] = 0; c_bstr[ch] = 0; c_dstr[ch] = 0; c_w[ch] = 0; c_h[ch] = 1;
            c_a[ch] = 0; c_b[ch] = 0; c_d[ch] = 0; c_abit[ch] = 0; c_bbit[ch] = 0; c_dbit[ch] = 0;
            c_next[ch] = 0; c_bport[ch] = 0; c_dport[ch] = 0;
        end
    endtask
    task go(input [3:0] chs);
        integer t;
        begin
            @(negedge clk) start_run = chs;
            @(negedge clk) start_run = 0;
            t = 0;
            while ((busy & chs) != 0 && t < 200000) begin @(negedge clk); t = t + 1; end
            if (t == 200000) begin $display("FAIL: channels %b still busy", busy & chs); $finish; end
            @(negedge clk) clr_done = 4'hF; @(negedge clk) clr_done = 0;
        end
    endtask
    task fillmem;
        integer a;
        for (a = 0; a < 8192; a = a + 1) mem[a] = $random;
    endtask

    integer i, n, t, x, y, e, ba, bd;
    initial begin
        for (i = 0; i < 4; i = i + 1) clear(i);
        for (i = 0; i < 1024; i = i + 1) xmem[i] = $random;
        fillmem;
        repeat (4) @(negedge clk); rst = 0;

        // ---- a fill at 8 bpp: VALUE's bytes by address
        clear(0); c_bc[0] = 1; c_val[0] = 32'h11223344; c_d[0] = 24'h101; c_w[0] = 37; c_h[0] = 3; c_dstr[0] = 64;
        snap; model(0); go(1); check("fill 8 bpp");
        // ---- copies at every depth, odd bit offsets: shifts and edge masks
        for (i = 0; i < 4; i = i + 1) begin
            clear(1); c_lb[1] = i; c_b[1] = 24'h400 + i; c_bbit[1] = 7 >> (3 - i);
            c_d[1] = 24'h2003 + i; c_dbit[1] = 5 >> (3 - i); if (i == 3) c_dbit[1] = 0;
            c_w[1] = 61 + 9 * i; c_h[1] = 4; c_bstr[1] = 80; c_dstr[1] = 96;
            snap; model(1); go(2);
            case (i) 0: check("copy 1 bpp"); 1: check("copy 2 bpp"); 2: check("copy 4 bpp"); default: check("copy 8 bpp"); endcase
        end
        // ---- minterms: XOR, AND NOT, and a constant
        clear(2); c_lb[2] = 0; c_mt[2] = 8'h66; c_b[2] = 24'h800; c_bbit[2] = 3; c_d[2] = 24'h1800; c_dbit[2] = 6;
        c_w[2] = 300; c_h[2] = 5; c_bstr[2] = 40; c_dstr[2] = 48;
        snap; model(2); go(4); check("minterm XOR");
        c_mt[2] = 8'h0C; c_lb[2] = 2; c_w[2] = 50; snap; model(2); go(4); check("minterm B AND NOT C");
        c_mt[2] = 8'hFF; c_lb[2] = 1; snap; model(2); go(4); check("minterm all ones");
        // ---- backwards, overlapping: a row moved 3 bytes on in place
        clear(3); c_desc[3] = 1; c_b[3] = 24'h3000; c_d[3] = 24'h3003; c_w[3] = 100; c_h[3] = 3;
        c_bstr[3] = 128; c_dstr[3] = 128;
        snap; model(3); go(8); check("backwards overlapping");
        clear(3); c_desc[3] = 1; c_lb[3] = 0; c_b[3] = 24'h3000; c_bbit[3] = 2; c_d[3] = 24'h3400; c_dbit[3] = 7;
        c_w[3] = 77; c_h[3] = 6; c_bstr[3] = 20; c_dstr[3] = 24;
        snap; model(3); go(8); check("backwards 1 bpp");
        // ---- key colour and mask image (cookie cut, 0xCA)
        clear(0); c_mask[0] = 2; c_mt[0] = 8'hCA; c_val[0] = 32'h5A; c_b[0] = 24'h500; c_d[0] = 24'h2801; c_w[0] = 40; c_h[0] = 3;
        c_bstr[0] = 64; c_dstr[0] = 64;
        for (i = 0; i < 120; i = i + 3) wrb(24'h500 + i, 8'h5A);
        snap; model(0); go(1); check("key colour 8 bpp");
        c_mask[0] = 1; c_a[0] = 24'h1000; c_abit[0] = 5; c_lb[0] = 2; c_bbit[0] = 1; c_dbit[0] = 3;
        snap; model(0); go(1); check("mask image 4 bpp");
        // ---- ADD, saturating
        clear(1); c_op[1] = 1; c_sat[1] = 1; c_b[1] = 24'h600; c_d[1] = 24'h2A00; c_w[1] = 33; c_h[1] = 2;
        c_bstr[1] = 64; c_dstr[1] = 64;
        snap; model(1); go(2); check("ADD saturating 8 bpp");
        // ---- four channels at once (round robin, set-up again on each return)
        clear(0); c_lb[0] = 0; c_b[0] = 24'h400; c_d[0] = 24'h2000; c_w[0] = 900; c_h[0] = 3; c_bstr[0] = 120; c_dstr[0] = 120;
        clear(1); c_bc[1] = 1; c_val[1] = 32'hA1B2C3D4; c_d[1] = 24'h2200; c_w[1] = 300; c_h[1] = 2; c_dstr[1] = 320;
        clear(2); c_lb[2] = 1; c_mt[2] = 8'h3C; c_b[2] = 24'h900; c_bbit[2] = 1; c_d[2] = 24'h2600; c_w[2] = 333; c_h[2] = 3;
        c_bstr[2] = 90; c_dstr[2] = 100;
        clear(3); c_desc[3] = 1; c_b[3] = 24'hC00; c_d[3] = 24'h2A00; c_w[3] = 250; c_h[3] = 2; c_bstr[3] = 256; c_dstr[3] = 256;
        snap; model(0); model(1); model(2); model(3); go(4'hF); check("four channels");

        // ---- from the other port
        clear(2); c_b[2] = 24'h20001; c_d[2] = 24'h3101; c_w[2] = 50; c_h[2] = 2; c_bstr[2] = 100; c_dstr[2] = 64;
        snap;
        for (y = 0; y < 2; y = y + 1)
            for (x = 0; x < 50; x = x + 1) begin
                n = 24'h20001 - 24'h20000 + y * 100 + x;
                ref[24'h3101 + y * 64 + x] = (LE != 0) == (n % 2 == 0) ? xmem[n / 2][7:0] : xmem[n / 2][15:8];
            end
        go(4); check("other port to memory");

        if (LINES) begin
        // ---- LINE at 8 bpp, x major, clipped at x = 8
        clear(0); c_op[0] = 2; c_val[0] = 32'hFFFFFFE7; c_mt[0] = 8'hCC; c_d[0] = 24'h3200; c_dstr[0] = 64;
        c_a[0] = 0; c_b[0] = 0; c_w[0] = 11; c_h[0] = 4;
        clip_xmax = 8;
        snap;
        x = 0; y = 0; e = 2 * 4 - 10;
        for (i = 0; i < 11; i = i + 1) begin
            if (x <= 8) ref[24'h3200 + y * 64 + x] = 8'hE7;
            x = x + 1;
            if (e > 0) begin y = y + 1; e = e + 2 * (4 - 10); end else e = e + 2 * 4;
        end
        go(1); check("LINE clipped");
        clip_xmax = 16'h7FFF;

        // ---- EDGES: one edge drawn, one wholly left of the clip rectangle
        clear(0); c_op[0] = 3; c_val[0] = 32'hFFFFFFFF; c_val[0][7:0] = 8'h3C; c_d[0] = 24'h3200; c_dstr[0] = 64;
        c_a[0] = 24'h3600; c_b[0] = 24'h3700; c_w[0] = 2;
        wr16(24'h3600, 2);  wr16(24'h3602, 1);     // point 0: (2, 1)
        wr16(24'h3604, 9);  wr16(24'h3606, 4);     // point 1: (9, 4)
        wr16(24'h3608, -10); wr16(24'h360A, 0);    // point 2: (-10, 0)
        wr16(24'h360C, -3); wr16(24'h360E, 2);     // point 3: (-3, 2)
        wrb(24'h3700, 0); wrb(24'h3701, 1);        // edge 0: points 0 and 1
        wrb(24'h3702, 2); wrb(24'h3703, 3);        // edge 1: points 2 and 3
        clip_xmin = 0;
        snap;
        x = 2; y = 1; e = 2 * 3 - 7;
        for (i = 0; i < 8; i = i + 1) begin
            ref[24'h3200 + y * 64 + x] = 8'h3C;
            x = x + 1;
            if (e > 0) begin y = y + 1; e = e + 2 * (3 - 7); end else e = e + 2 * 3;
        end
        go(1); check("EDGES");
        clip_xmin = 16'h8000;
        end else begin
        // ---- without LINE and EDGES, OP 2 and OP 3 are errors
        for (i = 2; i < 4; i = i + 1) begin
            clear(0); c_op[0] = i; c_w[0] = 4; c_h[0] = 1; c_d[0] = 24'h3200; c_dstr[0] = 64;
            @(negedge clk) da_we = 4'h1; da_d = 24'h0100 + i; @(negedge clk) da_we = 0;
            snap; go(1); check("no write");
            if (!err[0] || ea_q[23:0] != 24'h0100 + i) begin
                fails = fails + 1; $display("FAIL OP %0d left out: err %b at %h", i, err[0], ea_q[23:0]);
            end else $display("ok   OP %0d left out is an error", i);
            @(negedge clk) clr_err = 4'h1; @(negedge clk) clr_err = 0;
        end
        end

        // ---- port jobs: FIFO to memory, memory to FIFO
        clear(1); c_bport[1] = 1; c_d[1] = 24'h3301; c_w[1] = 21;
        for (i = 0; i < 21; i = i + 1) begin rxq[rx_w % 64] = 8'h40 + i; rx_w = rx_w + 1; end
        snap; for (i = 0; i < 21; i = i + 1) ref[24'h3301 + i] = 8'h40 + i;
        go(2); check("FIFO to memory");
        clear(1); c_dport[1] = 1; c_b[1] = 24'h3301; c_w[1] = 21; tx_n = 0;
        go(2);
        n = 0; for (i = 0; i < 21; i = i + 1) if (txq[i] !== 8'h40 + i) n = n + 1;
        if (n != 0 || tx_n != 21) begin fails = fails + 1; $display("FAIL memory to FIFO: %0d sent, %0d wrong", tx_n, n); end
        else $display("ok   memory to FIFO");

        // ---- a descriptor load, chained from a fill: VALUE and DPT from the descriptor
        clear(2); c_bc[2] = 1; c_val[2] = 32'h01010101; c_d[2] = 24'h3400; c_w[2] = 8; c_next[2] = 24'h3500; c_irq[2] = 1;
        for (i = 0; i < 32; i = i + 1) wrb(24'h3500 + i, 8'h00);
        wrb(24'h3500, 8'h77); wrb(24'h3501, 8'h77); wrb(24'h3502, 8'h77); wrb(24'h3503, 8'h77);   // VALUE
        wrb(24'h3504, 8'h10); wrb(24'h3505, 8'h34); wrb(24'h3506, 8'h00);                     // DPT 0x3410
        snap; for (i = 0; i < 8; i = i + 1) begin ref[24'h3400 + i] = 8'h01; ref[24'h3410 + i] = 8'h77; end
        dl_n = 0; t = 0;
        fork go(4); begin while (busy[2] || t == 0) begin @(negedge clk); if (irq_set[2]) t = t + 1; end end join
        check("descriptor chain");
        if (dl_n != 8 || da_q[71:48] != 24'h3500 || t != 2) begin
            fails = fails + 1; $display("FAIL descriptor load: %0d long words, address %h, %0d interrupts", dl_n, da_q[71:48], t);
        end

        // ---- errors: past the memory, and a bad op
        clear(3); c_bc[3] = 1; c_d[3] = 24'h8000; c_w[3] = 4;
        go(8);
        if (!err[3] || ea_q[95:72] != 24'h8000) begin fails = fails + 1; $display("FAIL bad address: err %b at %h", err[3], ea_q[95:72]); end
        else $display("ok   bad address");
        @(negedge clk) clr_err = 4'h8; @(negedge clk) clr_err = 0;
        clear(3); c_op[3] = 5; c_w[3] = 4;
        @(negedge clk) da_we = 4'h8; da_d = 24'h1234; @(negedge clk) da_we = 0;
        go(8);
        if (!err[3] || ea_q[95:72] != 24'h1234) begin fails = fails + 1; $display("FAIL bad op: err %b at %h", err[3], ea_q[95:72]); end
        else $display("ok   bad op");

        if (fails == 0) $display("TEST PASSED (LE=%0d LINES=%0d)", LE, LINES);
        else $display("TEST FAILED: %0d (LE=%0d LINES=%0d)", fails, LE, LINES);
        $finish;
    end
endmodule
