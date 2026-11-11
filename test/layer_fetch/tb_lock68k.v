`timescale 1ns/1ps
// layer_fetch in lockstep with retro68k's bpldma.v (ref/bpldma_68k.v):
// the same random line settings, register writes, takes and memory, and
// every clock the two must agree on dat, fill_t, req, addr, line_go
// and line_gen. urgent is checked against the reference's
// compare made with the deadline of the clock before and the mark + 1
// (spec 4.4). Allowed differences (spec 6): line_t reaches the reference
// a clock later, as the core has one more synchroniser flop; the core has
// no restart on a BPLDMA write, so those are made only in line_go clocks;
// pointers are loaded before the first line; depth, planar and scale
// change only in the line's first clock (the core takes them per group);
// the core's line-end resets (revision 4) are given to the reference as
// pointer writes and copies in the same clocks, and the pointers are not
// compared (the reference moves them at the last word, the core at line_go).
//
// The register-file side of retro68k's bpldma (byte merging, BPLDMA's
// set/clear, BPLSTRIDE) is modelled here, as the machine's wrapper would.
module tb_lock68k;
    localparam NL = 3, PW = 23, AW = 21;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // Shared stimulus
    reg          enable = 1'b1;
    reg          line_t_c = 1'b0, line_t_r = 1'b0;
    reg  [2:0]   act = 0, adv = 0, chunky = 0, take_t = 0;
    reg  [8:0]   planes = 0;
    reg  [5:0]   hscale = 0;
    reg  [11:0]  wrap = 0;
    reg  [35:0]  ngroups = 0;
    reg          ack = 0, rvalid = 0;
    reg  [15:0]  rdata = 0;

    // The machine's register file, mirrored for the reference and the core
    reg  [15:0]  mod [0:2];
    reg  [7:0]   pm  [0:2];
    wire [47:0]  stride = {mod[2], mod[1], mod[0]};
    wire [23:0]  dma_en = {pm[2], pm[1], pm[0]};

    // The reference's bus
    reg          rb_wr = 0;
    reg  [23:2]  rb_addr = 0;
    reg  [31:0]  rb_wdata = 0;
    reg  [3:0]   rb_be = 0;
    wire [31:0]  rb_rdata;

    // The core's ports
    reg          ptr_wr = 0, dat_wr = 0;
    reg  [4:0]   ptr_sel = 0, dat_sel = 0;
    reg  [22:0]  ptr_wv = 0;               // the bytes being written ...
    reg  [2:0]   ptr_be = 0;               // ... and which
    wire [22:0]  ptr_rdata;
    wire [22:0]  ptr_wdata = {ptr_be[2] ? ptr_wv[22:16] : ptr_rdata[22:16],
                              ptr_be[1] ? ptr_wv[15:8]  : ptr_rdata[15:8],
                              ptr_be[0] ? ptr_wv[7:1]   : ptr_rdata[7:1], 1'b0};
    reg  [15:0]  dat_wdata = 0;
    reg  [1:0]   dat_be = 0;
    wire [15:0]  dat_rdata;

    wire         r_go, r_gen, r_req, r_urg, c_go, c_gen, c_req, c_urg;

    // Revision 4: the core resets every pointer the ended line fetched at
    // line_go, one a clock while its stage A waits; the reference moves a
    // pointer at its last word instead. So the reference gets a same-value
    // pointer write on its bus in each clock of the core's resets (a write
    // holds its stage A too), and each pointer the core resets is copied
    // into it (below). Both then start every line from the same pointers,
    // and every address is compared; the pointers themselves differ between
    // the reference's last word and line_go, so they are not compared (the
    // line-end rule is tb_model's). The machine's own writes are held off
    // while the resets run.
    wire         cu_on   = dut.cu_act || dut.c_v;
    wire [4:0]   cu_q    = dut.cu_q;
    wire [23:0]  cu_ra   = 24'hE00100 + {19'd0, cu_q[4:3]} * 24'h80 + 24'h20 + {21'd0, cu_q[2:0]} * 24'h4;
    // A partial pointer write is merged with the pointer as it is; from the
    // reference's last word to line_go the two hold different values, so a
    // partial write lands only while they agree (dropped from both if not).
    // A whole pointer (a split screen) lands any time.
    wire         pb_ok     = ptr_be == 3'b111 || dut.pt[ptr_sel] == ref.pt[ptr_sel];
    wire         ptr_wr_g  = ptr_wr && pb_ok;
    // A data-register write is held in the core and stored on the first
    // clock with no fetched word (its one write port). The reference stores
    // a write in the clock it gets it, so it is given each one in the clock
    // the core stores it (h_go), on its bus. The bench sends nothing else
    // while a write is held, and no data write close to a line's end, so
    // the bus is free then.
    wire         h_go      = dut.h_go;
    wire [23:0]  h_ra      = 24'hE00100 + {19'd0, dut.h_sel[4:3]} * 24'h80 + 24'h40 + {21'd0, dut.h_sel[2:0]} * 24'h4;
    wire         ref_wr    = cu_on ? 1'b1 : h_go ? 1'b1 : (rb_wr && !dat_wr && !(ptr_wr && !pb_ok));
    wire [23:2]  ref_addr  = cu_on ? cu_ra[23:2] : h_go ? h_ra[23:2] : rb_addr;
    wire [31:0]  ref_wdata = cu_on ? {9'd0, ref.pt[cu_q]} : h_go ? {16'd0, dut.h_d} : rb_wdata;
    wire [3:0]   ref_be    = cu_on ? 4'b0111 : h_go ? {2'b00, dut.h_be} : rb_be;
    integer      n_land = 0, n_hold = 0;
    always @(posedge clk) if (!rst) begin
        if (h_go) n_land = n_land + 1;
        if (dut.h_v && !h_go) n_hold = n_hold + 1;
        if (h_go && cu_on) begin $display("ERROR: the bench let a held write land during the line-end resets"); $finish; end
    end
    integer      n_cu = 0, cp_q = -1;
    always @(posedge clk) begin
        cp_q = dut.c2_wr ? dut.c_q : -1;
        if (cp_q >= 0) n_cu = n_cu + 1;
    end
    always @(negedge clk) if (cp_q >= 0) begin ref.pt[cp_q] = dut.pt[cp_q];  ref.svm[cp_q] = dut.pt[cp_q]; end
    wire [9:0]   r_dl;
    wire [383:0] r_dat, c_dat;
    wire [2:0]   r_fill, c_fill;
    wire [21:1]  r_addr;
    wire [20:0]  c_addr;
    wire [29:0]  c_attr;

    bpldma_68k ref (
        .clk(clk), .rst(rst), .enable(enable),
        .rb_rd(1'b0), .rb_wr(ref_wr), .rb_addr(ref_addr), .rb_wdata(ref_wdata), .rb_be(ref_be), .rb_rdata(rb_rdata),
        .line_t(line_t_r), .act(act), .adv(adv), .planes(planes), .chunky(chunky), .hscale(hscale),
        .wrap(wrap), .ngroups(ngroups), .line_go(r_go), .line_gen(r_gen), .dat(r_dat),
        .fill_t(r_fill), .take_t(take_t), .req(r_req), .urgent(r_urg), .deadline(r_dl), .addr(r_addr),
        .ack(ack), .rvalid(rvalid), .rdata(rdata));

    layer_fetch #(.NL(NL), .AW(AW), .PW(PW), .PLANAR(1), .TILES(0), .DATWRITE(1), .LITTLE(0),
                  .URG_BASE(15), .URG_WORD(5)) dut (
        .clk(clk), .rst(rst), .enable(enable),
        .line_t(line_t_c), .line_go(c_go), .line_gen(c_gen),
        .act(act), .adv(adv), .depth(planes), .planar(~chunky), .hscale(hscale), .wrap(wrap),
        .stride(stride), .ngroups(ngroups),
        .tile(3'd0), .mapw(6'd0), .ty(30'd0), .tcol(21'd0), .mappt({3*PW{1'b0}}), .patpt({3*PW{1'b0}}),
        .ptr_sel(ptr_sel), .ptr_wr(ptr_wr_g), .ptr_wdata(ptr_wdata), .ptr_rdata(ptr_rdata),
        .dat_wr(dat_wr), .dat_sel(dat_sel), .dat_wdata(dat_wdata), .dat_be(dat_be), .dma_en(dma_en),
        .dat_rdata(dat_rdata), .dat(c_dat), .attr(c_attr), .fill_t(c_fill), .take_t(take_t),
        .req(c_req), .urgent(c_urg), .addr(c_addr), .ack(ack), .rvalid(rvalid), .rdata(rdata));

    // ---------------------------------------------------------------- memory and scheduler
    // A cycle every other clock; the reference's request gets one as the
    // memory's business allows. ack the clock after; read data 3 clocks after.
    reg        sn = 0;
    reg [2:0]  rv_pipe = 0;
    reg [20:0] a_pipe [0:2];
    // How busy the memory is changes every few hundred clocks: the display
    // gets 1 cycle in 5, 1 in 2, 4 in 5, or every one
    reg [1:0]  busy_mode = 2'd2;
    reg [8:0]  busy_left = 0;
    reg        grant;
    always @(posedge clk) begin
        if (busy_left == 9'd0) begin busy_mode <= {$random} % 4; busy_left <= 100 + ({$random} % 400); end
        else busy_left <= busy_left - 1'b1;
        case (busy_mode)
            2'd0: grant = ({$random} % 5 == 0);
            2'd1: grant = ({$random} % 2 == 0);
            2'd2: grant = ({$random} % 5 != 0);
            default: grant = 1'b1;
        endcase
    end
    function [15:0] hash(input [20:0] a);
        hash = {a[20:13] ^ a[7:0] ^ 8'h5A, a[12:5] ^ {a[4:0], a[20:18]} ^ 8'hC3} ^ {a[2:0], a[15:3]};
    endfunction
    always @(posedge clk) begin
        sn <= ~sn;
        ack <= sn && r_req && grant;
        rv_pipe <= {rv_pipe[1:0], ack};
        a_pipe[0] <= r_addr;  a_pipe[1] <= a_pipe[0];  a_pipe[2] <= a_pipe[1];
        rvalid <= rv_pipe[2];
        rdata  <= hash(a_pipe[2]);
    end

    // ---------------------------------------------------------------- the pixel side
    // A stand-in for layer_pix: takes a full group after a while, roughly a
    // group's time at the layer's scale, sometimes much sooner or later
    reg [7:0] tk_wait [0:2];
    integer i, m;
    always @(posedge clk) if (!rst)
        for (m = 0; m < 3; m = m + 1) begin
            if (r_fill[m] != take_t[m]) begin
                if (tk_wait[m] == 8'd0) begin
                    take_t[m] <= ~take_t[m];
                    tk_wait[m] <= ({$random} % 4 == 0) ? {$random} % 200 : 8'd30 + ({$random} % 8);
                end else tk_wait[m] <= tk_wait[m] - 1'b1;
            end
        end

    // ---------------------------------------------------------------- the lines and the register writes
    integer   cyc = 0, line = 0, lines_left = 0;
    reg       dma_pending = 0;
    reg [1:0] wsel = 0;
    reg [31:0] r;
    integer   j, ld = 0;                       // ld: pointers still to load before the first line
    // Issue a reference write and its mirror. kind: 0 pointer, 1 stride, 2 BPLDMA, 3 data
    reg [23:0] ra;
    task write(input [1:0] kind, input [1:0] layer, input [2:0] plane, input [31:0] data, input [3:0] be);
        begin
            rb_wr    <= 1'b1;
            rb_wdata <= data;
            rb_be    <= be;
            case (kind)
                2'd0: begin
                    ra = 24'hE00100 + layer * 24'h80 + 24'h20 + plane * 24'h4;  rb_addr <= ra[23:2];
                    ptr_wr  <= 1'b1;  ptr_sel <= {layer, plane};  ptr_wv <= data[22:0];  ptr_be <= be[2:0];
                end
                2'd1: begin ra = 24'hE00100 + layer * 24'h80 + 24'h10;  rb_addr <= ra[23:2]; end
                2'd2: begin ra = 24'hE00100 + layer * 24'h80 + 24'h14;  rb_addr <= ra[23:2]; end
                default: begin
                    ra = 24'hE00100 + layer * 24'h80 + 24'h40 + plane * 24'h4;  rb_addr <= ra[23:2];
                    dat_wr  <= 1'b1;  dat_sel <= {layer, plane};  dat_wdata <= data[15:0];  dat_be <= be[1:0];
                end
            endcase
        end
    endtask

    // The machine's register file takes a bus write at the edge that ends
    // its clock, as the reference does (its decode is borrowed here)
    always @(posedge clk) begin
        if (rst) begin
            for (j = 0; j < 3; j = j + 1) begin mod[j] <= 16'd0; pm[j] <= 8'hFF; end
        end else if (rb_wr) begin
            if (ref.sel_mod) begin
                if (rb_be[1]) mod[ref.rn][15:8] <= rb_wdata[15:8];
                if (rb_be[0]) mod[ref.rn][7:1]  <= rb_wdata[7:1];
                mod[ref.rn][0] <= 1'b0;
            end
            if (ref.sel_dma && rb_be[1:0] == 2'b11)
                pm[ref.rn] <= rb_wdata[15] ? (pm[ref.rn] | rb_wdata[7:0]) : (pm[ref.rn] & ~rb_wdata[7:0]);
        end
    end

    always @(posedge clk) begin
        cyc <= cyc + 1;
        rb_wr  <= 1'b0;  ptr_wr <= 1'b0;  dat_wr <= 1'b0;
        line_t_r <= line_t_c;
        dma_pending <= (line_t_c != line_t_r);                  // the next clock is the line_go clock
        if (rst) begin
            ld <= 48;
        end else if (ld != 0) begin
            // Load every pointer in both before the first line (the core's are not reset)
            ld <= ld - 1;
            if (ld[0]) write(2'd0, (48 - ld) / 16, ((48 - ld) / 2) % 8, ((48 - ld) / 2) * 32'h1234 + 32'h1000, 4'b0111);
        end else begin
            // Pointer and data registers read back in turn (compared below)
            if (!ptr_wr) ptr_sel <= ptr_sel + 1'b1;
            dat_sel <= dat_sel + 1'b1;
            r = $random;
            if (lines_left == 0) begin
                // A new line: toggle line_t, and new settings for it. Depth
                // and planar change only here (spec 6: the reference
                // registers its enables a clock later than the core)
                line_t_c   <= ~line_t_c;                       
                lines_left <= 300 + ({$random} % 700);
                line       <= line + 1;
            end else begin
                if (dma_pending) begin
                    // The line's settings, in the line_go clock: the core takes
                    // depth, planar and scale per group (revision 2), the
                    // reference per line or live, so they change only here
                    for (j = 0; j < 3; j = j + 1) begin
                        act[j]      <= (r[2*j +: 2] != 2'd0);
                        adv[j]      <= r[6+j];
                        chunky[j]   <= r[9+j];
                        planes[3*j +: 3] <= r[9+j] ? (r[12+2*j +: 2] == 2'd0 ? 3'd0 : r[12+2*j +: 2] == 2'd1 ? 3'd1 :
                                                      r[12+2*j +: 2] == 2'd2 ? 3'd3 : 3'd7)
                                                   : {$random} % 8;
                        hscale[2*j +: 2] <= (r[18+j]) ? 2'd0 : {$random} % 4;
                        ngroups[12*j +: 12] <= r[21+j] ? 12'd0 : 12'd1 + ({$random} % 40);
                    end
                end
                lines_left <= lines_left - 1;
                // Sometimes a live setting changes mid-line
                if (r[7:0] == 8'd2) begin j = {$random} % 3; wrap[4*j +: 4] <= ({$random} % 2) ? 4'd0 : 4'd1 + ({$random} % 6); end
                if (r[7:0] == 8'd3) begin j = {$random} % 3; act[j] <= ~act[j]; end
                if (r[7:0] == 8'd4) begin j = {$random} % 3; ngroups[12*j +: 12] <= 12'd1 + ({$random} % 40); end
                if (r[7:0] == 8'd5) enable <= ~enable;
            end
            // Register writes: one a clock at most. BPLDMA only in the line_go
            // clock. None while the core's line-end resets may run (above).
            if (dut.line_go || dut.cu_act || dut.c_v || dat_wr || (dut.h_v && !dut.h_go)) ;
            else if (dma_pending && r[9:8] != 2'd0)
                write(2'd2, {$random} % 3, 3'd0, {$random} & 32'h0000_80FF, 4'b0011);
            else if (!dma_pending && r[12:8] == 5'd0)                                // a whole pointer, often just below a wrap block's end
                write(2'd0, {$random} % 3, {$random} % 8, r[13] ? ({$random} & 32'hFFFFC00) | 32'h3F0 | ({$random} & 32'hE) : $random, 4'b0111);
            else if (!dma_pending && r[12:8] == 5'd1)
                write(2'd0, {$random} % 3, {$random} % 8, $random, 4'd1 << ({$random} % 3));   // one byte of one
            else if (!dma_pending && r[12:8] == 5'd2)
                write(2'd1, {$random} % 3, 3'd0, $random, {2'b00, r[14:13] == 2'd0 ? 2'b01 : r[14:13] == 2'd1 ? 2'b10 : 2'b11});
            else if (!dma_pending && r[12:8] == 5'd3 && lines_left > 6)
                write(2'd3, {$random} % 3, {$random} % 8, $random, {2'b00, r[16:15] == 2'd0 ? 2'b01 : r[16:15] == 2'd1 ? 2'b10 : 2'b11});
        end
    end

    // ---------------------------------------------------------------- checks
    integer d;
    integer errors = 0, checks = 0, n_req = 0, n_urg = 0, n_fill = 0, n_ptrw = 0, n_datw = 0, n_datfill = 0;
    reg [9:0] prev_dl [0:2];
    reg [3:0] wl;
    reg [7:0] rr;
    reg       exp_urg;
    task fail(input [8*12-1:0] what, input [63:0] got, input [63:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("ERROR @%0d line %0d: %0s: core %h, reference %h", cyc, line, what, got, want);
        end
    endtask
`ifdef DBG
    always @(negedge clk) if (cyc >= `DBG && cyc < `DBG + 70)
        $display("%0d go%b act%b ch%b pl%h pm%h%h%h | pw%b sel%h | want r%b c%b pick r%0d c%0d ph r%b c%b a_pi r%h c%h ago r%b c%b bgo r%b c%b | req%b/%b addr r%h c%h | rem r%h%h%h c%h%h%h | dl r%h %h %h",
                 cyc, r_go, act, chunky, planes, pm[2], pm[1], pm[0], ptr_wr, ptr_sel,
                 ref.want, dut.want, ref.pick, dut.pick, ref.phase, dut.phase, ref.a_pi, dut.a_pi, ref.a_go, dut.a_go, ref.b_go, dut.b_go,
                 c_req, r_req, r_addr, c_addr, ref.rem[2], ref.rem[1], ref.rem[0], dut.rem[2][9:2], dut.rem[1][9:2], dut.rem[0][9:2], ref.dl[2], ref.dl[1], ref.dl[0]);
