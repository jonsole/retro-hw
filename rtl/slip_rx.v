// Control commands and escapes on the bytes from the PC (SLIP-style).
// With recognition on (ctl_en or ctl_lock) C0 c ~c is a control command,
// DB DC a data C0 and DB DD a data DB. Every other byte goes on at once,
// so no data byte waits for the next one. A broken command is dropped; a
// C0 always starts a command again. With recognition off every byte goes
// on as it is.
//
// The commands: 1 BREAK, 2 RESET, 3 UPLOAD, each a 1-clock strobe. BREAK
// only while ctl_en is set; RESET and UPLOAD with ctl_lock alone too.
// With KEY_CMD = 1 there is also 4 KEY, C0 04 b ~b with b and ~b escaped
// like data: cmd_key for 1 clock with key_byte = b, only while ctl_en is
// set. With KEY_CMD = 0, C0 04 b is dropped as a broken command.
module slip_rx #(
    parameter KEY_CMD = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ctl_en,         // recognise the commands and escapes
    input  wire        ctl_lock,       // the same, but BREAK and KEY ignored

    input  wire        in_valid,       // 1 clock: a byte from the PC ...
    input  wire [7:0]  in_byte,        // ... this one

    output reg         out_valid,      // 1 clock: a data byte ...
    output reg  [7:0]  out_byte,       // ... this one

    output reg         cmd_break,      // 1 clock each: control commands
    output reg         cmd_reset,
    output reg         cmd_upload,
    output reg         cmd_key,        // 1 clock: KEY (KEY_CMD = 1) ...
    output reg  [7:0]  key_byte        // ... with this byte
);
    localparam [7:0] B_END = 8'hC0, B_ESC = 8'hDB, B_ESC_END = 8'hDC, B_ESC_ESC = 8'hDD;
    localparam [7:0] C_KEY = 8'd4;
    localparam [2:0] D_DATA = 3'd0, D_ESC = 3'd1, D_CMD = 3'd2, D_INV = 3'd3,
                     D_KB = 3'd4, D_KBESC = 3'd5, D_KBINV = 3'd6, D_KBINVESC = 3'd7;
    localparam       KEY_ON = (KEY_CMD != 0);

    wire        match_on = ctl_en || ctl_lock;
    reg  [2:0]  ds;
    reg  [7:0]  mc;            // the command byte
    reg  [7:0]  kb;            // KEY's b

    // An escaped byte: DC is C0, DD is DB, any other byte is itself
    function [7:0] unesc(input [7:0] b);
        unesc = (b == B_ESC_END) ? B_END : (b == B_ESC_ESC) ? B_ESC : b;
    endfunction

    always @(posedge clk) begin
        out_valid  <= 1'b0;
        cmd_break  <= 1'b0;
        cmd_reset  <= 1'b0;
        cmd_upload <= 1'b0;
        cmd_key    <= 1'b0;
        if (rst) begin
            ds <= D_DATA;
        end else if (in_valid) begin
            if (!match_on) begin
                out_valid <= 1'b1; out_byte <= in_byte;
                ds <= D_DATA;
            end else if (in_byte == B_END) begin
                ds <= D_CMD;
            end else case (ds)
                D_DATA: if (in_byte == B_ESC) ds <= D_ESC;
                        else begin out_valid <= 1'b1; out_byte <= in_byte; end
                D_ESC: begin
                    out_valid <= 1'b1;
                    out_byte  <= unesc(in_byte);
                    ds        <= D_DATA;
                end
                D_CMD: begin
                    mc <= in_byte;
                    ds <= (KEY_ON && in_byte == C_KEY) ? D_KB : D_INV;
                end
                D_INV: begin
                    ds <= D_DATA;
                    if (in_byte == ~mc && mc >= 8'd1 && mc <= 8'd3) begin
                        cmd_break  <= (mc == 8'd1) && ctl_en;
                        cmd_reset  <= (mc == 8'd2);
                        cmd_upload <= (mc == 8'd3);
                    end
                end
                D_KB: if (in_byte == B_ESC) ds <= D_KBESC;
                      else begin kb <= in_byte; ds <= D_KBINV; end
                D_KBESC: begin
                    kb <= unesc(in_byte);
                    ds <= D_KBINV;
                end
                D_KBINV: if (in_byte == B_ESC) ds <= D_KBINVESC;
                         else begin
                             ds <= D_DATA;
                             cmd_key  <= (in_byte == ~kb) && ctl_en;
                             key_byte <= kb;
                         end
                default: begin   // D_KBINVESC
                    ds <= D_DATA;
                    cmd_key  <= (unesc(in_byte) == ~kb) && ctl_en;
                    key_byte <= kb;
                end
            endcase
        end
    end
endmodule
