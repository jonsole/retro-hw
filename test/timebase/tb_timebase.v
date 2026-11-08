`timescale 1ns/1ps
// timebase.v on its own: sc counts 0-9 and ph 0-4 from the last clock
// with rst high, and both start again on a later rst.
module tb_timebase;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    wire [2:0] ph;
    wire [3:0] sc;
    timebase dut (.clk(clk), .rst(rst), .ph(ph), .sc(sc));

    integer errors = 0, n, k;

    initial begin
        repeat (3) @(posedge clk);
        // The first clock after rst falls is edge 0 of a slot
        @(negedge clk);
        if (sc !== 4'd0 || ph !== 3'd0) begin
            errors = errors + 1;
            $display("ERROR: in reset: sc %0d ph %0d", sc, ph);
        end
        rst = 1'b0;
        for (n = 1; n <= 95; n = n + 1) begin
            @(negedge clk);
            if (sc !== n % 10 || ph !== n % 5) begin
                errors = errors + 1;
                $display("ERROR: clock %0d: sc %0d ph %0d, expected %0d %0d", n, sc, ph, n % 10, n % 5);
            end
        end
        // A reset in the middle of a slot: both start again
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        for (k = 0; k <= 20; k = k + 1) begin
            if (sc !== k % 10 || ph !== k % 5) begin
                errors = errors + 1;
                $display("ERROR: after reset, clock %0d: sc %0d ph %0d", k, sc, ph);
            end
            @(negedge clk);
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
