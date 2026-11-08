`timescale 1ns/1ps
// layer_fetch in lockstep with retro-z80's bpldma.v (ref/bpldma_z80.v):
// tile layers, little-endian words, 22-bit pointers, the urgent mark one
// cycle earlier. The same random settings, byte register writes, takes and
// memory for both; every clock they must agree on dat, attr, fill_t, req,
// addr, line_go, line_gen and the pointers. urgent is checked against the
// reference's compare made with the deadline of the clock before and the
// mark + 1 (spec 4.4). Allowed differences (spec 6): line_t reaches the
// reference a clock later (the core has one more synchroniser flop), and
// the pointers are loaded before the first line.
//
// The register-file side of retro-z80's bpldma (byte registers, the
// pointer capture) is modelled here, as the machine's wrapper would.
module tb_lockz80;
    localparam NL = 3, PW = 22, AW = 21;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg          enable = 1'b1;
    reg          line_t_c = 1'b0, line_t_r = 1'b0;
    reg  [2:0]   act = 0, adv = 0, tile = 0, take_t = 0;
    reg  [5:0]   lbpp = 0, hscale = 0, mapw = 0;
    reg  [11:0]  wrap = 0;
    reg  [35:0]  ngroups = 0;
    reg  [29:0]  ty = 0;
    reg  [20:0]  tcol = 0;
    reg          ack = 0, rvalid = 0;
    reg  [15:0]  rdata = 0;
    wire [8:0]   depth = {lbpp[5:4] == 2'd0 ? 3'd0 : lbpp[5:4] == 2'd1 ? 3'd1 : lbpp[5:4] == 2'd2 ? 3'd3 : 3'd7,
                          lbpp[3:2] == 2'd0 ? 3'd0 : lbpp[3:2] == 2'd1 ? 3'd1 : lbpp[3:2] == 2'd2 ? 3'd3 : 3'd7,
                          lbpp[1:0] == 2'd0 ? 3'd0 : lbpp[1:0] == 2'd1 ? 3'd1 : lbpp[1:0] == 2'd2 ? 3'd3 : 3'd7};

    // The machine's register file, mirrored for the core
    reg  [15:0]  mod   [0:2];
    reg  [21:0]  mappt [0:2], patpt [0:2];
    wire [47:0]  stride   = {mod[2], mod[1], mod[0]};
    wire [65:0]  mappt_p  = {mappt[2], mappt[1], mappt[0]};
    wire [65:0]  patpt_p  = {patpt[2], patpt[1], patpt[0]};

    // The reference's 8-bit bus
    reg          rb_wr = 0;
    reg  [12:0]  rb_addr = 0;
    reg  [7:0]   rb_wdata = 0;
    wire [7:0]   rb_rdata;
    wire         rb_hit, rb_cap;
    wire [31:0]  rb_cdata;

    // The core's ports
    reg          ptr_wr = 0;
    reg  [4:0]   ptr_sel = 0;
    reg  [21:0]  ptr_wv = 0;
    reg  [2:0]   ptr_be = 0;
    wire [21:0]  ptr_rdata;
    wire [21:0]  ptr_wdata = {ptr_be[2] ? ptr_wv[21:16] : ptr_rdata[21:16],
                              ptr_be[1] ? ptr_wv[15:8]  : ptr_rdata[15:8],
                              ptr_be[0] ? ptr_wv[7:1]   : ptr_rdata[7:1], 1'b0};

    wire         r_go, r_gen, r_req, r_urg, c_go, c_gen, c_req, c_urg;
    wire [9:0]   r_dl;
    wire [383:0] r_dat, c_dat;
    wire [29:0]  r_attr, c_attr;
    wire [2:0]   r_fill, c_fill;
    wire [21:1]  r_addr;
    wire [20:0]  c_addr;
    wire [15:0]  dat_rdata;

    bpldma_z80 #(.NL(3)) ref (
        .clk(clk), .rst(rst), .enable(enable),
        .rb_rd(1'b0), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_rdata(rb_rdata),
        .rb_hit(rb_hit), .rb_cdata(rb_cdata), .rb_cap(rb_cap),
        .line_t(line_t_r), .act(act), .adv(adv), .lbpp(lbpp), .hscale(hscale), .wrap(wrap), .ngroups(ngroups),
        .tile(tile), .mapw(mapw), .ty(ty), .tcol(tcol),
        .line_go(r_go), .line_gen(r_gen), .dat(r_dat), .attr(r_attr), .fill_t(r_fill), .take_t(take_t),
        .req(r_req), .urgent(r_urg), .deadline(r_dl), .addr(r_addr), .ack(ack), .rvalid(rvalid), .rdata(rdata));

    layer_fetch #(.NL(NL), .AW(AW), .PW(PW), .PLANAR(0), .TILES(1), .DATWRITE(0), .LITTLE(1),
                  .URG_BASE(17), .URG_WORD(5)) dut (
        .clk(clk), .rst(rst), .enable(enable),
        .line_t(line_t_c), .line_go(c_go), .line_gen(c_gen),
        .act(act), .adv(adv), .depth(depth), .planar(3'd0), .hscale(hscale), .wrap(wrap),
        .stride(stride), .ngroups(ngroups),
        .tile(tile), .mapw(mapw), .ty(ty), .tcol(tcol), .mappt(mappt_p), .patpt(patpt_p),
        .ptr_sel(ptr_sel), .ptr_wr(ptr_wr), .ptr_wdata(ptr_wdata), .ptr_rdata(ptr_rdata),
        .dat_wr(1'b0), .dat_sel(5'd0), .dat_wdata(16'd0), .dat_be(2'd0), .dma_en(24'hFFFFFF),
        .dat_rdata(dat_rdata), .dat(c_dat), .attr(c_attr), .fill_t(c_fill), .take_t(take_t),
        .req(c_req), .urgent(c_urg), .addr(c_addr), .ack(ack), .rvalid(rvalid), .rdata(rdata));

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

    // ---------------------------------------------------------------- the pixel side
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

    // ---------------------------------------------------------------- the register file
    // A bus write lands at the edge that ends its clock, as in the reference
    // (whose decode is borrowed). Layer n at 0x1090 + n x 0x20.
    integer j, ld = 0;
    always @(posedge clk) begin
        if (rst) begin
            for (j = 0; j < 3; j = j + 1) begin mod[j] <= 16'd0; mappt[j] <= 22'd0; patpt[j] <= 22'd0; end
        end else if (rb_wr) begin
            if (ref.sel_mod) begin
                if (ref.off == 5'h10) mod[ref.rn][7:1]  <= rb_wdata[7:1];
                else                  mod[ref.rn][15:8] <= rb_wdata;
            end
            if (ref.sel_map) case (ref.off)
                5'h18:   mappt[ref.rn][7:1]   <= rb_wdata[7:1];
                5'h19:   mappt[ref.rn][15:8]  <= rb_wdata;
                default: mappt[ref.rn][21:16] <= rb_wdata[5:0];
            endcase
            if (ref.sel_pat) case (ref.off)
                5'h1C:   patpt[ref.rn][7:1]   <= rb_wdata[7:1];
                5'h1D:   patpt[ref.rn][15:8]  <= rb_wdata;
                default: patpt[ref.rn][21:16] <= rb_wdata[5:0];
            endcase
        end
    end
    // A byte write to the reference, mirrored to the core where it is a
    // pointer byte. off: 0x10-11 stride, 0x14-16 BPL0PT, 0x18-1A MAPPT, 0x1C-1E PATPT
    task write(input [1:0] layer, input [4:0] off, input [7:0] data);
        begin
            rb_wr    <= 1'b1;
            rb_wdata <= data;
            rb_addr  <= 13'h1090 + layer * 13'h20 + off;
            if (off >= 5'h14 && off <= 5'h16) begin
                ptr_wr  <= 1'b1;
                ptr_sel <= {layer, 3'd0};
                ptr_be  <= (off == 5'h14) ? 3'b001 : (off == 5'h15) ? 3'b010 : 3'b100;
                ptr_wv  <= {data[5:0], data, data};
            end
        end
    endtask

    // ---------------------------------------------------------------- the lines and the writes
    integer   cyc = 0, line = 0, lines_left = 0;
    reg [31:0] r;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        rb_wr  <= 1'b0;  ptr_wr <= 1'b0;
        line_t_r <= line_t_c;
        if (rst) begin
            ld <= 18;
        end else if (ld != 0) begin
            // The three pointers, a byte at a time, before the first line
            ld <= ld - 1;
            if (ld[0]) write((18 - ld) / 6, 5'h14 + ((18 - ld) / 2) % 3, ((18 - ld) / 2) * 8'h37 + 8'h10);
        end else begin
            if (!ptr_wr) ptr_sel <= ptr_sel + 1'b1;
            r = $random;
            if (lines_left == 0) begin
                line_t_c   <= ~line_t_c;
                lines_left <= 300 + ({$random} % 700);
                line       <= line + 1;
                for (j = 0; j < 3; j = j + 1) begin
                    act[j]      <= (r[2*j +: 2] != 2'd0);
                    adv[j]      <= r[6+j];
                    tile[j]     <= r[9+j];
                    lbpp[2*j +: 2] <= {$random} % 4;
                    hscale[2*j +: 2] <= (r[18+j]) ? 2'd0 : {$random} % 4;
                    ngroups[12*j +: 12] <= r[21+j] ? 12'd0 : 12'd1 + ({$random} % 40);
                    mapw[2*j +: 2] <= {$random} % 4;
                    ty[10*j +: 10] <= $random;
                    tcol[7*j +: 7] <= $random;
                end
            end else begin
                lines_left <= lines_left - 1;
                // Live settings change mid-line now and then
                if (r[7:0] == 8'd1) begin j = {$random} % 3; hscale[2*j +: 2] <= {$random} % 4; end
                if (r[7:0] == 8'd2) begin j = {$random} % 3; wrap[4*j +: 4] <= ({$random} % 2) ? 4'd0 : 4'd1 + ({$random} % 6); end
                if (r[7:0] == 8'd3) begin j = {$random} % 3; act[j] <= ~act[j]; end
                if (r[7:0] == 8'd4) begin j = {$random} % 3; ngroups[12*j +: 12] <= 12'd1 + ({$random} % 40); end
                if (r[7:0] == 8'd5) enable <= ~enable;
                if (r[7:0] == 8'd6) begin j = {$random} % 3; lbpp[2*j +: 2] <= {$random} % 4; end
                if (r[7:0] == 8'd7) begin j = {$random} % 3; tile[j] <= ~tile[j]; end
            end
            // One byte register write a clock at most
            if (r[12:8] == 5'd0)       write({$random} % 3, 5'h14 + ({$random} % 3), r[13] ? 8'hF0 | ({$random} % 16) : $random);
            else if (r[12:8] == 5'd1)  write({$random} % 3, 5'h10 + ({$random} % 2), $random);
            else if (r[12:8] == 5'd2)  write({$random} % 3, 5'h18 + ({$random} % 3), $random);
            else if (r[12:8] == 5'd3)  write({$random} % 3, 5'h1C + ({$random} % 3), $random);
        end
    end

    // ---------------------------------------------------------------- checks
    integer d;
    integer errors = 0, checks = 0, n_req = 0, n_urg = 0, n_fill = 0, n_ptrw = 0, n_tile = 0, n_ent = 0, n_flip = 0;
    reg [9:0]  prev_dl [0:2];
    reg [5:0]  prev_hs;
    reg [4:0]  wl;
    reg [9:0]  rr;
    reg [1:0]  lb;
    reg [10:0] dlq, mark;
    reg        exp_urg;
    task fail(input [8*12-1:0] what, input [63:0] got, input [63:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("ERROR @%0d line %0d: %0s: core %h, reference %h", cyc, line, what, got, want);
        end
    endtask
`ifdef DBG
    always @(negedge clk) if (cyc >= `DBG && cyc < `DBG + 70)
        $display("%0d go%b act%b tile%b/%b lb%h | pw%b sel%h | want r%b c%b pick r%0d c%0d ph r%b c%b slot r%h c%h ago r%b c%b bgo r%b c%b | req%b/%b addr r%h c%h | rem r%h %h %h c%h %h %h | fill c%b r%b attr c%h r%h | qb c%b r%b qf c%b r%b ent c%h %h r%h %h",
                 cyc, r_go, act, tile, ref.t_tile, lbpp, ptr_wr, ptr_sel,
                 ref.want, dut.want, ref.pick, dut.pick, ref.phase, dut.phase, ref.a_slot, dut.a_slot, ref.a_go, dut.a_go, ref.b_go, dut.b_go,
                 c_req, r_req, r_addr, c_addr, ref.rem[2], ref.rem[1], ref.rem[0], dut.rem[2], dut.rem[1], dut.rem[0], c_fill, r_fill, c_attr, r_attr,
                 dut.q_bsel[dut.q_h], ref.q_bsel[ref.q_h], dut.q_flip[dut.q_h], ref.q_flip[ref.q_h], dut.ent[2], dut.ent[3], ref.ent[2], ref.ent[3]);
