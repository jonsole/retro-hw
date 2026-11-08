// PS/2 keyboard port: the receiver, the sender and a 16-byte FIFO, with
// no registers. Each machine's wrapper maps its registers onto these
// ports. 100 MHz (the timeouts count clocks).
//
// Receiving: the keyboard clocks 11-bit frames (start 0, 8 data bits
// lowest first, odd parity, stop 1) at 10-17 kHz; a bit is taken at each
// falling edge of its clock. The clock line is filtered (it must hold a
// new level for 0.64 us) against noise. Good bytes go into the FIFO
// unchanged; bad ones are dropped and flagged (rx_frame_err,
// rx_parity_err). A frame not finished within 2 ms is dropped (the next
// starts afresh). The receiver runs while rx_en is 1; every good byte is
// also put out on rx_stb and rx_byte, whether or not it fits in the FIFO.
// It goes into the FIFO only while en is 1.
//
// A byte can also come from elsewhere (ins_stb, ins_byte), taken as if
// received while the receiver runs. If a real byte is taken on the same
// clock, the other waits a clock behind it, so neither is lost; two such
// bytes must be at least 2 clocks apart. Tie ins_stb to 0 if unused.
//
// Sending (tx_req with en set, while not busy): hold the clock low for
// 100 us, pull data low (the start bit), let the clock go; then the
// keyboard clocks the bits in: each is put out after a falling edge (8 data
// bits, parity, stop = data let go), and the keyboard answers by pulling
// data low for one more clock. 15 ms without that: tx_timeout. Nothing is
// received while sending.
//
// en 0 empties the FIFO and stops sending.
//
// Both lines are open collector: the outputs say when to pull a line low.
//
// The error strobes are high for one clock, on the clock the error is
// found, so a wrapper's sticky flags set on the next edge.
module ps2_core (
    input  wire        clk,
    input  wire        rst,

    input  wire        en,             // on: the FIFO fills, sending allowed
    input  wire        rx_en,          // the receiver runs (en, or more)

    input  wire        ps2_clk_i,
    input  wire        ps2_data_i,
    output reg         ps2_clk_low,    // pull the clock line low
    output reg         ps2_data_low,   // pull the data line low

    output reg         rx_stb,         // 1 clock: a good byte was received ...
    output reg  [7:0]  rx_byte,        // ... this one
    output wire        rx_frame_err,   // 1 clock: no start bit, or a bad stop bit
    output wire        rx_parity_err,  // 1 clock: bad parity

    input  wire        ins_stb,        // 1 clock: a byte taken as if received ...
    input  wire [7:0]  ins_byte,       // ... this one

    output wire [7:0]  fifo_byte,      // the oldest byte (0x00 when empty)
    output wire [4:0]  fifo_count,     // bytes in the FIFO, 0-16
    input  wire        fifo_pop,       // take the oldest byte (ignored when empty)
    output wire        fifo_overflow,  // 1 clock: a byte was dropped, the FIFO full

    input  wire        tx_req,         // 1 clock: send ...
    input  wire [7:0]  tx_byte,        // ... this byte
    output wire        tx_busy,        // sending
    output wire        tx_timeout      // 1 clock: no answer within 15 ms
);
    // ---------------------------------------------------------------- the lines
    (* ASYNC_REG = "TRUE" *) reg [1:0] cs, ds;
    always @(posedge clk) begin
        cs <= {cs[0], ps2_clk_i};
        ds <= {ds[0], ps2_data_i};
    end
    reg         kc;                    // the clock, filtered
    reg  [5:0]  kcn;
    always @(posedge clk)
        if (rst) begin kc <= 1'b1; kcn <= 6'd0; end
        else if (cs[1] == kc) kcn <= 6'd0;
        else if (kcn == 6'd63) begin kc <= cs[1]; kcn <= 6'd0; end
        else kcn <= kcn + 1'b1;
    reg         kc_d;
    always @(posedge clk) kc_d <= kc;
    wire        kfall = kc_d && !kc;

    // ---------------------------------------------------------------- the FIFO
    reg  [7:0]  fifo [0:15];
    reg  [3:0]  fh, ft;
    reg  [4:0]  fcount;
    wire        f_pop  = fifo_pop && fcount != 5'd0;
    reg         f_push;
    reg  [7:0]  f_byte;
    assign fifo_byte     = (fcount != 5'd0) ? fifo[fh] : 8'h00;
    assign fifo_count    = fcount;
    assign fifo_overflow = !rst && f_push && fcount == 5'd16;

    // ---------------------------------------------------------------- receive and send
    reg  [3:0]  rn;                    // bits of the frame so far
    reg  [9:0]  rsh;                   // data, parity, stop (start checked on its own)
    reg  [17:0] rt;                    // time since the frame's last bit
    reg         tx, tx_ack;            // sending; waiting for the keyboard's answer
    reg  [8:0]  tsh;                   // data and parity still to send
    reg  [3:0]  tn;
    reg  [20:0] tt;                    // time: the 100 us hold, then the 15 ms limit

    wire        send_w = tx_req && en && !tx;
    assign      tx_busy = tx;

    // The frame's end: rsh holds data and parity; ds[1] is the stop bit
    wire        rx_bit  = !rst && !tx && kfall;
    wire        rx_last = rx_bit && rn == 4'd10;
    wire        rx_good = rx_last && ds[1] && (^rsh[9:1]);   // data + parity must be odd
    assign rx_frame_err  = (rx_bit && rn == 4'd0 && ds[1])   // no start bit
                        || (rx_last && !ds[1]);              // a bad stop bit
    assign rx_parity_err = rx_last && ds[1] && !(^rsh[9:1]);
    assign tx_timeout    = !rst && tx && tt == 21'd1500000;

    // A byte from elsewhere waits here a clock if a real one is taken on
    // the same clock.
    reg         ins_wait;
    reg  [7:0]  ins_held;
    wire        ins_any  = ins_wait || ins_stb;
    wire [7:0]  ins_now  = ins_wait ? ins_held : ins_byte;

    always @(posedge clk) begin
        f_push <= 1'b0;
        rx_stb <= 1'b0;
        if (rst) begin
            fh <= 4'd0; ft <= 4'd0; fcount <= 5'd0;
            rn <= 4'd0; rt <= 18'd0; tx <= 1'b0; tx_ack <= 1'b0;
            ps2_clk_low <= 1'b0; ps2_data_low <= 1'b0;
            ins_wait <= 1'b0;
        end else begin
            // ---- receiving: a byte from elsewhere ...
            ins_wait <= 1'b0;
            if (ins_any && rx_en) begin
                f_push  <= en;
                f_byte  <= ins_now;
                rx_stb  <= 1'b1;
                rx_byte <= ins_now;
            end
            // ... and the keyboard's, which goes first on the same clock
            if (rx_bit) begin
                rt <= 18'd0;
                if (rn == 4'd0) begin
                    if (!ds[1]) rn <= 4'd1;                 // a start bit
                end else begin
                    rsh <= {ds[1], rsh[9:1]};
                    if (rn == 4'd10) rn <= 4'd0;
                    else             rn <= rn + 1'b1;
                end
                if (rx_good) begin
                    f_push  <= en;
                    f_byte  <= rsh[8:1];
                    rx_stb  <= 1'b1;
                    rx_byte <= rsh[8:1];
                    if (ins_any && rx_en) begin
                        ins_wait <= 1'b1;                   // the other byte goes next clock
                        ins_held <= ins_now;
                    end
                end
            end else if (!tx && rn != 4'd0) begin
                if (rt == 18'd200000) rn <= 4'd0;           // 2 ms without a bit: start again
                else rt <= rt + 1'b1;
            end
            // ---- sending
            if (send_w) begin
                tx <= 1'b1; tx_ack <= 1'b0;
                tsh <= {~^tx_byte, tx_byte};                // odd parity
                tn  <= 4'd0;
                tt  <= 21'd0;
                rn  <= 4'd0;
                ps2_clk_low  <= 1'b1;                       // hold the clock low ...
                ps2_data_low <= 1'b0;
            end else if (tx) begin
                tt <= tt + 1'b1;
                if (ps2_clk_low) begin
                    if (tt == 21'd10000) begin              // ... 100 us; then data low, clock free
                        ps2_data_low <= 1'b1;
                        ps2_clk_low  <= 1'b0;
                    end
                end else if (kfall) begin
                    if (tx_ack) begin
                        tx <= 1'b0;                         // the keyboard took it (data low on this clock)
                    end else if (tn < 4'd9) begin
                        ps2_data_low <= !tsh[0];            // data bits, then parity
                        tsh <= {1'b0, tsh[8:1]};
                        tn  <= tn + 1'b1;
                    end else begin
                        ps2_data_low <= 1'b0;               // the stop bit: let data go
                        tx_ack <= 1'b1;
                    end
                end
                if (tx_timeout) begin                       // 15 ms: give up
                    tx <= 1'b0;
                    ps2_clk_low  <= 1'b0;
                    ps2_data_low <= 1'b0;
                end
            end
            // ---- the FIFO (a byte is dropped when it is full)
            if (f_push && fcount != 5'd16) begin
                fifo[ft] <= f_byte;
                ft <= ft + 1'b1;
            end
            if (f_pop) fh <= fh + 1'b1;
            fcount <= fcount + ((f_push && fcount != 5'd16) ? 5'd1 : 5'd0) - (f_pop ? 5'd1 : 5'd0);
            if (!en) begin                                  // off: the FIFO empty, no sending
                fh <= 4'd0; ft <= 4'd0; fcount <= 5'd0;
                tx <= 1'b0; ps2_clk_low <= 1'b0; ps2_data_low <= 1'b0;
            end
            if (!rx_en) rn <= 4'd0;
        end
    end
endmodule
