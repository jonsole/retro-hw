// serial_link.v and ft232h_if.v with the FT232H model.
//   - data both ways: bytes from the PC reach the receive FIFO in order;
//     bytes pushed go out to the PC, and SIWU# pulses once they have gone
//   - C0 01 FE, C0 02 FD, C0 03 FC give one BREAK, RESET and UPLOAD pulse
//     each, and nothing reaches the FIFO
//   - DB DC and DB DD give C0 and DB
//   - a lone C0 starts a command: the next two bytes are dropped
//   - KEY (KEY_CMD = 1), C0 04 b ~b with b and ~b escaped, gives cmd_key
//     with b; a second link built with KEY_CMD = 0, fed the same bytes,
//     drops C0 04 b as a broken command and gives no cmd_key
//   - ctl_lock alone: RESET still works, BREAK and KEY do not
//   - recognition off: every byte, C0 and DB too, goes on raw
//   - tx_en = 0 throws pushed bytes away; drop_oldest on a full FIFO drops
//     the oldest byte and keeps the new one
`timescale 1ns/1ps
module tb_serial_link;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg ctl_en = 1, ctl_lock = 0, en = 0, fe_en = 0, drop_oldest = 0;
    reg rx_clear = 1, tx_clear = 1;

    wire [7:0] ft_d, ft_d_o;
    wire       ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n, ft_rxf_n, ft_txe_n;
    assign ft_d = ft_d_oe ? ft_d_o : 8'hzz;
    ft232h_model ft (.d(ft_d), .rxf_n(ft_rxf_n), .txe_n(ft_txe_n), .rd_n(ft_rd_n), .wr_n(ft_wr_n), .siwu_n(ft_siwu_n));

    wire       fe_rx_valid, fe_rx_room, fe_tx_valid, fe_tx_pop, fe_tx_empty;
    wire [7:0] fe_rx_byte, fe_tx_byte;
    ft232h_if fe (.clk(clk), .rst(rst), .en(fe_en),
                  .rx_valid(fe_rx_valid), .rx_byte(fe_rx_byte), .rx_room(fe_rx_room),
                  .tx_valid(fe_tx_valid), .tx_byte(fe_tx_byte), .tx_pop(fe_tx_pop), .tx_empty(fe_tx_empty),
                  .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d), .ft_d_o(ft_d_o), .ft_d_oe(ft_d_oe),
                  .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n));

    reg        rx_pop = 0, tx_push = 0;
    reg  [7:0] tx_byte = 0;
    wire       rx_valid, rx_new, tx_full, tx_dropped;
    wire [7:0] rx_byte, key_byte;
    wire [11:0] rx_count, tx_space;
    wire       cmd_break, cmd_reset, cmd_upload, cmd_key;
    serial_link #(.AW(11), .RX_MARGIN(18), .KEY_CMD(1)) dut (
        .clk(clk), .rst(rst), .rx_clear(rx_clear), .tx_clear(tx_clear),
        .ctl_en(ctl_en), .ctl_lock(ctl_lock), .tx_en(en), .drop_oldest(drop_oldest),
        .fe_rx_valid(fe_rx_valid), .fe_rx_byte(fe_rx_byte), .fe_rx_room(fe_rx_room),
        .fe_tx_valid(fe_tx_valid), .fe_tx_byte(fe_tx_byte), .fe_tx_pop(fe_tx_pop), .fe_tx_empty(fe_tx_empty),
        .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_pop(rx_pop), .rx_new(rx_new), .rx_count(rx_count),
        .tx_push(tx_push), .tx_byte(tx_byte), .tx_full(tx_full), .tx_dropped(tx_dropped), .tx_space(tx_space),
        .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .cmd_key(cmd_key), .key_byte(key_byte));

    // The same bytes into a link without KEY; its transmit side is unused
    reg        rx0_pop = 0;
    wire       rx0_valid, key0;
    wire [7:0] rx0_byte;
    wire [11:0] rx0_count;
    serial_link #(.AW(11), .KEY_CMD(0)) nokey (
        .clk(clk), .rst(rst), .rx_clear(rx_clear), .tx_clear(tx_clear),
        .ctl_en(ctl_en), .ctl_lock(ctl_lock), .tx_en(1'b0), .drop_oldest(1'b0),
        .fe_rx_valid(fe_rx_valid), .fe_rx_byte(fe_rx_byte), .fe_rx_room(),
        .fe_tx_valid(), .fe_tx_byte(), .fe_tx_pop(1'b0), .fe_tx_empty(),
        .rx_valid(rx0_valid), .rx_byte(rx0_byte), .rx_pop(rx0_pop), .rx_new(), .rx_count(rx0_count),
        .tx_push(1'b0), .tx_byte(8'h00), .tx_full(), .tx_dropped(), .tx_space(),
        .cmd_break(), .cmd_reset(), .cmd_upload(), .cmd_key(key0), .key_byte());

    integer errors = 0, nbrk = 0, nrst = 0, nupl = 0, nkey = 0, nkey0 = 0, nnew = 0;
    reg [7:0] lastkey;
    always @(posedge clk) begin
        if (cmd_key) begin lastkey = key_byte; nkey = nkey + 1; end
        if (key0)       nkey0 = nkey0 + 1;
        if (cmd_break)  nbrk = nbrk + 1;
        if (cmd_reset)  nrst = nrst + 1;
        if (cmd_upload) nupl = nupl + 1;
        if (rx_new)     nnew = nnew + 1;
    end

    task fail(input [8*48-1:0] what);
        begin $display("FAIL %0s", what); errors = errors + 1; end
    endtask

    task idle;   // all the model's bytes read
        begin
            wait (ft.head == ft.tail);
            repeat (40) @(posedge clk);
        end
    endtask

    // The receive FIFO must hold exactly the n bytes in want; it is emptied
    reg [7:0] want [0:15];
    task expect_rx(input integer n, input [8*48-1:0] what);
        integer i;
        begin
            idle;
            if (rx_count != n) begin
                $display("FAIL %0s: %0d bytes, not %0d", what, rx_count, n);
                errors = errors + 1;
            end
            for (i = 0; i < n && rx_valid; i = i + 1) begin
                if (rx_byte !== want[i]) begin
                    $display("FAIL %0s: byte %0d is %h, not %h", what, i, rx_byte, want[i]);
                    errors = errors + 1;
                end
                @(posedge clk) rx_pop <= 1;
                @(posedge clk) rx_pop <= 0;
                @(posedge clk);
            end
            repeat (4) @(posedge clk);
            if (rx_valid) fail(what);
        end
    endtask

    // Empty the KEY_CMD = 0 link, keeping its bytes in got0
    reg [7:0] got0 [0:15];
    integer   n0;
    task drain0;
        begin
            n0 = 0;
            while (rx0_valid) begin
                got0[n0] = rx0_byte; n0 = n0 + 1;
                @(posedge clk) rx0_pop <= 1;
                @(posedge clk) rx0_pop <= 0;
                @(posedge clk);
            end
        end
    endtask

    task push(input [7:0] b);
        begin
            @(posedge clk) begin tx_push <= 1; tx_byte <= b; end
            @(posedge clk) tx_push <= 0;
        end
    endtask

    integer i, siwu0, out0;
    initial begin
        repeat (4) @(posedge clk);
        rst <= 0; rx_clear <= 0; tx_clear <= 0;
        repeat (4) @(posedge clk);

        // ---- nothing is read while en is 0
        ft.send(8'h11);
        repeat (200) @(posedge clk);
        if (ft.head != 0 || rx_valid) fail("read with en = 0");
        en <= 1; fe_en <= 1;
        want[0] = 8'h11;
        expect_rx(1, "first byte once en is set");

        // ---- data from the PC: a frame ending in 0x00 is all there at once
        ft.send(8'h48); ft.send(8'h69); ft.send(8'h00);
        want[0] = 8'h48; want[1] = 8'h69; want[2] = 8'h00;
        expect_rx(3, "data from the PC");
        if (nnew != 4) fail("rx_new count");

        // ---- data to the PC, then one SIWU# pulse
        siwu0 = ft.siwu_count; out0 = ft.nout;
        for (i = 0; i < 5; i = i + 1) push(8'h30 + i);
        if (tx_space != 12'd2048 - 5 && tx_space != 12'd2048 - 4) fail("tx_space after pushes");
        wait (ft.nout == out0 + 5);
        repeat (40) @(posedge clk);
        for (i = 0; i < 5; i = i + 1)
            if (ft.from_fpga[out0 + i] !== 8'h30 + i) fail("data to the PC");
        if (ft.siwu_count != siwu0 + 1) fail("one SIWU# pulse");
        if (tx_space != 12'd2048 || !fe_tx_empty) fail("transmit FIFO empty again");

        // ---- control commands among data
        ft.send(8'h41); ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'h42); ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'hC0); ft.send(8'h03); ft.send(8'hFC); ft.send(8'h43);
        want[0] = 8'h41; want[1] = 8'h42; want[2] = 8'h43;
        expect_rx(3, "commands among data");
        if (nbrk != 1 || nrst != 1 || nupl != 1) fail("one pulse per command");

        // ---- a broken command: wrong inverse, and an unknown code
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFE);
        ft.send(8'hC0); ft.send(8'h07); ft.send(8'hF8); ft.send(8'h44);
        want[0] = 8'h44;
        expect_rx(1, "broken commands dropped");
        if (nrst != 1) fail("no RESET from a wrong inverse");

        // ---- escapes
        ft.send(8'hDB); ft.send(8'hDC); ft.send(8'hDB); ft.send(8'hDD);
        ft.send(8'hDB); ft.send(8'h55); ft.send(8'hDC);
        want[0] = 8'hC0; want[1] = 8'hDB; want[2] = 8'h55; want[3] = 8'hDC;
        expect_rx(4, "escapes");

        // ---- a lone C0: the next two bytes are taken as a broken command
        ft.send(8'h61); ft.send(8'hC0); ft.send(8'h62); ft.send(8'h63); ft.send(8'h64);
        want[0] = 8'h61; want[1] = 8'h64;
        expect_rx(2, "a lone C0");
        // a C0 inside a command starts it again
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        idle;
        if (nrst != 2) fail("C0 restarts a command");
        drain0;   // the KEY_CMD = 0 link has seen the same bytes so far

        // ---- KEY with b = C0 (escaped) and ~b = 3F; then b = 24 and ~b = DB (escaped)
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'hDB); ft.send(8'hDC); ft.send(8'h3F);
        idle;
        if (nkey != 1 || lastkey != 8'hC0) fail("KEY with an escaped b");
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h24); ft.send(8'hDB); ft.send(8'hDD);
        idle;
        if (nkey != 2 || lastkey != 8'h24) fail("KEY with an escaped ~b");
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h12); ft.send(8'h34); ft.send(8'h70);
        want[0] = 8'h70;
        expect_rx(1, "broken KEY dropped");
        if (nkey != 2) fail("no KEY from a wrong inverse");
        // without KEY_CMD: C0 04 b is a broken command, what follows is data
        drain0;
        if (nkey0 != 0) fail("KEY with KEY_CMD = 0");
        if (n0 != 5 || got0[0] !== 8'hDC || got0[1] !== 8'h3F || got0[2] !== 8'hDB || got0[3] !== 8'h34
            || got0[4] !== 8'h70)
            fail("KEY_CMD = 0: bytes after C0 04 b");

        // ---- ctl_lock alone: RESET and UPLOAD, not BREAK or KEY
        ctl_en <= 0; ctl_lock <= 1;
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'hE3);
        ft.send(8'h45);
        want[0] = 8'h45;
        expect_rx(1, "ctl_lock alone");
        if (nbrk != 1 || nrst != 3 || nkey != 2) fail("ctl_lock: RESET only");

        // ---- recognition off: raw bytes
        ctl_lock <= 0;
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD); ft.send(8'hDB); ft.send(8'hDC);
        want[0] = 8'hC0; want[1] = 8'h02; want[2] = 8'hFD; want[3] = 8'hDB; want[4] = 8'hDC;
        expect_rx(5, "recognition off");
        if (nrst != 3) fail("no command with recognition off");
        ctl_en <= 1;

        // ---- tx_en = 0 throws pushes away
        en <= 0;
        push(8'h99);
        repeat (4) @(posedge clk);
        if (tx_space != 12'd2048) fail("push with tx_en = 0 kept");
        en <= 1;

        // ---- drop_oldest: fill the FIFO (nothing goes out with the front end off)
        fe_en <= 0;
        repeat (40) @(posedge clk);
        for (i = 0; i < 2049; i = i + 1) push(i[7:0]);
        repeat (4) @(posedge clk);
        if (!tx_full || tx_space != 0) fail("transmit FIFO full");
        drop_oldest <= 1;
        @(posedge clk) begin tx_push <= 1; tx_byte <= 8'hEE; end
        #1 if (!tx_dropped) fail("tx_dropped");
        @(posedge clk) tx_push <= 0;
        drop_oldest <= 0;
        out0 = ft.nout;
        fe_en <= 1;
        wait (ft.nout == out0 + 2049);
        repeat (40) @(posedge clk);
        if (ft.from_fpga[out0] !== 8'h01) fail("the oldest byte dropped");
        if (ft.from_fpga[out0 + 2048] !== 8'hEE) fail("the new byte kept, last");

        $display("");
        if (ft.errors != 0) fail("FT232H timing");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
