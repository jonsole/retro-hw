`timescale 1ns/1ps
// dmac.v on its own, on random requests and a random slot plan that
// changes every few hundred clocks (and now and then in the middle of a
// slot). Each cycle's winner, address, data, write flag, byte enables and
// tag are checked against a model of the rules, the acks a clock later,
// and the read-valid lines against the tag. Counters check that every rule
// came up.
module tb_dmac;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    localparam C_NONE = 3'd0, C_CPU = 3'd1, C_BPL = 3'd2, C_SPR = 3'd3,
               C_AUD  = 3'd4, C_COP = 3'd5, C_BLT = 3'd6, C_PORT = 3'd7;

    reg         start_next;
    reg  [2:0]  next_cycle;
    reg         cpu_req, cpu_we, bpl_req, bpl_urgent, spr_req, spr_urgent, aud_req, cop_req;
    reg         blt_req, blt_we, blt_high, port_req, port_we, rvalid;
    reg  [21:1] cpu_addr, bpl_addr, spr_addr, aud_addr, cop_addr, blt_addr, port_addr;
    reg  [15:0] cpu_wdata, blt_wdata, port_wdata;
    reg  [1:0]  cpu_be, blt_be, port_be;
    reg         cop_high;
    reg  [14:0] slot_owner;
    reg  [4:0]  slot_lock;
    reg  [9:0]  bpl_deadline, spr_deadline;
    reg  [2:0]  rtag;

    // Outputs: {rvalid x 7, ack x 7} and the cycle to sram_ctl
    wire [6:0]  ack_a, rv_a;
    wire        go_a, we_a;
    wire [21:1] addr_a;
    wire [15:0] wd_a;
    wire [1:0]  be_a;
    wire [2:0]  tag_a;

`define PORTS(P_ACK, P_RV, P_GO, P_WE, P_ADDR, P_WD, P_BE, P_TAG) \
        .clk(clk), .rst(rst), .start_next(start_next), .next_cycle(next_cycle), \
        .slot_owner(slot_owner), .slot_lock(slot_lock), \
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_be(cpu_be), \
        .cpu_ack(P_ACK[0]), .cpu_rvalid(P_RV[0]), \
        .bpl_req(bpl_req), .bpl_addr(bpl_addr), .bpl_deadline(bpl_deadline), .bpl_urgent(bpl_urgent), \
        .bpl_ack(P_ACK[1]), .bpl_rvalid(P_RV[1]), \
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_deadline(spr_deadline), .spr_urgent(spr_urgent), \
        .spr_ack(P_ACK[2]), .spr_rvalid(P_RV[2]), \
        .aud_req(aud_req), .aud_addr(aud_addr), .aud_ack(P_ACK[3]), .aud_rvalid(P_RV[3]), \
        .cop_req(cop_req), .cop_addr(cop_addr), .cop_high(cop_high), .cop_ack(P_ACK[4]), .cop_rvalid(P_RV[4]), \
        .blt_req(blt_req), .blt_we(blt_we), .blt_addr(blt_addr), .blt_wdata(blt_wdata), .blt_be(blt_be), \
        .blt_high(blt_high), .blt_ack(P_ACK[5]), .blt_rvalid(P_RV[5]), \
        .port_req(port_req), .port_we(port_we), .port_addr(port_addr), .port_wdata(port_wdata), .port_be(port_be), \
        .port_ack(P_ACK[6]), .port_rvalid(P_RV[6]), \
        .go(P_GO), .go_we(P_WE), .go_addr(P_ADDR), .go_wdata(P_WD), .go_be(P_BE), .go_tag(P_TAG), \
        .rvalid(rvalid), .rtag(rtag)

    dmac dut (`PORTS(ack_a, rv_a, go_a, we_a, addr_a, wd_a, be_a, tag_a));

    // ---------------------------------------------------------------- the model
    wire       hard_any = bpl_req || spr_req;
    wire [2:0] hard     = (spr_req && (!bpl_req || spr_deadline < bpl_deadline)) ? C_SPR : C_BPL;
    wire       urg_any  = (bpl_req && bpl_urgent) || (spr_req && spr_urgent);
    wire [2:0] urg      = (spr_req && spr_urgent && !(bpl_req && bpl_urgent && bpl_deadline <= spr_deadline))
                          ? C_SPR : C_BPL;

    // The free order, written as a list walked in turn
    reg [2:0] free;
    integer   k;
    always @(*) begin
        free = C_NONE;
        for (k = 7; k >= 0; k = k - 1)
            case (k)
                0: if (cop_req && cop_high) free = C_COP;
                1: if (hard_any)            free = hard;
                2: if (aud_req)             free = C_AUD;
                3: if (cop_req)             free = C_COP;
                4: if (blt_req && blt_high) free = C_BLT;
                5: if (cpu_req)             free = C_CPU;
                6: if (blt_req)             free = C_BLT;
                7: if (port_req)            free = C_PORT;
            endcase
    end

    function asks(input [2:0] c);
        case (c)
            C_CPU: asks = cpu_req;  C_BPL, C_SPR: asks = hard_any;  C_AUD: asks = aud_req;
            C_COP: asks = cop_req;  C_BLT: asks = blt_req;  C_PORT: asks = port_req;
            default: asks = 1'b0;
        endcase
    endfunction

    reg [2:0] m_owner, m_own, exp_a;
    reg       m_lock;
    always @(*) begin
        case (next_cycle)
            3'd0: m_owner = slot_owner[2:0];
            3'd1: m_owner = slot_owner[5:3];
            3'd2: m_owner = slot_owner[8:6];
            3'd3: m_owner = slot_owner[11:9];
            3'd4: m_owner = slot_owner[14:12];
            default: m_owner = C_NONE;
        endcase
        m_lock = (next_cycle <= 3'd4) && slot_lock[next_cycle];
        m_own  = (m_owner == C_BPL || m_owner == C_SPR) ? hard : m_owner;
        if (!start_next)                      exp_a = C_NONE;
        else if (m_lock && asks(m_owner))     exp_a = m_own;
        else if (urg_any)                     exp_a = urg;
        else if (asks(m_owner))               exp_a = m_own;
        else                                  exp_a = free;
    end

    function [21:1] w_addr(input [2:0] w);
        case (w)
            C_CPU: w_addr = cpu_addr;  C_BPL: w_addr = bpl_addr;  C_SPR: w_addr = spr_addr;
            C_AUD: w_addr = aud_addr;  C_COP: w_addr = cop_addr;  C_BLT: w_addr = blt_addr;
            default: w_addr = port_addr;
        endcase
    endfunction
    function [18:0] w_wr(input [2:0] w);           // {we, be, wdata}
        case (w)
            C_CPU:   w_wr = {cpu_we, cpu_be, cpu_wdata};
            C_BLT:   w_wr = {blt_we, blt_be, blt_wdata};
            C_PORT:  w_wr = {port_we, port_be, port_wdata};
            default: w_wr = {1'b0, 2'b11, port_wdata};
        endcase
    endfunction

    // ---------------------------------------------------------------- checks
    integer errors = 0, checks = 0;
    integer n_lock = 0, n_urg_over_owner = 0, n_owner = 0, n_disp_owner_spr = 0, n_free_cpu = 0,
            n_blt_over_cpu = 0, n_cop_high = 0, n_port = 0, n_no_owner = 0;
    reg [2:0] last_a;
    task fail(input [8*24-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("ERROR: %0s: got %h, expected %h (cycle %0d, start %b, owner %0d, lock %b)",
                         what, got, want, next_cycle, start_next, m_owner, m_lock);
        end
    endtask
    always @(negedge clk) if (!rst) begin
        checks = checks + 1;
        if (tag_a !== exp_a) fail("winner", tag_a, exp_a);
        if (go_a !== (exp_a != C_NONE)) fail("go", go_a, exp_a != C_NONE);
        if (addr_a !== w_addr(exp_a)) fail("address", addr_a, w_addr(exp_a));
        if ({we_a, be_a, wd_a} !== w_wr(exp_a)) fail("write", {we_a, be_a, wd_a}, w_wr(exp_a));
        // The acks: one clock after the cycle was given
        if (ack_a !== ((last_a == C_NONE) ? 7'd0 : 7'd1 << (last_a - 1'b1))) fail("acks", ack_a, last_a);
        // Read data back by tag
        if (rv_a !== ((rvalid && rtag != 3'd0) ? 7'd1 << (rtag - 1'b1) : 7'd0)) fail("rvalid", rv_a, rtag);
        last_a = exp_a;
        // What came up
        if (start_next) begin
            if (m_lock && asks(m_owner) && urg_any && m_own != urg) n_lock = n_lock + 1;
            if (!m_lock && asks(m_owner) && urg_any && m_own != urg) n_urg_over_owner = n_urg_over_owner + 1;
            if (!urg_any && asks(m_owner) && exp_a != free) n_owner = n_owner + 1;
            if (!urg_any && m_owner == C_BPL && exp_a == C_SPR) n_disp_owner_spr = n_disp_owner_spr + 1;
            if (exp_a == C_CPU && m_owner != C_CPU) n_free_cpu = n_free_cpu + 1;
            if (exp_a == C_BLT && cpu_req && m_owner != C_BLT) n_blt_over_cpu = n_blt_over_cpu + 1;
            if (exp_a == C_COP && hard_any && m_owner != C_COP) n_cop_high = n_cop_high + 1;
            if (exp_a == C_PORT) n_port = n_port + 1;
            if (next_cycle <= 3'd4 && m_owner == C_NONE && exp_a != C_NONE) n_no_owner = n_no_owner + 1;
        end
    end

    // ---------------------------------------------------------------- stimulus
    reg [31:0] r;
    always @(posedge clk) begin
        r = $random;
        start_next <= (r[2:0] != 3'd0);
        next_cycle <= (r[7:4] == 4'd0) ? 3'd5 + {1'b0, r[9:8] == 2'd3 ? 2'd2 : r[9:8]} : {$random} % 5;
        r = $random;
        // Requests: each often enough that every rule comes up
        cpu_req    <= r[0] | r[1];
        bpl_req    <= r[2] & r[3];
        spr_req    <= r[4] & r[5];
        bpl_urgent <= r[6] & r[7] & r[8];
        spr_urgent <= r[9] & r[10] & r[11];
        aud_req    <= r[12];
        cop_req    <= r[13];
        cop_high   <= r[14] & r[15];
        blt_req    <= r[16];
        blt_high   <= r[17] & r[18];
        port_req   <= r[20];
        cpu_we     <= r[21];
        blt_we     <= r[23];
        port_we    <= r[24];
        rvalid     <= r[25];
        rtag       <= r[28:26];
        bpl_deadline <= r[29] ? {$random} % 8 : $random;
        spr_deadline <= r[30] ? {$random} % 8 : $random;
        {cpu_addr, bpl_addr, spr_addr} <= {$random, $random};
        {aud_addr, cop_addr, blt_addr} <= {$random, $random};
        port_addr <= $random;
        {cpu_wdata, blt_wdata} <= $random;
        port_wdata <= $random;
        {cpu_be, blt_be, port_be} <= $random;
        // A new slot plan now and then (any clock, so also in mid-slot)
        if ({$random} % 300 == 0) begin
            slot_owner <= $random;
            slot_lock  <= $random;
        end
    end

    initial begin
        last_a = C_NONE;
        slot_owner = {3'd0, C_BPL, C_AUD, C_BPL, C_CPU};
        slot_lock  = 5'b00000;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (400000) @(posedge clk);
        @(negedge clk);
        $display("%0d clocks checked", checks);
        $display("locked owner over urgent %0d, urgent over owner %0d, owner %0d, display owner gave SPR %0d",
                 n_lock, n_urg_over_owner, n_owner, n_disp_owner_spr);
        $display("free: CPU %0d, high BLT over CPU %0d, high COP over display %0d, PORT %0d, unowned cycle used %0d",
                 n_free_cpu, n_blt_over_cpu, n_cop_high, n_port, n_no_owner);
        if (n_lock == 0 || n_urg_over_owner == 0 || n_owner == 0 || n_disp_owner_spr == 0 || n_free_cpu == 0 ||
            n_blt_over_cpu == 0 || n_cop_high == 0 || n_port == 0 || n_no_owner == 0) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
