// FT232H in asynchronous 245 FIFO mode: the pins on one side, a byte
// stream each way on the other. The clock is 100 MHz (the timing below
// counts clocks of 10 ns). What sits behind (the FIFOs, the command
// decoder) is in serial_link.v, so another front end, such as a UART,
// can take this one's place.
//
// A read starts when the FT232H has a byte (RXF# low) and rx_room says
// there is room behind; the byte comes out on rx_byte with rx_valid for
// one clock. A write starts when the FT232H can take a byte (TXE# low) and
// tx_valid is set; tx_pop is set for one clock once tx_byte has gone. Reads
// go first. Once the bytes behind have all gone (tx_empty), SIWU# is pulsed
// so the FT232H sends what it holds to the PC at once.
module ft232h_if (
    input  wire        clk,            // 100 MHz
    input  wire        rst,
    input  wire        en,             // 0: nothing read from or written to the FT232H

    output reg         rx_valid,       // 1 clock: a byte from the PC ...
    output reg  [7:0]  rx_byte,        // ... this one
    input  wire        rx_room,        // room behind for a byte

    input  wire        tx_valid,       // a byte waits to go to the PC ...
    input  wire [7:0]  tx_byte,        // ... this one
    output reg         tx_pop,         // 1 clock: tx_byte has gone
    input  wire        tx_empty,       // no bytes wait behind (for SIWU#)

    // FT232H pins
    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output reg  [7:0]  ft_d_o,
    output reg         ft_d_oe,
    output reg         ft_rd_n,
    output reg         ft_wr_n,
    output reg         ft_siwu_n
);
    // RXF# and TXE# are asynchronous: two-flop synchronisers.
    reg [1:0] rxf_s, txe_s;
    always @(posedge clk) begin
        rxf_s <= {rxf_s[0], ft_rxf_n};
        txe_s <= {txe_s[0], ft_txe_n};
    end
    wire rxf = !rxf_s[1];
    wire txe = !txe_s[1];

    // Read : RD# low 8 clocks (80 ns), data taken at the end, then 8 clocks high.
    // Write: data out; WR# high 3 clocks, low 5 clocks (the FT232H takes the
    //        byte as WR# falls), then data released and 8 clocks of recovery.
    localparam F_IDLE = 2'd0, F_READ = 2'd1, F_WRITE = 2'd2, F_REC = 2'd3;
    reg [1:0] fs;
    reg [3:0] ft_t;
    reg       sent;            // bytes went out since the last send-immediate
    reg [1:0] siwu_t;
    wire      room = rx_room && !rx_valid;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        tx_pop   <= 1'b0;
        if (rst) begin
            fs        <= F_IDLE;
            ft_rd_n   <= 1'b1;
            ft_wr_n   <= 1'b1;
            ft_d_oe   <= 1'b0;
            ft_siwu_n <= 1'b1;
            sent      <= 1'b0;
            siwu_t    <= 2'd0;
        end else begin
            // Send immediate: when the bytes behind have all gone
            if (siwu_t != 0) begin
                siwu_t <= siwu_t - 1'b1;
                if (siwu_t == 2'd1) ft_siwu_n <= 1'b1;
            end else if (sent && tx_empty && fs == F_IDLE) begin
                ft_siwu_n <= 1'b0;
                siwu_t    <= 2'd3;
                sent      <= 1'b0;
            end

            case (fs)
                F_IDLE: begin
                    ft_t <= 4'd0;
                    if (en && rxf && room) begin
                        ft_rd_n <= 1'b0;
                        fs      <= F_READ;
                    end else if (en && txe && tx_valid && siwu_t == 0) begin
                        ft_d_o  <= tx_byte;
                        ft_d_oe <= 1'b1;
                        fs      <= F_WRITE;
                    end
                end
                F_READ: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd7) begin
                        rx_byte  <= ft_d_i;
                        rx_valid <= 1'b1;
                        ft_rd_n  <= 1'b1;
                        ft_t     <= 4'd0;
                        fs       <= F_REC;
                    end
                end
                F_WRITE: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd2) ft_wr_n <= 1'b0;
                    if (ft_t == 4'd7) begin
                        ft_wr_n <= 1'b1;
                        ft_d_oe <= 1'b0;
                        tx_pop  <= 1'b1;
                        sent    <= 1'b1;
                        ft_t    <= 4'd0;
                        fs      <= F_REC;
                    end
                end
                F_REC: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd7) fs <= F_IDLE;
                end
            endcase
        end
    end
endmodule