`endif
    always @(negedge clk) if (!rst) begin
        checks = checks + 1;
        if (c_go  !== r_go)  fail("line_go", c_go, r_go);
        if (c_gen !== r_gen) fail("line_gen", c_gen, r_gen);
        if (c_dat !== r_dat) begin
            for (i = 23; i >= 0; i = i - 1) if (c_dat[16*i +: 16] !== r_dat[16*i +: 16]) d = i;
            fail("dat", {d[7:0], c_dat[16*d +: 16]}, {d[7:0], r_dat[16*d +: 16]});   // register (layer x 8 + r), value
        end
        if (c_attr !== r_attr) fail("attr", c_attr, r_attr);
        if (c_fill !== r_fill) fail("fill_t", c_fill, r_fill);
        if (c_req !== r_req) fail("req", c_req, r_req);
        if (r_req && c_addr !== r_addr) fail("addr", c_addr, r_addr);
        if (ptr_sel[4:3] != 2'd3 && ptr_rdata !== ref.pt[ptr_sel[4:3]]) fail("pointer", {ptr_sel, ptr_rdata}, {ptr_sel, ref.pt[ptr_sel[4:3]]});
        // urgent: the reference's compare, with the words left now and the
        // deadline (and scale) of the clock before, against the mark + 1
        rr = ref.rem[ref.req_layer];
        lb = lbpp[2*ref.req_layer +: 2];
        if (ref.req_ent) wl = {4'd0, rr[1]} + {4'd0, rr[0]} + 5'd1 + ((lb == 2'd0) ? 5'd2 : (5'd1 << lb));
        else begin wl = 5'd1; for (i = 2; i < 10; i = i + 1) wl = wl + {4'd0, rr[i]}; end
        dlq = {1'b0, prev_dl[ref.req_layer]};
        if (ref.req_ent) dlq = (prev_dl[ref.req_layer] == 10'h3FF) ? 11'h3FF : dlq + ({5'd0, 6'd59} << prev_hs[2*ref.req_layer +: 2]);
        mark = 11'd17 + 11'd5 * {6'd0, wl};
        exp_urg = r_req && (dlq < mark);
        if (c_urg !== exp_urg) fail("urgent", c_urg, exp_urg);
        for (i = 0; i < 3; i = i + 1) prev_dl[i] = ref.dl[i];
        prev_hs = hscale;
        if (r_req) n_req = n_req + 1;
        if (exp_urg) n_urg = n_urg + 1;
        if (c_fill != 3'd0) n_fill = n_fill + 1;
        if (ptr_wr) n_ptrw = n_ptrw + 1;
        if (r_req && ref.t_tile[ref.req_layer]) n_tile = n_tile + 1;
        if (r_req && ref.req_ent) n_ent = n_ent + 1;
        if (rvalid && ref.q_flip[ref.q_h] && ref.t_tile[ref.q_layer[ref.q_h]]) n_flip = n_flip + 1;
    end

    initial begin
        for (m = 0; m < 3; m = m + 1) begin tk_wait[m] = 0; prev_dl[m] = 10'h3FF; end
        prev_hs = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        repeat (`ifdef SHORT 20000 `else 600000 `endif) @(posedge clk);
        @(negedge clk);
        $display("%0d clocks, %0d lines: %0d requests (%0d tile, %0d entries, %0d flipped rows), %0d urgent, %0d full, %0d pointer bytes written",
                 checks, line, n_req, n_tile, n_ent, n_flip, n_urg, n_fill, n_ptrw);
        if (n_req < 1000 || n_urg == 0 || n_fill == 0 || n_ptrw == 0 || n_tile == 0 || n_ent == 0 || n_flip == 0) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
