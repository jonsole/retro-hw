`timescale 1ns/1ps
// fifo8.v against a queue model, checked after every edge: count, full,
// valid, and rdata (the oldest byte while valid; the last byte held while
// not). The model follows the spec, section 4.1: pop, refill, push.
// Directed parts first (the spec's table in 4.2, pop while empty, full with
// and without a pop, push and pop together at every fill level, reset),
// then random traffic at several push and pop rates.
module tb_fifo8;
    parameter AW = 2;
    localparam RAM   = 1 << AW;      // bytes in the RAM
    localparam DEPTH = RAM + 1;      // with the output register

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1, push = 1'b0, pop = 1'b0;
    reg  [7:0] wdata = 8'h00;
    wire [7:0] rdata;
    wire [AW+1:0] count;
    wire       full, valid;

    fifo8 #(.AW(AW)) dut (.clk(clk), .rst(rst), .push(push), .wdata(wdata), .pop(pop),
                          .rdata(rdata), .count(count), .full(full), .valid(valid));

    // The model: q[0] is the oldest byte; ov says it is on rdata
    reg [7:0] q [0:DEPTH-1];
    integer   n = 0;                 // bytes held
    reg       ov = 1'b0;
    reg [7:0] last = 8'h00;          // what rdata should hold while not valid
    reg       have_last = 1'b0;

    integer errors = 0, edges = 0, i;
    // Coverage of the cases the spec calls out
    integer c_push_full_drop = 0, c_push_full_taken = 0, c_pop_empty = 0;
    integer c_both = 0, c_count_max = 0, c_reset = 0;

    task model_edge;
        reg do_pop, refill, full_m, do_push;
        integer ramc;
        begin
            ramc    = n - ov;
            do_pop  = pop && ov;
            refill  = (ramc != 0) && (!ov || do_pop);
            full_m  = (ramc == RAM);
            do_push = push && (!full_m || refill);
            if (rst) begin
                // The RAM side has no reset: a refill in the reset clock
                // still loads rdata (spec 4.5); valid is 0 after it
                if (refill) last = q[ov];
                have_last = have_last || refill;
                n = 0; ov = 1'b0;
                c_reset = c_reset + 1;
            end else begin
                if (push && full_m && !refill) c_push_full_drop  = c_push_full_drop + 1;
                if (push && full_m &&  refill) c_push_full_taken = c_push_full_taken + 1;
                if (pop && !ov)                c_pop_empty       = c_pop_empty + 1;
                if (do_push && do_pop)         c_both            = c_both + 1;
                if (do_pop) begin
                    for (i = 0; i < DEPTH - 1; i = i + 1) q[i] = q[i+1];
                    n = n - 1;
                end
                if (do_push) begin
                    q[n] = wdata;
                    n = n + 1;
                end
                if (refill) begin
                    ov = 1'b1;
                    last = q[0];
                    have_last = 1'b1;
                end else if (do_pop) ov = 1'b0;
            end
        end
    endtask

    // The model steps at each edge, with the inputs the DUT samples
    always @(posedge clk) begin
        model_edge;
        edges = edges + 1;
    end

    // Compare between edges
    always @(negedge clk) begin
        if (n == DEPTH) c_count_max = c_count_max + 1;
        if (count !== n || full !== ((n - ov) == RAM) || valid !== ov
            || (ov && rdata !== q[0]) || (!ov && have_last && rdata !== last)) begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR: edge %0d: count %0d full %b valid %b rdata %h; model count %0d full %b valid %b rdata %h",
                         edges, count, full, valid, rdata, n, (n - ov) == RAM, ov, ov ? q[0] : last);
        end
    end

    // Set the inputs for the next edge (called just after a negedge)
    reg [7:0] next_byte = 8'h01;
    task drive(input p, input o);
        begin
            push = p; pop = o;
            wdata = next_byte;
            if (p) next_byte = next_byte + 8'h01;
            @(negedge clk);
        end
    endtask

    task flush;
        begin
            rst = 1'b1; push = 1'b0; pop = 1'b0;
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    integer k, lvl, ppush, ppop;
    reg rp, ro;
    initial begin
        repeat (2) @(negedge clk);
        rst = 1'b0;

        // The spec's table (4.2): A, B, a clock, two pops
        drive(1, 0); drive(1, 0); drive(0, 0); drive(0, 1); drive(0, 1);
        // A pop while empty, twice
        drive(0, 1); drive(0, 1);
        // One push a clock, popped as soon as valid: a steady stream
        for (k = 0; k < 12; k = k + 1) drive(1, valid);
        while (valid) drive(0, 1);

        // Fill to the top, then push while full with no pop: dropped
        for (k = 0; k < DEPTH + 3; k = k + 1) drive(1, 0);
        // Push and pop together while full: the push is taken (drop-oldest)
        for (k = 0; k < 4; k = k + 1) drive(1, 1);
        // Empty it
        for (k = 0; k < DEPTH + 2; k = k + 1) drive(0, 1);

        // Push and pop together at every fill level
        for (lvl = 0; lvl <= DEPTH; lvl = lvl + 1) begin
            flush;
            for (k = 0; k < lvl; k = k + 1) drive(1, 0);
            drive(0, 0);                   // let the output register fill
            for (k = 0; k < 3; k = k + 1) drive(1, 1);
            drive(0, 0);
        end

        // Reset while full and while streaming
        for (k = 0; k < DEPTH; k = k + 1) drive(1, 0);
        flush;
        drive(0, 1);
        for (k = 0; k < 5; k = k + 1) drive(1, 1);
        flush;
        drive(0, 0);

        // Random traffic at several rates (percent of clocks with push, pop)
        for (ppush = 10; ppush <= 90; ppush = ppush + 40)
            for (ppop = 10; ppop <= 90; ppop = ppop + 40)
                for (k = 0; k < 2000; k = k + 1) begin
                    rp = ($urandom % 100) < ppush;
                    ro = ($urandom % 100) < ppop;
                    if (($urandom % 500) == 0) flush;
                    else drive(rp, ro);
                end

        $display("AW %0d: %0d edges; pushes dropped while full %0d, taken while full %0d, pops while empty %0d, push+pop %0d, at %0d bytes %0d, resets %0d",
                 AW, edges, c_push_full_drop, c_push_full_taken, c_pop_empty, c_both, DEPTH, c_count_max, c_reset);
        if (c_push_full_drop == 0 || c_push_full_taken == 0 || c_pop_empty == 0
            || c_both == 0 || c_count_max == 0 || c_reset == 0) begin
            errors = errors + 1;
            $display("ERROR: a case was never reached");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
