`timescale 1ns/1ps
// dmac.v on its own, with two cycle plans side by side on the same random
// requests:
//   plan A, the defaults: the CPU owns cycle 0 (urgent requests and the
//           nasty copper beat it), audio cycle 2, the HIGH share on;
//   plan B: the CPU owns cycles 0 and 2 and nothing beats it there, audio
//           cycle 4, no nasty copper, no HIGH share.
// Each cycle's winner, address, data, write flag, byte enables and tag are
// checked against a model of the rules for each plan, the acks a clock
// later, and the read-valid lines against the tag. Counters check that the
// cases that tell the plans apart came up.
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
    reg  [1:0]  cpu_be, blt_be, port_be, cop_pri, blt_share;
    reg  [9:0]  bpl_deadline, spr_deadline;
    reg  [2:0]  rtag;

    // Outputs: {rvalid x 7, ack x 7} and the cycle to sram_ctl
    wire [6:0]  ack_a, ack_b, rv_a, rv_b;
    wire        go_a, go_b, we_a, we_b;
    wire [21:1] addr_a, addr_b;
    wire [15:0] wd_a, wd_b;
    wire [1:0]  be_a, be_b;
    wire [2:0]  tag_a, tag_b;

`define PORTS(P_ACK, P_RV, P_GO, P_WE, P_ADDR, P_WD, P_BE, P_TAG) \
        .clk(clk), .rst(rst), .start_next(start_next), .next_cycle(next_cycle), \
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_be(cpu_be), \
        .cpu_ack(P_ACK[0]), .cpu_rvalid(P_RV[0]), \
        .bpl_req(bpl_req), .bpl_addr(bpl_addr), .bpl_deadline(bpl_deadline), .bpl_urgent(bpl_urgent), \
        .bpl_ack(P_ACK[1]), .bpl_rvalid(P_RV[1]), \
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_deadline(spr_deadline), .spr_urgent(spr_urgent), \
        .spr_ack(P_ACK[2]), .spr_rvalid(P_RV[2]), \
        .aud_req(aud_req), .aud_addr(aud_addr), .aud_ack(P_ACK[3]), .aud_rvalid(P_RV[3]), \
        .cop_req(cop_req), .cop_addr(cop_addr), .cop_pri(cop_pri), .cop_ack(P_ACK[4]), .cop_rvalid(P_RV[4]), \
        .blt_req(blt_req), .blt_we(blt_we), .blt_addr(blt_addr), .blt_wdata(blt_wdata), .blt_be(blt_be), \
        .blt_high(blt_high), .blt_share(blt_share), .blt_ack(P_ACK[5]), .blt_rvalid(P_RV[5]), \
        .port_req(port_req), .port_we(port_we), .port_addr(port_addr), .port_wdata(port_wdata), .port_be(port_be), \
        .port_ack(P_ACK[6]), .port_rvalid(P_RV[6]), \
        .go(P_GO), .go_we(P_WE), .go_addr(P_ADDR), .go_wdata(P_WD), .go_be(P_BE), .go_tag(P_TAG), \
        .rvalid(rvalid), .rtag(rtag)

    dmac plan_a (`PORTS(ack_a, rv_a, go_a, we_a, addr_a, wd_a, be_a, tag_a));
    dmac #(.CPU_CYCLES(5'b00101), .HARD_CYCLES(5'b01010), .AUD_CYCLES(5'b10000),
           .CPU_FIRST(1), .NASTY(0), .HIGH(0)) plan_b (`PORTS(ack_b, rv_b, go_b, we_b, addr_b, wd_b, be_b, tag_b));

    // ---------------------------------------------------------------- the model
    wire       hard_any = bpl_req || spr_req;
    wire [2:0] hard     = (spr_req && (!bpl_req || spr_deadline < bpl_deadline)) ? C_SPR : C_BPL;
    wire       urg_any  = (bpl_req && bpl_urgent) || (spr_req && spr_urgent);
    wire [2:0] urg      = (spr_req && spr_urgent && !(bpl_req && bpl_urgent && bpl_deadline <= spr_deadline))
                          ? C_SPR : C_BPL;
    wire       cop_hi   = cop_req && cop_pri != 2'd0;
    wire [2:0] free     = cop_hi ? C_COP : hard_any ? hard : aud_req ? C_AUD : cop_req ? C_COP :
                          blt_req ? C_BLT : port_req ? C_PORT : C_NONE;

    // Plan A's share of cycle 0 between the CPU and a HIGH job
    reg  [2:0] shc;
    wire [2:0] shmax    = (blt_share == 2'd0) ? 3'd1 : (blt_share == 2'd1) ? 3'd3 : 3'd7;
    wire       cpu_turn = (shc == shmax);
    wire       nasty    = cop_req && cop_pri == 2'd2;
    always @(posedge clk)
        if (rst) shc <= 3'd0;
        else if (start_next && next_cycle == 3'd0 && cpu_req && blt_req && blt_high && !urg_any && !nasty)
            shc <= cpu_turn ? 3'd0 : shc + 1'b1;

    reg [2:0] exp_a, exp_b;
    always @(*) begin
        // Plan A
        if (urg_any)    exp_a = urg;
        else if (nasty) exp_a = C_COP;
        else case (next_cycle)
            3'd0:       exp_a = !cpu_req ? free : (blt_req && blt_high && !cpu_turn) ? C_BLT : C_CPU;
            3'd1, 3'd3: exp_a = hard_any ? hard : free;
            3'd2:       exp_a = aud_req ? C_AUD : free;
            default:    exp_a = free;
        endcase
        if (!start_next) exp_a = C_NONE;
        // Plan B
        if ((next_cycle == 3'd0 || next_cycle == 3'd2) && cpu_req) exp_b = C_CPU;
        else if (urg_any) exp_b = urg;
        else case (next_cycle)
            3'd1, 3'd3: exp_b = hard_any ? hard : free;
            3'd4:       exp_b = aud_req ? C_AUD : free;
            default:    exp_b = free;
        endcase
        if (!start_next) exp_b = C_NONE;
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
    integer n_b_cpu_over_urg = 0, n_a_urg_over_cpu = 0, n_a_nasty = 0, n_a_high = 0,
            n_a_cpu_turn = 0, n_b_aud4 = 0, n_a_aud2 = 0, n_b_cpu2 = 0, n_free = 0;
    reg [2:0] last_a, last_b;
    task fail(input [8*24-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("ERROR: %0s: got %h, expected %h (cycle %0d, start %b)", what, got, want, next_cycle, start_next);
        end
    endtask
    always @(negedge clk) if (!rst) begin
        checks = checks + 1;
        if (tag_a !== exp_a) fail("plan A winner", tag_a, exp_a);
        if (tag_b !== exp_b) fail("plan B winner", tag_b, exp_b);
        if (go_a !== (exp_a != C_NONE)) fail("plan A go", go_a, exp_a != C_NONE);
        if (go_b !== (exp_b != C_NONE)) fail("plan B go", go_b, exp_b != C_NONE);
        if (addr_a !== w_addr(exp_a)) fail("plan A address", addr_a, w_addr(exp_a));
        if (addr_b !== w_addr(exp_b)) fail("plan B address", addr_b, w_addr(exp_b));
        if ({we_a, be_a, wd_a} !== w_wr(exp_a)) fail("plan A write", {we_a, be_a, wd_a}, w_wr(exp_a));
        if ({we_b, be_b, wd_b} !== w_wr(exp_b)) fail("plan B write", {we_b, be_b, wd_b}, w_wr(exp_b));
        // The acks: one clock after the cycle was given
        if (ack_a !== ((last_a == C_NONE) ? 7'd0 : 7'd1 << (last_a - 1'b1))) fail("plan A acks", ack_a, last_a);
        if (ack_b !== ((last_b == C_NONE) ? 7'd0 : 7'd1 << (last_b - 1'b1))) fail("plan B acks", ack_b, last_b);
        // Read data back by tag
        if (rv_a !== ((rvalid && rtag != 3'd0) ? 7'd1 << (rtag - 1'b1) : 7'd0)) fail("plan A rvalid", rv_a, rtag);
        if (rv_b !== rv_a) fail("plan B rvalid", rv_b, rv_a);
        last_a = exp_a;
        last_b = exp_b;
        // What came up
        if (start_next) begin
            if (exp_b == C_CPU && urg_any) n_b_cpu_over_urg = n_b_cpu_over_urg + 1;
            if (next_cycle == 3'd0 && cpu_req && urg_any) n_a_urg_over_cpu = n_a_urg_over_cpu + 1;
            if (!urg_any && nasty) n_a_nasty = n_a_nasty + 1;
            if (exp_a == C_BLT && next_cycle == 3'd0 && cpu_req) n_a_high = n_a_high + 1;
            if (exp_a == C_CPU && next_cycle == 3'd0 && blt_req && blt_high) n_a_cpu_turn = n_a_cpu_turn + 1;
            if (exp_b == C_AUD && next_cycle == 3'd4 && hard_any) n_b_aud4 = n_b_aud4 + 1;
            if (exp_a == C_AUD && next_cycle == 3'd2 && hard_any) n_a_aud2 = n_a_aud2 + 1;
            if (exp_b == C_CPU && next_cycle == 3'd2) n_b_cpu2 = n_b_cpu2 + 1;
            if (exp_a == C_PORT) n_free = n_free + 1;
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
        cop_pri    <= r[15:14];
        blt_req    <= r[16];
        blt_high   <= r[17];
        blt_share  <= r[22] ? 2'd0 : r[19:18];     // held mostly still, so the share counts up
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
    end

    initial begin
        last_a = C_NONE;
        last_b = C_NONE;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (200000) @(posedge clk);
        @(negedge clk);
        $display("%0d clocks checked", checks);
        $display("plan A: urgent over the CPU %0d, nasty %0d, HIGH job in cycle 0 %0d, the CPU's turn %0d, audio in 2 %0d",
                 n_a_urg_over_cpu, n_a_nasty, n_a_high, n_a_cpu_turn, n_a_aud2);
        $display("plan B: the CPU over urgent %0d, the CPU in 2 %0d, audio in 4 %0d", n_b_cpu_over_urg, n_b_cpu2, n_b_aud4);
        if (n_a_urg_over_cpu == 0 || n_a_nasty == 0 || n_a_high == 0 || n_a_cpu_turn == 0 || n_a_aud2 == 0 ||
            n_b_cpu_over_urg == 0 || n_b_cpu2 == 0 || n_b_aud4 == 0 || n_free == 0) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
