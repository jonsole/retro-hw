`timescale 1ns/1ps
// dmac.v on its own, for one choice of N (requesters) and S (slots), set
// with -P (the Makefile runs several). Random requests, urgent and high
// flags, and a random slot plan that changes every few hundred clocks (and
// now and then in the middle of a round). next_slot also takes values past
// the plan's end. Each cycle's winner, address, data, write flag, byte
// enables and tag are checked against a model of the rules, the acks a
// clock later, and the read-valid lines: the memory's rvalid comes 4 clocks
// after each read issued, as sram_ctl's does, and must go to its reader. Counters check
// that every rule came up.
module tb_dmac;
    parameter N = 7;
    parameter S = 5;
    localparam AW = 21, DW = 16, BW = DW / 8;
    localparam SW = (S > 1) ? $clog2(S) : 1;
    localparam TW = (N > 1) ? $clog2(N) : 1;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg              start_next;
    reg  [SW-1:0]    next_slot;
    reg  [S*N-1:0]   slot_owner;
    reg  [S-1:0]     slot_lock;
    reg  [N-1:0]     req, urgent, high, we;
    reg  [N*AW-1:0]  addr;
    reg  [N*DW-1:0]  wdata;
    reg  [N*BW-1:0]  be;
    reg              rvalid;

    wire [N-1:0]     ack, rv;
    wire             go, go_we;
    wire [AW-1:0]    go_addr;
    wire [DW-1:0]    go_wdata;
    wire [BW-1:0]    go_be;

    dmac #(.N(N), .S(S), .AW(AW), .DW(DW), .RD_DELAY(4)) dut (
        .clk(clk), .rst(rst), .start_next(start_next), .next_slot(next_slot),
        .slot_owner(slot_owner), .slot_lock(slot_lock),
        .req(req), .urgent(urgent), .high(high), .we(we), .addr(addr), .wdata(wdata), .be(be),
        .ack(ack), .rvalid_o(rv),
        .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be),
        .rvalid(rvalid));

    // ---------------------------------------------------------------- the model
    // Written as a walk over the requesters for each rule in turn: the
    // winner's number, or -1 for none.
    integer m_win, m_rule, i;
    reg [N-1:0] m_own;
    reg         m_lock;
    always @(*) begin
        m_own  = (next_slot < S) ? (slot_owner >> (next_slot * N)) : {N{1'b0}};
        m_lock = (next_slot < S) ? slot_lock[next_slot] : 1'b0;
        m_win  = -1;
        m_rule = 0;
        if (start_next) begin
            if (m_lock)
                for (i = N - 1; i >= 0; i = i - 1) if (req[i] && m_own[i]) begin m_win = i; m_rule = 1; end
            if (m_win < 0)
                for (i = N - 1; i >= 0; i = i - 1) if (req[i] && urgent[i]) begin m_win = i; m_rule = 2; end
            if (m_win < 0)
                for (i = N - 1; i >= 0; i = i - 1) if (req[i] && m_own[i]) begin m_win = i; m_rule = 3; end
            if (m_win < 0)
                for (i = N - 1; i >= 0; i = i - 1) if (req[i] && high[i]) begin m_win = i; m_rule = 4; end
            if (m_win < 0)
                for (i = N - 1; i >= 0; i = i - 1) if (req[i]) begin m_win = i; m_rule = 5; end
        end
    end

    // ---------------------------------------------------------------- checks
    integer errors = 0, checks = 0, last_win = -1;
    integer n_lock = 0, n_urg_over_own = 0, n_own = 0, n_own_pick = 0, n_high = 0,
            n_any = 0, n_past_end = 0, n_idle = 0, n_reads = 0;
    integer rd_hist [0:3];
    task fail(input [8*16-1:0] what, input [63:0] got, input [63:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("ERROR (N=%0d S=%0d): %0s: got %h, expected %h (slot %0d, start %b, owners %b, lock %b)",
                         N, S, what, got, want, next_slot, start_next, m_own, m_lock);
        end
    endtask
    always @(negedge clk) if (!rst) begin
        checks = checks + 1;
        if (go !== (m_win >= 0)) fail("go", go, m_win >= 0);
        if (m_win >= 0) begin
            if (go_addr !== addr[m_win*AW +: AW]) fail("address", go_addr, addr[m_win*AW +: AW]);
            if ({go_we, go_be, go_wdata} !== {we[m_win], be[m_win*BW +: BW], wdata[m_win*DW +: DW]})
                fail("write", {go_we, go_be, go_wdata}, {we[m_win], be[m_win*BW +: BW], wdata[m_win*DW +: DW]});
        end
        // The acks: one clock after the cycle was given
        if (ack !== ((last_win < 0) ? {N{1'b0}} : ({{(N-1){1'b0}}, 1'b1} << last_win))) fail("acks", ack, last_win);
        // Read data back to the reader of 4 clocks ago (rd_hist[3]), then
        // move the history on: rd_hist[0] is this clock's read, or -1
        if (rv !== ((rd_hist[3] < 0) ? {N{1'b0}} : ({{(N-1){1'b0}}, 1'b1} << rd_hist[3])))
            fail("rvalid", rv, rd_hist[3]);
        if (rd_hist[3] >= 0) n_reads = n_reads + 1;
        rd_hist[3] = rd_hist[2]; rd_hist[2] = rd_hist[1]; rd_hist[1] = rd_hist[0];
        rd_hist[0] = (m_win >= 0 && !we[m_win]) ? m_win : -1;
        last_win = m_win;
        // What came up
        if (start_next) begin
            if (m_rule == 1 && |(req & urgent & ~(1 << m_win))) n_lock = n_lock + 1;
            if (m_rule == 2 && !m_own[m_win] && |(req & m_own)) n_urg_over_own = n_urg_over_own + 1;
            if (m_rule == 3) n_own = n_own + 1;
            if (m_rule == 3 && m_win > 0 && |(req & ((1 << m_win) - 1))) n_own_pick = n_own_pick + 1;
            if (m_rule == 4 && m_win > 0 && |(req & ((1 << m_win) - 1))) n_high = n_high + 1;
            if (m_rule == 5) n_any = n_any + 1;
            if (next_slot >= S && m_win >= 0) n_past_end = n_past_end + 1;
            if (m_win < 0) n_idle = n_idle + 1;
        end
    end

    // ---------------------------------------------------------------- stimulus
    reg [31:0] r;
    integer j;
    always @(posedge clk) begin
        r = $random;
        start_next <= (r[2:0] != 3'd0);
        next_slot  <= r[15:8];                     // all values, past the end too
        for (j = 0; j < N; j = j + 1) begin
            r = $random;
            req[j]    <= (N > 8) ? r[0] & r[1] : r[0] | r[1];   // rarer with many, so idle cycles still come up
            urgent[j] <= r[2] & r[3] & r[4];
            high[j]   <= r[5] & r[6];
            we[j]     <= r[7];
            addr[j*AW +: AW]  <= $random;
            wdata[j*DW +: DW] <= $random;
            be[j*BW +: BW]    <= $random;
        end
        // The memory: rvalid in the 4th clock after a read's decision
        rvalid <= (rd_hist[3] >= 0);
        // A new slot plan now and then (any clock, so also mid-round)
        if ({$random} % 300 == 0) begin
            for (j = 0; j < S; j = j + 1) begin
                r = $random;
                // Mostly one owner, sometimes several or none
                slot_owner[j*N +: N] <= r[1:0] == 2'd0 ? {N{1'b0}} :
                                        r[1:0] == 2'd1 ? $random : ({{(N-1){1'b0}}, 1'b1} << ({$random} % N));
                slot_lock[j] <= r[4] & r[5];
            end
        end
    end

    initial begin
        slot_owner = {S*N{1'b0}};
        slot_lock  = {S{1'b0}};
        rvalid     = 1'b0;
        rd_hist[0] = -1; rd_hist[1] = -1; rd_hist[2] = -1; rd_hist[3] = -1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (300000) @(posedge clk);
        @(negedge clk);
        $display("N=%0d S=%0d: %0d clocks checked", N, S, checks);
        $display("  locked owner over urgent %0d, urgent over owner %0d, owner %0d (not the lowest asking %0d)",
                 n_lock, n_urg_over_own, n_own, n_own_pick);
        $display("  high over a lower number %0d, any %0d, past the plan's end %0d, idle %0d, reads back %0d",
                 n_high, n_any, n_past_end, n_idle, n_reads);
        // Cases that need more than one requester, or slot numbers past the end
        if (n_own == 0 || n_any == 0 || n_idle == 0 || n_reads == 0 ||
            (N > 1 && (n_lock == 0 || n_urg_over_own == 0 || n_own_pick == 0 || n_high == 0)) ||
            ((1 << SW) > S && n_past_end == 0)) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
