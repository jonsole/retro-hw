`timescale 1ns/1ps
// dmac with the real sram_ctl and a model of the SRAM behind its pad
// registers: 3 requesters read and write 16 words at random. Each rvalid_o
// pulse must go to a requester with a read in flight, in order, with the
// word a shadow copy of the memory says it should have. This checks that
// dmac's RD_DELAY matches sram_ctl's read latency, now that sram_ctl
// carries no tag.
module tb_dmac_sram;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    reg [3:0] sc = 0;
    always @(posedge clk) sc <= rst ? 4'd0 : (sc == 9 ? 4'd0 : sc + 1);
    wire start_next, rvalid, go, go_we; wire [2:0] next_cycle;
    wire [20:0] go_addr; wire [15:0] go_wdata, rdata; wire [1:0] go_be;
    reg [2:0] req = 0, we = 0; reg [62:0] addr; reg [47:0] wdata;
    wire [2:0] ack, rv;
    wire [20:0] sa; wire ce_n, ub_n, lb_n, oer, oef, wer, wef, dtr, dtf; wire [15:0] dqo;
    // SRAM model: the pad registers delay every output one clock
    reg [20:0] sa_p; reg [15:0] dqo_p; reg wef_p, ce_p;
    reg [15:0] mem [0:255];
    always @(posedge clk) begin sa_p <= sa; dqo_p <= dqo; wef_p <= wef; ce_p <= ce_n; end
    always @(negedge clk) if (!ce_p && !wef_p) mem[sa_p[7:0]] <= dqo_p;   // write mid-cycle
    wire [15:0] dqi = mem[sa_p[7:0]];
    dmac #(.N(3), .S(5), .RD_DELAY(4)) d (.clk(clk), .rst(rst), .start_next(start_next), .next_slot(next_cycle),
      .slot_owner(15'b000_000_001_000_010), .slot_lock(5'b0), .req(req), .urgent(3'b0), .high(3'b0), .we(we),
      .addr(addr), .wdata(wdata), .be(6'b111111), .ack(ack), .rvalid_o(rv), .go(go), .go_we(go_we),
      .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be), .rvalid(rvalid));
    sram_ctl m (.clk(clk), .rst(rst), .sc(sc), .go(go), .go_we(go_we), .go_addr(go_addr),
      .go_wdata(go_wdata), .go_be(go_be), .start_next(start_next), .next_cycle(next_cycle), .rvalid(rvalid),
      .rdata(rdata), .sram_a(sa), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
      .sram_oe_n_r(oer), .sram_oe_n_f(oef), .sram_we_n_r(wer), .sram_we_n_f(wef), .sram_dq_o(dqo),
      .sram_dq_t_r(dtr), .sram_dq_t_f(dtf), .sram_dq_i(dqi));
    // Each requester: its own reads must come back in order with the shadow copy's data
    reg [15:0] shadow [0:255];
    reg [15:0] expq [0:2][0:7]; integer qh[0:2], qt[0:2];
    integer k, errors = 0, reads = 0, i;
    always @(posedge clk) if (!rst) begin
        for (k = 0; k < 3; k = k + 1) begin
            if (ack[k]) begin
                if (we[k]) shadow[addr[k*21 +: 8]] = wdata[k*16 +: 16];
                else begin expq[k][qt[k] % 8] = shadow[addr[k*21 +: 8]]; qt[k] = qt[k] + 1; end
            end
            if (rv[k]) begin
                reads = reads + 1;
                if (qh[k] == qt[k]) begin errors = errors + 1; $display("ERROR: rvalid to %0d with no read", k); end
                else begin
                    if (rdata !== expq[k][qh[k] % 8]) begin errors = errors + 1;
                        if (errors < 5) $display("ERROR: req %0d got %h want %h", k, rdata, expq[k][qh[k] % 8]); end
                    qh[k] = qh[k] + 1;
                end
            end
            if (ack[k] || !req[k]) begin
                req[k] <= $random; we[k] <= $random;
                addr[k*21 +: 21] <= {$random} % 16; wdata[k*16 +: 16] <= $random;
            end
        end
    end
    initial begin
        for (i = 0; i < 256; i = i + 1) begin mem[i] = i * 3; shadow[i] = i * 3; end
        for (k = 0; k < 3; k = k + 1) begin qh[k] = 0; qt[k] = 0; end
        addr = 0; wdata = 0;
        repeat (3) @(posedge clk); rst = 0;
        repeat (100000) @(posedge clk);
        for (k = 0; k < 3; k = k + 1) if (qt[k] - qh[k] > 1) begin errors = errors + 1; $display("ERROR: reads lost at %0d", k); end
        $display("%0d reads back, %0d errors", reads, errors);
        if (errors == 0 && reads > 1000) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
