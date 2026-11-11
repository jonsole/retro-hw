// audio_engine.v against a bit-exact model of its spec (4.6).
//
// The bench writes random settings (a byte or more at a time, at any
// moment), starts and stops channels, reads fields back, changes the rate,
// and answers memory reads quickly or slowly by spells. The model follows
// the spec's rules. It takes from the core only WHEN the engine begins a
// channel, moves a channel on and ends an output sample (the spec fixes
// what happens at those moments, not their clocks); everything computed
// is its own. Compared every clock: on, ev, out_v, out_l and out_r, rb_q,
// and every memory read's address, in order.
`timescale 1ns/1ps
module tb_audio_engine;
    parameter NCH    = 4;
    parameter AW     = 16;
    parameter LE     = 0;
    parameter INTERP = 1;
    parameter RDBACK = 1;
    localparam BW = AW + 1;
    localparam [BW-1:0] BM = {BW{1'b1}};

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg  [15:0]    rate = 16'd200;
    reg  [NCH-1:0] start = 0, stop = 0;
    reg            set_we = 1'b0, rb_re = 1'b0;
    reg  [1:0]     set_ch = 0, rb_ch = 0;
    reg  [2:0]     set_f = 0, set_be = 0, rb_f = 0;
    reg  [23:0]    set_d = 0;
    wire [NCH-1:0] on, ev;
    wire [23:0]    rb_q;
    wire           mem_req, out_v;
    wire [AW-1:0]  mem_addr;
    reg            mem_ack = 1'b0, mem_rvalid = 1'b0;
    reg  [15:0]    mem_rdata = 16'd0;
    wire signed [15:0] out_l, out_r;

    audio_engine #(.NCH(NCH), .AW(AW), .LE(LE), .INTERP(INTERP), .RDBACK(RDBACK)) dut (
        .clk(clk), .rst(rst), .rate(rate), .start(start), .stop(stop), .on(on), .ev(ev),
        .set_we(set_we), .set_ch(set_ch), .set_f(set_f), .set_d(set_d), .set_be(set_be),
        .rb_re(rb_re), .rb_ch(rb_ch), .rb_f(rb_f), .rb_q(rb_q),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .out_l(out_l), .out_r(out_r), .out_v(out_v));

    // ---------------------------------------------------------------- memory
    reg [15:0] mem [0:(1 << AW) - 1];
    integer    slow = 0;                       // the longest wait for an ack, by spells
    integer    wait_n = -1, rv_n = -1;
    reg [15:0] rv_d;
    always @(posedge clk) begin
        mem_ack <= 1'b0;  mem_rvalid <= 1'b0;
        if (mem_req && !mem_ack && wait_n < 0) wait_n = (slow == 0) ? 0 : {$random} % (slow + 1);
        if (wait_n == 0 && mem_req && !mem_ack) begin
            mem_ack <= 1'b1;
            rv_d    = mem[mem_addr];
            rv_n    = {$random} % 3;
            wait_n  = -1;
        end else if (wait_n > 0) wait_n = wait_n - 1;
        if (rv_n == 0 && !mem_ack) begin mem_rvalid <= 1'b1; mem_rdata <= rv_d; rv_n = -1; end
        else if (rv_n > 0) rv_n = rv_n - 1;
    end

    // ---------------------------------------------------------------- the model
    reg [2:0]     m_ctrl [0:3];
    reg [23:0]    m_lc [0:3], m_len [0:3], m_stepr [0:3], m_vol [0:3];    // the fields as written
    reg [BW-1:0]  b_lc [0:3], b_len [0:3];
    reg [BW+15:0] m_pos [0:3];
    reg [NCH-1:0] m_on = 0, m_startp = 0, x_ev = 0;
    reg [2:0]     c_ctrl;                      // taken when the channel was begun
    reg [19:0]    c_step;
    integer       c_vl, c_vr;
    reg           m_run;
    integer       L, R;
    reg           x_out = 1'b0;
    reg signed [15:0] x_l = 0, x_r = 0;
    reg [23:0]    x_rb = 24'd0;
    reg [AW-1:0]  rq [0:7];                    // the reads expected, in order
    integer       rq_w = 0, rq_r = 0;

    integer errors = 0, cyc = 0;
    integer n_out = 0, n_take = 0, n_wrap = 0, n_shot = 0, n_two = 0, n_stopmid = 0, n_late = 0, n_rb = 0,
            n_len0 = 0, n_stoptake = 0, n_near = 0, n_b8 = 0, n_period = 0, n_over = 0, n_xend = 0;
    task fail(input [8*14-1:0] what, input integer got, input integer want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("ERROR @%0d: %0s: core %0d (%h), model %0d (%h)", cyc, what, got, got, want, want);
        end
    endtask

    function integer s16(input [15:0] v);
        s16 = v[15] ? $signed({16'hFFFF, v}) : {16'd0, v};
    endfunction
    function integer sample(input [BW-1:0] lc, input [BW-1:0] i, input b16);
        reg [BW-1:0] a;
        reg [15:0]   w;
        begin
            a = b16 ? lc + (i << 1) : lc + i;
            w = mem[a[BW-1:1]];
            if (b16) sample = s16(w);
            else     sample = s16({((a[0] == (LE == 0)) ? w[7:0] : w[15:8]), 8'd0});
        end
    endfunction
    function [BW-1:0] addr_of(input [BW-1:0] lc, input [BW-1:0] i, input b16);
        addr_of = b16 ? lc + (i << 1) : lc + i;
    endfunction
    function integer vol(input [6:0] v);
        vol = (v > 7'd64) ? 64 : v;
    endfunction

    localparam E_IDLE = 4'd0, E_CH = 4'd1, E_G2 = 4'd14, E_ADV = 4'd12, E_OUT = 4'd13;
    wire stall = (RDBACK != 0) && rb_re;

    integer        n, last_begin = -1, last_rate = 0;
    reg            was_early = 1'b0;
    reg [BW-1:0]   i0, i1, a0, a1;
    reg [15:0]     fr;
    reg [BW+15:0]  p;
    integer        s0, s1, s;
    reg            nearm, tk, xe;

    always @(posedge clk) if (!rst) begin
        cyc = cyc + 1;
        // 1. the engine's moments
        if (!stall || dut.es == E_IDLE) begin
            n = dut.ch;
            case (dut.es)
                E_IDLE: if (dut.cnt == 16'd0) begin
                    L = 0;  R = 0;
                    // a sample not held up comes "rate" clocks after the one before
                    if (last_begin >= 0 && was_early) begin
                        n_period = n_period + 1;
                        if (cyc - last_begin != last_rate) fail("period", cyc - last_begin, last_rate);
                    end else if (last_begin >= 0) n_late = n_late + 1;
                    last_begin = cyc;  last_rate = (rate == 16'd0) ? 65536 : rate;  was_early = 1'b0;
                end else was_early = 1'b1;
                E_CH: begin
                    c_ctrl = m_ctrl[n];
                    c_step = m_stepr[n][19:0];
                    c_vl   = vol(m_vol[n][22:16]);
                    c_vr   = vol(m_vol[n][6:0]);
                    tk     = m_startp[n] && !stop[n];
                    if (m_startp[n] && stop[n]) n_stoptake = n_stoptake + 1;
                    if (tk) begin
                        b_lc[n]  = m_lc[n][BW-1:0];
                        b_len[n] = m_len[n][BW-1:0];
                        m_pos[n] = 0;
                        x_ev[n]  = 1'b1;
                        m_on[n]  = (b_len[n] != 0);
                        m_startp[n] = 1'b0;
                        n_take = n_take + 1;
                        if (b_len[n] == 0) n_len0 = n_len0 + 1;
                    end
                    m_run = tk ? (b_len[n] != 0) : (m_on[n] && !stop[n]);
                end
                E_G2: if (!m_run) fail("ran a stopped", 1, 0); else begin
                        i0 = m_pos[n][BW+15:16];
                        fr = m_pos[n][15:0];
                        i1 = (((i0 + 1'b1) & BM) < b_len[n]) ? i0 + 1'b1 : i0;
                        nearm = (INTERP == 0) || c_ctrl[1];
                        s0 = sample(b_lc[n], i0, c_ctrl[0]);
                        // at the block's last sample: on to the first sample at the address register now
                        xe = !(((i0 + 1'b1) & BM) < b_len[n]) && !c_ctrl[2] && (m_len[n][BW-1:0] != 0);
                        if (xe && !nearm) n_xend = n_xend + 1;
                        s1 = xe ? sample(m_lc[n][BW-1:0], 0, c_ctrl[0]) : sample(b_lc[n], i1, c_ctrl[0]);
                        if (nearm) s = s0;
                        else begin : ip
                            reg signed [63:0] wide;
                            reg signed [15:0] cut;
                            wide = $signed(s1 - s0) * $signed({1'b0, fr});
                            cut  = s0 + (wide >>> 16);
                            s    = cut;
                        end
                        L = L + s * c_vl;
                        R = R + s * c_vr;
                        a0 = addr_of(b_lc[n], i0, c_ctrl[0]);
                        a1 = xe ? m_lc[n][BW-1:0] : addr_of(b_lc[n], i1, c_ctrl[0]);
                        rq[rq_w % 8] = a0[BW-1:1];  rq_w = rq_w + 1;
                        if (!nearm && a1[BW-1:1] != a0[BW-1:1]) begin
                            rq[rq_w % 8] = a1[BW-1:1];  rq_w = rq_w + 1;
                            n_two = n_two + 1;
                        end
                        if (nearm) n_near = n_near + 1;
                        if (!c_ctrl[0]) n_b8 = n_b8 + 1;
                end
                E_ADV: begin
                    if (!m_run) fail("moved a stopped", 1, 0);
                    p = m_pos[n] + c_step;
                    if (p[BW+15:16] >= b_len[n]) begin
                        if (c_ctrl[2]) begin
                            m_on[n] = 1'b0;  x_ev[n] = 1'b1;  n_shot = n_shot + 1;
                        end else begin
                            p = p - {b_len[n], 16'd0};
                            b_lc[n]  = m_lc[n][BW-1:0];
                            b_len[n] = m_len[n][BW-1:0];
                            x_ev[n]  = 1'b1;
                            if (p[BW+15:16] >= b_len[n]) begin p = {{BW{1'b0}}, p[15:0]}; n_over = n_over + 1; end
                            if (b_len[n] == 0) m_on[n] = 1'b0;
                            m_pos[n] = p;
                            n_wrap = n_wrap + 1;
                        end
                    end else m_pos[n] = p;
                end
                E_OUT: begin
                    x_out = 1'b1;
                    x_l   = L >>> 8;
                    x_r   = R >>> 8;
                    n_out = n_out + 1;
                end
                default: ;
            endcase
        end
        // 2. a read-back
        if (rb_re && RDBACK != 0) begin
            n_rb = n_rb + 1;
            case (rb_f)
                3'd0:    x_rb = {21'd0, m_ctrl[rb_ch]};
                3'd1:    x_rb = {{(24-BW){1'b0}}, m_lc[rb_ch][BW-1:0]};
                3'd2:    x_rb = {{(24-BW){1'b0}}, m_len[rb_ch][BW-1:0]};
                3'd3:    x_rb = {4'd0, m_stepr[rb_ch][19:0]};
                3'd4:    x_rb = {1'b0, m_vol[rb_ch][22:16], 9'd0, m_vol[rb_ch][6:0]};
                3'd5:    x_rb = {{(24-BW){1'b0}}, m_pos[rb_ch][BW+15:16]};
                default: x_rb = 24'd0;
            endcase
        end
        // 3. starts and stops (a stop wins)
        for (n = 0; n < NCH; n = n + 1) begin
            if (stop[n] && dut.es > E_CH && dut.es != E_OUT && dut.ch == n && m_run) n_stopmid = n_stopmid + 1;
            if (start[n]) m_startp[n] = 1'b1;
            if (stop[n]) begin m_startp[n] = 1'b0; m_on[n] = 1'b0; end
        end
        // 4. a settings write
        if (set_we) begin
            if (set_f == 3'd0 && set_be[0]) m_ctrl[set_ch] = set_d[2:0];
            for (n = 0; n < 3; n = n + 1) if (set_be[n]) begin
                if (set_f == 3'd1) m_lc[set_ch][8*n +: 8]    = set_d[8*n +: 8];
                if (set_f == 3'd2) m_len[set_ch][8*n +: 8]   = set_d[8*n +: 8];
                if (set_f == 3'd3) m_stepr[set_ch][8*n +: 8] = set_d[8*n +: 8];
                if (set_f == 3'd4) m_vol[set_ch][8*n +: 8]   = set_d[8*n +: 8];
            end
        end
        // the reads, in order
        if (mem_req && mem_ack) begin
            if (rq_r == rq_w) fail("a read too many", mem_addr, 0);
            else begin
                if (mem_addr !== rq[rq_r % 8]) fail("mem_addr", mem_addr, rq[rq_r % 8]);
                rq_r = rq_r + 1;
            end
        end
    end

    always @(negedge clk) if (!rst) begin
        if (on !== m_on) fail("on", on, m_on);
        if (ev !== x_ev) fail("ev", ev, x_ev);
        if (out_v !== x_out) fail("out_v", out_v, x_out);
        if (out_l !== x_l) fail("out_l", out_l, x_l);
        if (out_r !== x_r) fail("out_r", out_r, x_r);
        if (rb_q !== x_rb) fail("rb_q", rb_q, x_rb);
        x_ev = 0;  x_out = 1'b0;
    end

    // ---------------------------------------------------------------- the machine
    integer j, len_r;
    reg [31:0] r;
    task wr(input [1:0] c, input [2:0] f, input [23:0] d, input [2:0] be);
        begin
            @(negedge clk); set_we = 1'b1; set_ch = c; set_f = f; set_d = d; set_be = be;
            @(negedge clk); set_we = 1'b0;
        end
    endtask
    function [23:0] rnd_field(input [2:0] f);
        begin
            r = $random;
            case (f)
                3'd0: rnd_field = ({$random} % 4 == 0) ? {$random} % 8 : {$random} % 4;          // one-shot less often
                3'd1: rnd_field = $random;
                3'd2: rnd_field = ({$random} % 12 == 0) ? 24'd0 : ({$random} % 5 == 0) ? $random : 24'd1 + ({$random} % 60);
                3'd3: rnd_field = ({$random} % 4 == 0) ? $random : 24'h004000 + ({$random} % 24'h030000);
                default: rnd_field = ({$random} % 4 == 0) ? $random : ((({$random} % 65) << 16) | ({$random} % 65));
            endcase
        end
    endfunction

    integer steps;
    initial begin
        for (j = 0; j < (1 << AW); j = j + 1) mem[j] = $random;
        for (j = 0; j < 4; j = j + 1) begin
            m_ctrl[j] = 3'd0;  m_lc[j] = 24'd0;  m_len[j] = 24'd0;  m_stepr[j] = 24'h010000;  m_vol[j] = 24'd0;
            b_lc[j] = 0;  b_len[j] = 0;  m_pos[j] = 0;
        end
        repeat (4) @(negedge clk);
        rst = 1'b0;
        // every field written once, whole
        for (j = 0; j < NCH; j = j + 1) begin
            wr(j, 3'd0, rnd_field(3'd0), 3'b111);
            wr(j, 3'd1, rnd_field(3'd1), 3'b111);
            wr(j, 3'd2, 24'd20 + j, 3'b111);
            wr(j, 3'd3, rnd_field(3'd3), 3'b111);
            wr(j, 3'd4, rnd_field(3'd4), 3'b111);
        end
        @(negedge clk); start = {NCH{1'b1}};
        @(negedge clk); start = 0;
        for (steps = 0; steps < `ifdef SHORT 600000 `else 3000000 `endif; steps = steps + 1) begin
            @(negedge clk);
            start = 0;  stop = 0;  set_we = 1'b0;  rb_re = 1'b0;
            r = $random;
            if ({$random} % 700 == 0) start[{$random} % NCH] = 1'b1;
            if ({$random} % 1500 == 0) stop[{$random} % NCH] = 1'b1;
            if ({$random} % 6000 == 0) begin start = $random; stop = $random; end                  // both at once
            // a stop in the very clock the engine begins a channel: one with a
            // start waiting (the start is forgotten), or one playing
            if (dut.es == E_CH && (dut.startp[dut.ch] ? {$random} % 6 == 0 : on[dut.ch] && {$random} % 300 == 0)) stop[dut.ch] = 1'b1;
            if ({$random} % 120 == 0) begin
                set_we = 1'b1;  set_ch = {$random} % NCH;  set_f = {$random} % 5;
                set_d  = rnd_field(set_f);
                set_be = ({$random} % 3 == 0) ? $random : 3'b111;
            end
            if ({$random} % 30 == 0) begin rb_re = 1'b1; rb_ch = {$random} % NCH; rb_f = {$random} % 8; end
            if ({$random} % 1500 == 0) rate = ({$random} % 6 == 0) ? 16'd1 + ({$random} % 150) : 16'd200 + ({$random} % 80);
            if ({$random} % 2500 == 0) slow = ({$random} % 3 == 0) ? 70 : ({$random} % 3 == 0) ? 12 : 0;
        end
        @(negedge clk);
        start = 0;  stop = 0;  set_we = 1'b0;  rb_re = 1'b0;
        // a reset: everything stops, the settings stay
        @(negedge clk); rst = 1'b1;
        @(negedge clk);
        if (on !== {NCH{1'b0}} || out_l !== 16'sd0 || out_r !== 16'sd0 || mem_req !== 1'b0) fail("reset", on, 0);
        $display("NCH=%0d LE=%0d INTERP=%0d RDBACK=%0d: %0d output samples (%0d on time, %0d late), %0d blocks taken at a start (%0d of length 0), %0d block ends (%0d past the next block too), %0d one-shots ended, %0d second reads, %0d nearest, %0d 8-bit, %0d stops while the engine worked on the channel, %0d stops as a start was to be taken, %0d read-backs, %0d samples interpolated across a block's end",
                 NCH, LE, INTERP, RDBACK, n_out, n_period, n_late, n_take, n_len0, n_wrap, n_over, n_shot, n_two, n_near, n_b8, n_stopmid, n_stoptake, n_rb, n_xend);
        if (n_out < 500 || n_period < 100 || (NCH == 4 && INTERP != 0 && n_late == 0) || n_take < 100 || n_len0 == 0 || n_wrap < 100 || n_over == 0 || n_shot == 0
            || (INTERP != 0 && n_two == 0) || n_near == 0 || n_b8 == 0 || (INTERP != 0 && n_xend < 50) || n_stopmid == 0 || n_stoptake == 0 || (RDBACK != 0 && n_rb == 0)) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
