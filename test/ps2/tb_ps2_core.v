// Unit test for ps2_core against the keyboard model (sim/ps2_model.v):
// receiving, the FIFO, overflow, parity and frame errors, the glitch
// filter, the 2 ms frame timeout, bytes from elsewhere, sending with the
// keyboard's answer, and the 15 ms send timeout.
`timescale 1ns/1ps
module tb_ps2_core;
    reg clk = 1'b0;
    always #5 clk = !clk;                  // 100 MHz
    reg rst = 1'b1;

    reg        en = 1'b0, rx_en = 1'b0;
    reg        ins_stb = 1'b0;
    reg  [7:0] ins_byte = 8'h00;
    reg        fifo_pop = 1'b0;
    reg        tx_req = 1'b0;
    reg  [7:0] tx_byte = 8'h00;

    // the lines: open collector, pulled low by the core, the model or the test
    reg        model_on = 1'b1;            // 0: the keyboard is unplugged
    reg        t_clk_low = 1'b0, t_data_low = 1'b0;
    wire       m_clk_low, m_data_low, c_clk_low, c_data_low;
    wire       clk_line  = !(c_clk_low  || (model_on && m_clk_low)  || t_clk_low);
    wire       data_line = !(c_data_low || (model_on && m_data_low) || t_data_low);

    wire       rx_stb, rx_frame_err, rx_parity_err, fifo_overflow, tx_busy, tx_timeout;
    wire [7:0] rx_byte, fifo_byte;
    wire [4:0] fifo_count;

    ps2_core dut (
        .clk(clk), .rst(rst), .en(en), .rx_en(rx_en),
        .ps2_clk_i(clk_line), .ps2_data_i(data_line),
        .ps2_clk_low(c_clk_low), .ps2_data_low(c_data_low),
        .rx_stb(rx_stb), .rx_byte(rx_byte),
        .rx_frame_err(rx_frame_err), .rx_parity_err(rx_parity_err),
        .ins_stb(ins_stb), .ins_byte(ins_byte),
        .fifo_byte(fifo_byte), .fifo_count(fifo_count), .fifo_pop(fifo_pop),
        .fifo_overflow(fifo_overflow),
        .tx_req(tx_req), .tx_byte(tx_byte), .tx_busy(tx_busy), .tx_timeout(tx_timeout)
    );
    ps2_model kbd (.clk_line(model_on ? clk_line : 1'b1), .data_line(model_on ? data_line : 1'b1),
                   .clk_low(m_clk_low), .data_low(m_data_low));

    // strobe counters
    integer n_rx = 0, n_frame = 0, n_parity = 0, n_ovf = 0, n_tout = 0;
    reg [7:0] last_rx = 8'h00;
    always @(posedge clk) begin
        if (rx_stb) begin n_rx = n_rx + 1; last_rx = rx_byte; end
        if (rx_frame_err)  n_frame  = n_frame + 1;
        if (rx_parity_err) n_parity = n_parity + 1;
        if (fifo_overflow) n_ovf    = n_ovf + 1;
        if (tx_timeout)    n_tout   = n_tout + 1;
    end

    integer fails = 0;
    task check(input [8*40-1:0] what, input integer got, input integer want);
        if (got !== want) begin
            $display("FAIL %0s: got %0h, want %0h", what, got, want);
            fails = fails + 1;
        end else
            $display("ok   %0s", what);
    endtask

    task pop;
        begin
            @(negedge clk); fifo_pop = 1'b1;
            @(negedge clk); fifo_pop = 1'b0;
        end
    endtask

    // a clock pulse from the test, data held at d (the keyboard model idle)
    task t_bit(input d);
        begin
            t_data_low = !d; #5000;
            t_clk_low = 1'b1; #10000;
            t_clk_low = 1'b0; #5000;
        end
    endtask

    integer k, r0;
    initial begin
        #100; @(negedge clk) rst = 1'b0;
        en = 1'b1; rx_en = 1'b1;
        #1000;

        // ---- a byte received
        kbd.send(8'h1C, 1'b0);
        check("one byte: rx_stb", n_rx, 1);
        check("one byte: rx_byte", last_rx, 8'h1C);
        check("one byte: count", fifo_count, 1);
        check("one byte: fifo_byte", fifo_byte, 8'h1C);
        pop;
        check("popped: count", fifo_count, 0);
        check("popped: fifo_byte 0x00", fifo_byte, 8'h00);
        pop;
        check("pop when empty: count stays 0", fifo_count, 0);

        // ---- bad parity
        kbd.send(8'h55, 1'b1);
        check("bad parity: rx_parity_err", n_parity, 1);
        check("bad parity: no byte", n_rx, 1);
        check("bad parity: count", fifo_count, 0);

        // ---- 17 bytes: the 17th dropped, still on rx_stb
        for (k = 0; k < 17; k = k + 1) kbd.send(8'h40 + k, 1'b0);
        check("17 bytes: rx_stb", n_rx, 18);
        check("17 bytes: count 16", fifo_count, 16);
        check("17 bytes: one overflow", n_ovf, 1);
        check("17 bytes: oldest first", fifo_byte, 8'h40);
        pop;
        check("then: next byte", fifo_byte, 8'h41);

        // ---- en 0 empties the FIFO; rx_en alone still receives
        @(negedge clk) en = 1'b0;
        @(negedge clk);
        check("en 0: count 0", fifo_count, 0);
        kbd.send(8'h2A, 1'b0);
        check("rx_en alone: rx_stb", n_rx, 19);
        check("rx_en alone: FIFO stays empty", fifo_count, 0);
        @(negedge clk) en = 1'b1;

        // ---- a byte from elsewhere
        @(negedge clk) begin ins_stb = 1'b1; ins_byte = 8'hA5; end
        @(negedge clk) ins_stb = 1'b0;
        @(negedge clk);
        check("ins: rx_stb", n_rx, 20);
        check("ins: rx_byte", last_rx, 8'hA5);
        check("ins: in the FIFO", fifo_byte, 8'hA5);
        pop;

        // ---- a byte from elsewhere on the clock a real one is taken
        fork
            kbd.send(8'h32, 1'b0);
            begin
                @(negedge clk);
                while (!(dut.rn == 4'd10 && dut.kfall)) @(negedge clk);
                ins_stb = 1'b1; ins_byte = 8'h21;
                @(negedge clk) ins_stb = 1'b0;
            end
        join
        check("both: count 2", fifo_count, 2);
        check("both: the keyboard's first", fifo_byte, 8'h32);
        pop;
        check("both: then the other", fifo_byte, 8'h21);
        pop;

        // ---- a glitch on the clock (0.3 us) is filtered out
        model_on = 1'b0;                      // the model would take these for a request to send
        r0 = n_frame;
        @(negedge clk) t_clk_low = 1'b1; #300; t_clk_low = 1'b0;
        #2000;
        check("glitch: no frame error", n_frame, r0);
        // ... but a real falling edge with data high is a frame error (no start bit)
        t_bit(1'b1);
        check("no start bit: frame error", n_frame, r0 + 1);

        // ---- a frame cut short: dropped after 2 ms, the next taken
        t_bit(1'b0); t_bit(1'b1); t_bit(1'b0);
        t_data_low = 1'b0;
        #2100000;
        model_on = 1'b1;
        check("cut short: dropped (rn 0)", dut.rn, 0);
        kbd.send(8'h77, 1'b0);
        check("after: byte taken", fifo_byte, 8'h77);
        check("after: count", fifo_count, 1);
        pop;

        // ---- sending: the keyboard takes the byte and answers 0xFA
        @(negedge clk) begin tx_req = 1'b1; tx_byte = 8'hED; end
        @(negedge clk) tx_req = 1'b0;
        check("send: busy", tx_busy, 1);
        wait (!tx_busy);
        #20000;                            // the model notes the byte after the ack bit
        check("send: the keyboard got 0xED", kbd.last_rx, 8'hED);
        check("send: no bad frames", kbd.rx_bad, 0);
        check("send: no timeout", n_tout, 0);
        wait (n_rx == 24);
        @(negedge clk);
        check("send: 0xFA back", fifo_byte, 8'hFA);
        pop;

        // ---- no keyboard: 15 ms timeout
        model_on = 1'b0;
        @(negedge clk) begin tx_req = 1'b1; tx_byte = 8'hFF; end
        @(negedge clk) tx_req = 1'b0;
        #14900000;
        check("no keyboard: still busy at 14.9 ms", tx_busy, 1);
        #200000;
        check("no keyboard: timeout", n_tout, 1);
        check("no keyboard: not busy", tx_busy, 0);
        check("no keyboard: lines let go", {c_clk_low, c_data_low}, 0);

        // ---- en 0 stops a send
        @(negedge clk) begin tx_req = 1'b1; tx_byte = 8'hFF; end
        @(negedge clk) tx_req = 1'b0;
        #1000;
        @(negedge clk) en = 1'b0;
        @(negedge clk);
        check("en 0: send stopped", tx_busy, 0);
        check("en 0: lines let go", {c_clk_low, c_data_low}, 0);
        @(negedge clk) tx_req = 1'b1;
        @(negedge clk) tx_req = 1'b0;
        check("en 0: no send", tx_busy, 0);

        if (fails == 0) $display("TEST PASSED");
        else            $display("TEST FAILED: %0d", fails);
        $finish;
    end
endmodule