`endif
    always @(negedge clk) if (!rst) begin
        checks = checks + 1;
        if (c_go  !== r_go)  fail("line_go", c_go, r_go);
        if (c_gen !== r_gen) fail("line_gen", c_gen, r_gen);
        if (c_dat !== r_dat) begin
            for (i = 23; i >= 0; i = i - 1) if (c_dat[16*i +: 16] !== r_dat[16*i +: 16]) d = i;
            fail("dat", {d[7:0], c_dat[16*d +: 16]}, {d[7:0], r_dat[16*d +: 16]});   // register (layer x 8 + r), value
        end
        if (c_fill !== r_fill) fail("fill_t", c_fill, r_fill);
        if (c_req !== r_req) fail("req", c_req, r_req);
        if (r_req && c_addr !== r_addr) fail("addr", c_addr, r_addr);
        if (dat_sel < 5'd24 && dat_rdata !== ref.dr[dat_sel]) fail("dat_rdata", dat_rdata, ref.dr[dat_sel]);
        // urgent: the reference's compare, with the words left now and the
        // deadline of the clock before, against the mark + 1
        wl = 4'd1;
        rr = ref.rem[ref.req_layer];
        for (i = 0; i < 8; i = i + 1) wl = wl + {3'd0, rr[i]};
        exp_urg = r_req && (prev_dl[ref.req_layer] < 10'd15 + {wl, 2'b00} + wl);
        if (c_urg !== exp_urg) fail("urgent", c_urg, exp_urg);
        for (i = 0; i < 3; i = i + 1) prev_dl[i] = ref.dl[i];
        if (r_req) n_req = n_req + 1;
        if (exp_urg) n_urg = n_urg + 1;
        if (c_fill != 3'd0) n_fill = n_fill + 1;
        if (ptr_wr) n_ptrw = n_ptrw + 1;
        if (dat_wr) n_datw = n_datw + 1;
        if (dut.dw_fills) n_datfill = n_datfill + 1;
    end

    initial begin
        for (m = 0; m < 3; m = m + 1) begin tk_wait[m] = 0; prev_dl[m] = 10'h3FF; end
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        repeat (`ifdef SHORT 20000 `else 600000 `endif) @(posedge clk);
        @(negedge clk);
        $display("%0d clocks, %0d lines: %0d requests, %0d urgent, %0d full, %0d pointer writes, %0d data writes (%0d completing a group), %0d pointer resets copied",
                 checks, line, n_req, n_urg, n_fill, n_ptrw, n_datw, n_datfill, n_cu);
        $display("data-register writes: %0d sent, %0d stored, %0d clocks one waited for a fetched word", n_datw, n_land, n_hold);
        if (n_datw != n_land + (dut.h_v ? 1 : 0)) begin
            errors = errors + 1;
            $display("ERROR: a data-register write was lost");
        end
        if (n_hold == 0) begin
            errors = errors + 1;
            $display("ERROR: no write ever waited for a fetched word");
        end
        if (n_req < 1000 || n_urg == 0 || n_fill == 0 || n_ptrw == 0 || n_datw == 0 || n_datfill == 0 || n_cu == 0) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
