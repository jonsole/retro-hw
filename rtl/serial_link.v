// The serial link's engine: the receive and transmit FIFOs and the
// command decoder (slip_rx.v), between a front end and a machine's
// registers. The front end (ft232h_if.v, later a UART) sits on the fe_
// ports, so this part is the same whatever carries the bytes.
//
// From the front end each byte goes through the decoder: data bytes into
// the receive FIFO, control commands out as strobes. Bytes pushed on the
// transmit side go to the front end in order. Both FIFOs show the oldest
// byte whenever valid is set (first-word-fall-through).
module serial_link #(
    parameter AW        = 11,          // each FIFO holds 2^AW bytes
    parameter RX_MARGIN = 18,          // bytes kept free in the receive FIFO
    parameter KEY_CMD   = 0            // 1: the KEY command (slip_rx.v)
) (
    input  wire          clk,
    input  wire          rst,          // the decoder
    input  wire          rx_clear,     // empty the receive FIFO
    input  wire          tx_clear,     // empty the transmit FIFO

    input  wire          ctl_en,       // recognise commands and escapes
    input  wire          ctl_lock,     // the same, but BREAK and KEY ignored
    input  wire          tx_en,        // 0: pushed bytes are thrown away
    input  wire          drop_oldest,  // a push on a full FIFO drops its oldest byte

    // Front end
    input  wire          fe_rx_valid,  // 1 clock: a byte from the PC
    input  wire [7:0]    fe_rx_byte,
    output wire          fe_rx_room,   // the receive FIFO has room
    output wire          fe_tx_valid,  // a byte for the PC
    output wire [7:0]    fe_tx_byte,
    input  wire          fe_tx_pop,    // 1 clock: it has gone
    output wire          fe_tx_empty,  // the transmit FIFO is empty

    // Receive side
    output wire          rx_valid,     // a data byte waits ...
    output wire [7:0]    rx_byte,      // ... this one (the oldest)
    input  wire          rx_pop,       // take it
    output wire          rx_new,       // 1 clock: a data byte went into the FIFO
    output wire [AW:0]   rx_count,     // bytes waiting, 0 .. 2^AW

    // Transmit side
    input  wire          tx_push,      // 1 clock: send this byte ...
    input  wire [7:0]    tx_byte,
    output wire          tx_full,      // no room: a push now is lost or drops the oldest
    output wire          tx_dropped,   // 1 clock: the oldest byte was dropped
    output wire [AW:0]   tx_space,     // room left, 0 .. 2^AW

    // Control commands, 1 clock each
    output wire          cmd_break,
    output wire          cmd_reset,
    output wire          cmd_upload,
    output wire          cmd_key,      // with key_byte (KEY_CMD = 1)
    output wire [7:0]    key_byte
);
    localparam [AW+1:0] SIZE = {2'b01, {AW{1'b0}}};
    localparam [AW+1:0] ROOM = SIZE - RX_MARGIN[AW+1:0];

    // ---------------------------------------------------------------- decoder
    wire       d_valid;
    wire [7:0] d_byte;
    slip_rx #(.KEY_CMD(KEY_CMD)) dec (
        .clk(clk), .rst(rst), .ctl_en(ctl_en), .ctl_lock(ctl_lock),
        .in_valid(fe_rx_valid), .in_byte(fe_rx_byte),
        .out_valid(d_valid), .out_byte(d_byte),
        .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .cmd_key(cmd_key), .key_byte(key_byte)
    );
    assign rx_new = d_valid;

    // ---------------------------------------------------------------- receive FIFO
    wire [AW+1:0] rx_n;
    fifo8 #(.AW(AW)) rx_fifo (.clk(clk), .rst(rx_clear), .push(d_valid), .wdata(d_byte),
                              .pop(rx_pop), .rdata(rx_byte), .count(rx_n), .full(),
                              .valid(rx_valid));
    assign rx_count   = (rx_n > SIZE) ? SIZE[AW:0] : rx_n[AW:0];
    assign fe_rx_room = rx_n < ROOM;

    // ---------------------------------------------------------------- transmit FIFO
    wire [AW+1:0] tx_n;
    assign tx_dropped = tx_push && tx_full && drop_oldest;
    fifo8 #(.AW(AW)) tx_fifo (.clk(clk), .rst(tx_clear), .push(tx_push && tx_en), .wdata(tx_byte),
                              .pop(fe_tx_pop || tx_dropped), .rdata(fe_tx_byte), .count(tx_n),
                              .full(tx_full), .valid(fe_tx_valid));
    assign tx_space    = (tx_n >= SIZE) ? {(AW+1){1'b0}} : SIZE[AW:0] - tx_n[AW:0];
    assign fe_tx_empty = tx_n == 0;
endmodule
