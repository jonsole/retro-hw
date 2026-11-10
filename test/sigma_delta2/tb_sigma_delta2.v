// Unit test for sigma_delta2: for a constant input x the share of ones in
// y over 2^17 clocks must be 1/2 + x / 2^17, within a few counts. The same
// for a first-order unit (ORDER 1); a unit with DSP 1 must give the same
// stream as one without, bit for bit.
`timescale 1ns/1ps
module tb_sigma_delta2;
    reg clk = 1'b0;
    always #5 clk = !clk;
    reg rst = 1'b1;
    reg signed [15:0] x = 16'sd0;
    wire y;

    wire y1, yd;
    sigma_delta2 dut (.clk(clk), .rst(rst), .x(x), .y(y));
    sigma_delta2 #(.ORDER(1)) dut1 (.clk(clk), .rst(rst), .x(x), .y(y1));
    sigma_delta2 #(.DSP(1)) dutd (.clk(clk), .rst(rst), .x(x), .y(yd));
    integer ones1, diff = 0;
    always @(negedge clk) if (!rst && yd !== y) diff = diff + 1;

    integer fails = 0;
    integer ones, k, want;
    task run(input signed [15:0] v);
        begin
            @(negedge clk) x = v;
            for (k = 0; k < 4096; k = k + 1) @(negedge clk);     // let it settle
            ones = 0;  ones1 = 0;
            for (k = 0; k < 131072; k = k + 1) begin
                @(negedge clk);
                if (y) ones = ones + 1;
                if (y1) ones1 = ones1 + 1;
            end
            want = 65536 + v;                                     // 2^17 * (1/2 + v / 2^17)
            if (ones < want - 4 || ones > want + 4) begin
                $display("FAIL x = %0d: %0d ones, want %0d", v, ones, want);
                fails = fails + 1;
            end else
                $display("ok   x = %0d: %0d ones (want %0d)", v, ones, want);
            if (ones1 < want - 4 || ones1 > want + 4) begin
                $display("FAIL first order, x = %0d: %0d ones, want %0d", v, ones1, want);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        #100; @(negedge clk) rst = 1'b0;
        if (y !== 1'b0 && y !== 1'b1) begin $display("FAIL y unknown after reset"); fails = fails + 1; end
        run(16'sd0);
        run(16'sd8192);                    // a quarter of full scale
        run(-16'sd8192);
        run(16'sd32767);                   // the ends
        run(-16'sd32768);
        run(16'sd1234);
        if (diff != 0) begin $display("FAIL: the DSP build's stream differs in %0d clocks", diff); fails = fails + 1; end
        if (fails == 0) $display("TEST PASSED");
        else            $display("TEST FAILED: %0d", fails);
        $finish;
    end
endmodule
