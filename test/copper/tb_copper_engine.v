// copper_engine.v on its own: a small made-up instruction set decoded here,
// lists in a memory model, a short frame (VTOT 20, HTOT 30). Every
// instruction run is checked against memory (the words in the buffer are
// the words at its place), and each test checks the order of the places
// run, the writes, the timing of the spare clock, WAIT, SKIP, SKIPC, the
// stack, STOP and errors, the starts, the frame restart, resume,
// stack_keep, run low, and a jump with a word on its way (dropped).
// Built twice: WR_HANDSHAKE 0 and 1 (-DHS=1).
//
// The test's instruction words:
//   15-12  op (the engine's OP_ codes)
//   11     two words
//   10     one more word is needed (a skip reads the next instruction's)
//   9      pos_rel;  8  wait_blt
//   7-0    pos_line, or cc in 3-0
//   second word: pos_px (7-0), or the target place (JUMP, CALL)
`timescale 1ns/1ps
module tb_copper_engine;
`ifdef HS
    localparam HS = 1;
`else
    localparam HS = 0;
`endif
    localparam [3:0] OP_NEXT = 4'd0, OP_WRITE = 4'd1, OP_WAIT = 4'd2, OP_SKIP = 4'd3,
                     OP_SKIPC = 4'd4, OP_JUMP = 4'd5, OP_CALL = 4'd6, OP_RET = 4'd7,
                     OP_STOP = 4'd8, OP_ERR = 4'd9, OP_MORE = 4'd10;
    localparam [10:0] VTOT = 11'd20, HTOT = 11'd30;

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- the engine
    reg         run = 1'b0, frame = 1'b0, start1 = 1'b0, start2 = 1'b0;
    reg  [16:1] list1 = 16'd0, list2 = 16'd0;
    reg         resume = 1'b0, stack_keep = 1'b0, stack_clear = 1'b0;
    wire        save2;
    wire [16:1] save2_at;
    wire [15:0] w0, w1, w2;
    wire        exec, more, error, wr_req, stopped, waiting;
    wire [16:1] pc;
    wire [3:0]  sp;
    reg         wr_go = 1'b1;
    reg  [2:0]  flags = 3'd0;
    reg  [10:0] bv = 11'd0, bh = 11'd0;
    reg         blt_idle = 1'b1;
    wire        mem_req;
    wire [16:1] mem_addr;
    wire        mem_ack;
    reg         mem_rvalid = 1'b0;
    reg  [15:0] mem_rdata = 16'd0;

    wire [1:0]  len  = w0[11] ? 2'd2 : 2'd1;
    wire [1:0]  need = len + {1'b0, w0[10]};

    copper_engine #(.AW(16), .VTOT(VTOT), .HTOT(HTOT), .WR_HANDSHAKE(HS)) dut (
        .clk(clk), .rst(rst),
        .run(run), .frame(frame), .start1(start1), .start2(start2),
        .list1(list1), .list2(list2),
        .resume(resume), .stack_keep(stack_keep), .stack_clear(stack_clear),
        .save2(save2), .save2_at(save2_at),
        .word0(w0), .word1(w1), .word2(w2),
        .need(need), .len(len),
        .skip_len((w0[11] ? w2[11] : w1[11]) ? 2'd2 : 2'd1),
        .op(w0[15:12]), .target(w1),
        .pos_line({3'd0, w0[7:0]}), .pos_px({3'd0, w1[7:0]}),
        .pos_rel(w0[9]), .wait_blt(w0[8]),
        .cc(w0[3:0]), .flags(flags),
        .exec(exec), .more(more), .error(error),
        .wr_req(wr_req), .wr_go(wr_go),
        .stopped(stopped), .waiting(waiting), .pc(pc), .sp(sp),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .beam_v(bv), .beam_h(bh), .blt_idle(blt_idle)
    );

    // ---------------------------------------------------------------- memory
    // The acknowledge in the clock of the request (when granted), the word
    // LAT clocks after it
    reg  [15:0] mem [0:255];
    reg         grant = 1'b1;
    integer     lat = 1, cnt = 0;
    reg         busy = 1'b0;
    reg  [16:1] a_held;
    assign mem_ack = mem_req && grant && !busy;
    always @(posedge clk) begin
        mem_rvalid <= 1'b0;
        if (mem_ack) begin busy <= 1'b1; a_held <= mem_addr; cnt <= lat; end
        else if (busy) begin
            if (cnt <= 1) begin
                busy <= 1'b0; mem_rvalid <= 1'b1; mem_rdata <= mem[a_held[8:1]];
            end else cnt <= cnt - 1;
        end
    end

    // ---------------------------------------------------------------- beam
    reg beam_on = 1'b0;
    always @(posedge clk) if (beam_on) begin
        if (bh == HTOT - 1) begin bh <= 11'd0; bv <= (bv == VTOT - 1) ? 11'd0 : bv + 11'd1; end
        else bh <= bh + 11'd1;
    end

    // ---------------------------------------------------------------- watch
    integer errors = 0, checks = 0, clocks = 0;
    integer nrun = 0, nwr = 0, nerr = 0, nsave = 0, nmore = 0;
    integer runat [0:63];               // places run, in order
    integer runclk [0:63];
    integer wrclk [0:63];
    integer last_exec = 0;
    reg [16:1] last_save = 16'd0;
    reg        ret_inflight = 1'b0;
    always @(posedge clk) clocks <= clocks + 1;

    task check(input [8*40-1:0] what, input integer got, input integer want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("ERROR: %0s: %0d (0x%h), expected %0d (0x%h)", what, got, got, want, want);
                errors = errors + 1;
            end
        end
    endtask

    // Sampled at the edge: the values the engine acts on
    always @(posedge clk) if (!rst) begin
        if (exec) begin
            // The buffer holds the instruction's words
            checks = checks + 1;
            if (w0 !== mem[pc[8:1]] || (need >= 2 && w1 !== mem[pc[8:1] + 8'd1])
                                   || (need == 3 && w2 !== mem[pc[8:1] + 8'd2])) begin
                $display("ERROR: at %h the buffer holds %h %h %h", pc, w0, w1, w2);
                errors = errors + 1;
            end
            if (w0[15:12] == OP_RET) ret_inflight = busy;
            if (nrun < 64) begin runat[nrun] = pc; runclk[nrun] = clocks; end
            nrun = nrun + 1;
        end
        if (wr_req && (!HS || wr_go)) begin
            if (nwr < 64) wrclk[nwr] = clocks;
            nwr = nwr + 1;
        end
        if (error) nerr = nerr + 1;
        if (more) nmore = nmore + 1;
        if (save2) begin nsave = nsave + 1; last_save = save2_at; end
    end

    // ---------------------------------------------------------------- helpers
    integer k;
    task clear;
        begin
            for (k = 0; k < 256; k = k + 1) mem[k] = {OP_STOP, 12'd0};
            nrun = 0; nwr = 0; nerr = 0; nsave = 0; nmore = 0;
        end
    endtask
    task put(input integer a, input [15:0] w); mem[a] = w; endtask
    task clk_n(input integer n); repeat (n) @(posedge clk); endtask
    task pulse_start1; begin @(negedge clk); start1 = 1'b1; @(negedge clk); start1 = 1'b0; end endtask
    task pulse_start2; begin @(negedge clk); start2 = 1'b1; @(negedge clk); start2 = 1'b0; end endtask
    task pulse_frame;  begin @(negedge clk); frame = 1'b1; @(negedge clk); frame = 1'b0; end endtask
    task wait_stop(input integer limit);
        integer t;
        begin
            t = 0;
            @(negedge clk);
            while (!stopped && t < limit) begin @(negedge clk); t = t + 1; end
            check("stopped in time", stopped, 1);
        end
    endtask
    task ran(input integer i, input integer a);
        check("place run", runat[i], a);
    endtask

    // ---------------------------------------------------------------- tests
    initial begin
        clear;
        clk_n(3);
        @(negedge clk); rst = 1'b0;
        check("stopped after reset", stopped, 1);
        run = 1'b1;

        // 1. Writes in a row, then STOP: places, a write a clock after it
        //    runs, a spare clock after each
        $display("1. writes");
        clear;
        put(16, {OP_WRITE, 12'h001}); put(17, {OP_WRITE, 12'h002}); put(18, {OP_WRITE, 12'h003});
        put(19, {OP_STOP, 12'd0});
        list1 = 16'd16;
        pulse_start1;
        wait_stop(200);
        check("runs", nrun, 4);
        ran(0, 16); ran(1, 17); ran(2, 18); ran(3, 19);
        check("writes", nwr, 3);
        check("write 1 clock after exec", wrclk[0] - runclk[0], 1);
        check("pc at the STOP", pc, 19);
        check("no error", nerr, 0);

        // 2. A WAIT on the beam fills the buffer: then two writes 2 clocks apart
        $display("2. WAIT, then writes 2 clocks apart");
        clear;
        put(0, {OP_WAIT, 4'b1000, 8'd3}); put(1, 16'd10);     // line 3, pixel 10
        put(2, {OP_WRITE, 12'h0}); put(3, {OP_WRITE, 12'h0}); put(4, {OP_STOP, 12'd0});
        bv = 0; bh = 0; beam_on = 1'b1;
        list1 = 16'd0;
        pulse_start1;
        clk_n(20);
        check("waiting", waiting, 1);
        wait_stop(200);
        check("runs", nrun, 4);
        ran(1, 2); ran(2, 3);
        check("writes 2 clocks apart (3: handshake)", runclk[2] - runclk[1], 2 + HS);
        // The WAIT ends at the clock the beam reaches (3, 10); the write runs
        // in the next
        check("write after the WAIT", runclk[1] - runclk[0] > 0, 1);

        // 3. WAIT with the blitter busy; WAIT that never ends (line 25)
        $display("3. WAIT for the blitter, WAIT never");
        clear;
        put(0, {OP_WAIT, 4'b1001, 8'd0}); put(1, 16'd0);      // (0, 0) and blt idle
        put(2, {OP_WAIT, 4'b1000, 8'd25}); put(3, 16'd0);     // line 25 >= VTOT
        blt_idle = 1'b0;
        pulse_start1;
        clk_n(50);
        check("held by the blitter", nrun, 1);
        check("waiting", waiting, 1);
        blt_idle = 1'b1;
        clk_n(400);
        check("on to the WAIT never", nrun, 2);
        check("still waiting", waiting, 1);

        // 4. JUMP, SKIP (beam), SKIPC (flags), with a two-word instruction
        //    skipped
        $display("4. JUMP, SKIP, SKIPC");
        clear;
        beam_on = 1'b0; bv = 11'd5; bh = 11'd0;
        put(0, {OP_JUMP, 4'b1000, 8'd0}); put(1, 16'd40);
        put(40, {OP_SKIP, 4'b1100, 8'd4}); put(41, 16'd0);    // (4, 0): reached; reads the next
        put(42, {OP_WAIT, 4'b1000, 8'd25}); put(43, 16'd0);   // skipped (two words)
        put(44, {OP_SKIP, 4'b1100, 8'd6}); put(45, 16'd0);    // (6, 0): not reached
        put(46, {OP_WRITE, 12'h0});
        put(47, {OP_SKIPC, 4'b0100, 8'd2});                   // cc 2: C set: skips
        put(48, {OP_WRITE, 12'h0});                           // skipped
        put(49, {OP_SKIPC, 4'b0100, 8'd0});                   // cc 0: Z (clear): not
        put(50, {OP_STOP, 12'd0});
        flags = 3'b100;
        list1 = 16'd0;
        pulse_start1;
        wait_stop(300);
        check("runs", nrun, 7);
        ran(0, 0); ran(1, 40); ran(2, 44); ran(3, 46); ran(4, 47); ran(5, 49); ran(6, 50);

        // 5. CALL and RET; the stack full and empty are errors
        $display("5. CALL, RET, stack faults");
        clear;
        put(0, {OP_CALL, 4'b1000, 8'd0}); put(1, 16'd20);
        put(2, {OP_RET, 12'd0});                              // empty: error
        put(20, {OP_WRITE, 12'h0}); put(21, {OP_RET, 12'd0});
        pulse_start1;
        wait_stop(300);
        check("runs", nrun, 4);
        ran(0, 0); ran(1, 20); ran(2, 21); ran(3, 2);
        check("errors", nerr, 1);
        check("sp", sp, 0);
        clear;
        put(0, {OP_CALL, 4'b1000, 8'd0}); put(1, 16'd0);      // calls itself: full at 8
        pulse_start1;
        wait_stop(300);
        check("runs", nrun, 9);
        check("errors", nerr, 1);
        check("sp full", sp, 8);
        // stack_clear empties it
        @(negedge clk); stack_clear = 1'b1; @(negedge clk); stack_clear = 1'b0;
        check("sp cleared", sp, 0);

        // 6. OP_ERR and an unknown op stop with an error; OP_MORE gives more
        $display("6. errors, MORE");
        clear;
        put(0, {OP_MORE, 12'd0}); put(1, {OP_ERR, 12'd0});
        pulse_start1;
        wait_stop(100);
        check("more", nmore, 1);
        check("errors", nerr, 1);
        clear;
        put(0, {4'd14, 12'd0});
        pulse_start1;
        wait_stop(100);
        check("unknown op: error", nerr, 1);

        // 7. A RET with the next word on its way: the word is dropped. The
        //    WAIT ends (blt_idle) once word 33 has been asked for
        $display("7. a return with a word on its way");
        clear;
        lat = 6;
        put(0, {OP_CALL, 4'b1000, 8'd0}); put(1, 16'd30);
        put(2, {OP_WRITE, 12'h0}); put(3, {OP_STOP, 12'd0});
        put(30, {OP_WAIT, 4'b1001, 8'd0}); put(31, 16'd0);
        put(32, {OP_RET, 12'd0});
        put(33, {OP_ERR, 12'd0});                             // on its way, then dropped
        blt_idle = 1'b0;
        pulse_start1;
        @(negedge clk);
        while (!(busy && a_held == 16'd33)) @(negedge clk);
        blt_idle = 1'b1;
        wait_stop(400);
        check("runs", nrun, 5);
        ran(1, 30); ran(2, 32); ran(3, 2); ran(4, 3);
        check("word on its way at the RET", ret_inflight, 1);
        check("no error", nerr, 0);
        lat = 1;

        // 8. resume: list 2 waits; the frame saves the WAIT's place, and
        //    starts list 1. Without resume nothing is saved. stack_keep.
        $display("8. resume, stack_keep");
        clear;
        put(0, {OP_STOP, 12'd0});                             // list 1
        put(60, {OP_CALL, 4'b1000, 8'd0}); put(61, 16'd70);
        put(70, {OP_WAIT, 4'b1000, 8'd25}); put(71, 16'd0);   // waits for ever
        list1 = 16'd0; list2 = 16'd60;
        resume = 1'b1; stack_keep = 1'b1;
        pulse_start2;
        clk_n(40);
        check("waiting in list 2", waiting, 1);
        pulse_frame;
        check("saved", nsave, 1);
        check("saved place: the WAIT", last_save, 70);
        check("stack kept", sp, 1);
        wait_stop(100);
        check("list 1 ran", runat[nrun - 1], 0);
        // Not in list 2 any more: the next frame saves nothing
        pulse_frame;
        check("no second save", nsave, 1);
        stack_keep = 1'b0;
        pulse_frame;
        check("stack emptied", sp, 0);
        // Without resume
        resume = 1'b0;
        pulse_start2;
        clk_n(40);
        pulse_frame;
        check("no save without resume", nsave, 1);

        // 9. run low stops the copper and forgets list 2
        $display("9. run low");
        resume = 1'b1;
        pulse_start2;
        clk_n(40);
        check("waiting", waiting, 1);
        @(negedge clk); run = 1'b0; @(negedge clk);
        check("stopped", stopped, 1);
        run = 1'b1;
        pulse_frame;
        check("nothing saved after off", nsave, 1);
        // A start while run is low does nothing
        wait_stop(50);
        @(negedge clk); run = 1'b0; start1 = 1'b1; @(negedge clk); start1 = 1'b0; run = 1'b1;
        clk_n(5);
        check("start while off ignored", stopped, 1);

        // 10. The write handshake: a write held until wr_go; a frame while it
        //     waits saves the write's own place
        if (HS) begin
            $display("10. write handshake");
            clear;
            put(80, {OP_WRITE, 12'h0}); put(81, {OP_STOP, 12'd0});
            list2 = 16'd80;
            wr_go = 1'b0;
            pulse_start2;
            clk_n(20);
            check("write waits", wr_req, 1);
            check("not on", nrun, 1);
            pulse_frame;
            check("saved the write's place", last_save, 80);
            check("write dropped by the restart", wr_req, 0);
            wr_go = 1'b1;
            clear;
            put(80, {OP_WRITE, 12'h0}); put(81, {OP_STOP, 12'd0});
            pulse_start2;
            wait_stop(100);
            check("write then STOP", nrun, 2);
            check("one write", nwr, 1);
        end

        // 11. Random memory delays: a long list, every word checked
        $display("11. random delays");
        clear;
        for (k = 100; k < 160; k = k + 3) begin
            put(k, {OP_WRITE, 12'h0});
            put(k + 1, {OP_SKIPC, 4'b0100, 8'd1});               // cc 1: Z clear: skips
            put(k + 2, {OP_ERR, 12'h0});                         // skipped
        end
        put(160, {OP_STOP, 12'd0});
        list1 = 16'd100;
        lat = 3;
        pulse_start1;
        repeat (400) begin @(negedge clk); grant = ($random & 1); end
        grant = 1'b1;
        wait_stop(200);
        check("no error", nerr, 0);
        check("runs", nrun, 41);
        check("writes", nwr, 20);
        lat = 1;

        $display("%0d checks, %0d errors (WR_HANDSHAKE %0d)", checks, errors, HS);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end

    initial begin
        #2000000;
        $display("ERROR: timeout");
        $display("TEST FAILED");
        $finish;
    end
endmodule
