// Copper engine (docs/spec/copper_engine.md): the part of a copper that is
// the same whatever its instruction words look like. It fetches a list of
// 16-bit words from memory, holds them in a small buffer, runs one
// instruction at a time as the machine's decoder describes it, and waits
// for beam positions.
//
//   fetch     one word at a time through a memory channel (a request, an
//             acknowledge, then the data some clocks later), into a buffer
//             of up to three words. A jump throws the buffer away; a word
//             still on its way is dropped when it arrives.
//   run       the decoder (in the machine) looks at the buffer and says how
//             many words the instruction needs before it can run, how many
//             it takes up, and what it does (op). The engine runs it as soon
//             as the words are in.
//
// What the engine does itself: the list pointers' use (start, frame
// restart), jumps, skips, calls and returns (a stack of 8 places), WAIT on
// the beam (with or without the blitter idle), STOP, errors, keeping list
// 2's place over a frame start (resume) and the stack over it (stack_keep).
// What the machine does: the registers, decoding the words, the register
// write's address and data, an index register's step and the ALU (on more).
//
// Places are word addresses, bits AW to 1 of a byte address.
module copper_engine #(
    parameter        AW           = 21,       // word address bits AW to 1
    parameter [10:0] VTOT         = 11'd625,  // lines in a frame
    parameter [10:0] HTOT         = 11'd864,  // pixels in a line
    parameter        WR_HANDSHAKE = 0         // 1: a write waits for wr_go
) (
    input  wire          clk,
    input  wire          rst,

    // Control
    input  wire          run,          // the copper may run; low stops it
    input  wire          frame,        // 1 clock: the frame starts, at list 1
    input  wire          start1,       // 1 clock: start again at list 1
    input  wire          start2,       // 1 clock: start again at list 2
    input  wire [AW:1]   list1,
    input  wire [AW:1]   list2,
    input  wire          resume,       // keep list 2's place over a frame start
    input  wire          stack_keep,   // keep the stack over a frame start
    input  wire          stack_clear,  // 1 clock: empty the stack (wins)
    output wire          save2,        // 1 clock: put save2_at into list 2
    output wire [AW:1]   save2_at,

    // The decoder: the buffer out, the instruction's description in
    output wire [15:0]   word0,        // the instruction's first word
    output wire [15:0]   word1,
    output wire [15:0]   word2,
    input  wire [1:0]    need,         // words in the buffer before it runs (1-3)
    input  wire [1:0]    len,          // words it takes up (1-2)
    input  wire [1:0]    skip_len,     // words the next instruction takes up
    input  wire [3:0]    op,           // what it does (OP_ below)
    input  wire [AW:1]   target,       // JUMP and CALL: where to
    input  wire [10:0]   pos_line,     // WAIT and SKIP: the beam position
    input  wire [10:0]   pos_px,
    input  wire          pos_rel,      // ... pixel on this line (or the next)
    input  wire          wait_blt,     // WAIT: and the blitter idle
    input  wire [3:0]    cc,           // SKIPC: the condition
    input  wire [2:0]    flags,        // SKIPC: C (2), N (1), Z (0)
    output wire          exec,         // the instruction runs this clock
    output wire          more,         // OP_MORE's second clock runs this clock
    output wire          error,        // 1 clock: a bad op or a stack fault

    // The register write
    output reg           wr_req,
    input  wire          wr_go,        // the write is on the bus (WR_HANDSHAKE)

    // State
    output wire          stopped,
    output wire          waiting,
    output wire [AW:1]   pc,           // the instruction running (or next)
    output reg  [3:0]    sp,           // places on the stack (0-8)

    // Memory
    output reg           mem_req,      // held until mem_ack
    output reg  [AW:1]   mem_addr,
    input  wire          mem_ack,
    input  wire          mem_rvalid,
    input  wire [15:0]   mem_rdata,

    // The beam, and the blitter
    input  wire [10:0]   beam_v,
    input  wire [10:0]   beam_h,
    input  wire          blt_idle
);
    // What an instruction does
    localparam [3:0] OP_NEXT  = 4'd0,  // nothing: go on
                     OP_WRITE = 4'd1,  // a register write, then a spare clock
                     OP_WAIT  = 4'd2,  // wait for the beam
                     OP_SKIP  = 4'd3,  // skip the next if the beam is there
                     OP_SKIPC = 4'd4,  // skip the next if cc holds on flags
                     OP_JUMP  = 4'd5,
                     OP_CALL  = 4'd6,
                     OP_RET   = 4'd7,
                     OP_STOP  = 4'd8,
                     OP_ERR   = 4'd9,  // stop, with error
                     OP_MORE  = 4'd10; // a second clock (an ALU)

    localparam [2:0] X_OFF = 3'd0, X_RUN = 3'd1, X_WAIT = 3'd2, X_GAP = 3'd3,
                     X_MORE = 3'd4, X_WR = 3'd5;
    reg  [2:0]  xs;
    reg  [AW:1] npc;                   // next instruction to run (the word at b0)
    reg  [AW:1] xpc;                   // the instruction running
    reg         in2;                   // in list 2 (resume)
    reg  [AW:1] stk [0:7];

    // Fetch: a buffer of up to three words, and at most one word on its way
    reg  [15:0] b0, b1, b2;
    reg  [1:0]  bn;
    reg  [AW:1] fpc;                   // next word to fetch
    reg         outst;                 // a word is on its way (acked, data not back)
    reg         stale;                 // ... and it is to be dropped

    // A WAIT in progress
    reg  [10:0] w_line, w_px;
    reg         w_never, w_blt;

    assign word0 = b0;
    assign word1 = b1;
    assign word2 = b2;

    wire go = WR_HANDSHAKE ? wr_go : 1'b1;

    // A clock that restarts the copper runs no instruction, so that a cut-off
    // never leaves one half done
    wire hold = (frame || start1 || start2) && run;

    wire        have  = (bn != 2'd0) && (bn >= need);
    assign exec  = (xs == X_RUN) && have && !hold;
    assign more  = (xs == X_MORE) && !hold;
    assign error = exec && (op > OP_MORE || op == OP_ERR ||
                            (op == OP_CALL && sp == 4'd8) || (op == OP_RET && sp == 4'd0));

    wire [AW:1] npc_n = npc + {{(AW-2){1'b0}}, len};        // the instruction after
    wire [AW:1] npc_s = npc_n + {{(AW-2){1'b0}}, skip_len}; // ... and the one after that

    // Reached: the beam is at or past (line, pixel) in the frame
    wire        t_never  = (pos_line >= VTOT) || (pos_px >= HTOT);
    wire        t_reach  = !t_never && ((beam_v > pos_line) || (beam_v == pos_line && beam_h >= pos_px));
    wire        t_preach = (pos_px < HTOT) && (beam_h >= pos_px);

    function cond(input [3:0] c, input [2:0] f);   // f = {C, N, Z}
        case (c)
            4'd0: cond = f[0];
            4'd1: cond = !f[0];
            4'd2: cond = f[2];
            4'd3: cond = !f[2];
            4'd4: cond = f[1];
            4'd5: cond = !f[1];
            4'd6: cond = !f[2] && !f[0];
            4'd7: cond = f[2] || f[0];
            default: cond = 1'b0;
        endcase
    endfunction

    // Resume: list 2's place. A WAIT still waiting, a second clock not run
    // or a write not on the bus is run again; after a skip, npc is past it
    assign save2    = frame && run && resume && in2;
    assign save2_at = (xs == X_WAIT || xs == X_MORE || (xs == X_WR && !go)) ? xpc : npc;

    assign stopped = (xs == X_OFF);
    assign waiting = (xs == X_WAIT);
    assign pc      = (xs == X_RUN) ? npc : xpc;           // stopped: the STOP

    // ---------------------------------------------------------------- main
    reg        flush;                  // throw the fetched words away, fetch from f_to
    reg [AW:1] f_to;
    reg [1:0]  used;                   // words taken from the buffer this clock

    always @(posedge clk) begin
        flush = 1'b0;
        f_to  = npc;
        used  = 2'd0;
        if (!WR_HANDSHAKE) wr_req <= 1'b0;

        if (rst) begin
            sp <= 4'd0;
            xs <= X_OFF;
            npc <= {AW{1'b0}}; xpc <= {AW{1'b0}};
            in2 <= 1'b0;
            bn <= 2'd0;
            fpc <= {AW{1'b0}};
            mem_req <= 1'b0;
            outst <= 1'b0;
            stale <= 1'b0;
            wr_req <= 1'b0;
        end else begin
            // ---- run
            if (WR_HANDSHAKE && wr_go) wr_req <= 1'b0;

            case (xs)
                X_RUN: if (have && !hold) begin
                    used = len;
                    xpc  <= npc;
                    npc  <= npc_n;
                    case (op)
                        OP_NEXT: ;
                        OP_WRITE: begin
                            wr_req <= 1'b1;
                            xs     <= WR_HANDSHAKE ? X_WR : X_GAP;
                        end
                        OP_WAIT: begin
                            w_line  <= pos_rel ? beam_v + {10'd0, beam_h >= pos_px} : pos_line;
                            w_px    <= pos_px;
                            w_never <= pos_rel ? (pos_px >= HTOT) : t_never;
                            w_blt   <= wait_blt;
                            xs      <= X_WAIT;
                        end
                        OP_SKIP: if (pos_rel ? t_preach : t_reach) begin
                            flush = 1'b1; f_to = npc_s;
                        end
                        OP_SKIPC: if (cond(cc, flags)) begin
                            flush = 1'b1; f_to = npc_s;
                        end
                        OP_JUMP: begin flush = 1'b1; f_to = target; end
                        OP_CALL: if (sp == 4'd8) stop;
                            else begin
                                stk[sp[2:0]] <= npc_n;
                                sp <= sp + 1'b1;
                                flush = 1'b1; f_to = target;
                            end
                        OP_RET: if (sp == 4'd0) stop;
                            else begin
                                sp <= sp - 1'b1;
                                flush = 1'b1; f_to = stk[sp[2:0] - 3'd1];
                            end
                        OP_MORE: xs <= X_MORE;
                        default: stop;                  // OP_STOP, OP_ERR, unknown
                    endcase
                end

                X_MORE: if (!hold) xs <= X_RUN;

                X_WAIT: if (!w_never && ((beam_v > w_line) || (beam_v == w_line && beam_h >= w_px))
                            && (!w_blt || blt_idle))
                    xs <= X_RUN;

                X_WR:  if (go) xs <= X_GAP;
                X_GAP: xs <= X_RUN;
                default: ;
            endcase

            // ---- starts and the frame restart (after run: they win)
            if (start1 && run) begin
                in2 <= 1'b0;
                restart(list1);
            end
            if (start2 && run) begin
                in2 <= 1'b1;
                restart(list2);
            end
            if (frame && run) begin
                in2 <= 1'b0;
                if (!stack_keep) sp <= 4'd0;
                restart(list1);
            end
            if (!run) begin                // off: stopped, as by STOP (not in list 2)
                xs  <= X_OFF;
                in2 <= 1'b0;
                if (WR_HANDSHAKE) wr_req <= 1'b0;
                if (xs != X_OFF) flush = 1'b1;
            end

            // ---- fetch: the buffer, less the words used, plus a word arriving
            begin : fetch
                reg [15:0] n0, n1, n2;
                reg [1:0]  nn;
                n0 = (used == 2'd1) ? b1 : (used == 2'd2) ? b2 : b0;
                n1 = (used == 2'd1) ? b2 : b1;
                n2 = b2;
                nn = bn - used;
                if (mem_ack) begin
                    mem_req <= 1'b0;
                    outst   <= 1'b1;
                end
                if (mem_rvalid) begin
                    outst <= 1'b0;
                    if (stale) stale <= 1'b0;
                    else if (!flush) begin
                        if (nn == 2'd0) n0 = mem_rdata; else if (nn == 2'd1) n1 = mem_rdata; else n2 = mem_rdata;
                        nn = nn + 2'd1;
                    end
                end
                b0 <= n0;
                b1 <= n1;
                b2 <= n2;
                bn <= nn;
            end
            if (flush) begin
                bn   <= 2'd0;
                fpc  <= f_to;
                npc  <= f_to;
                // A word asked for or on its way is dropped when it comes
                if (mem_req || mem_ack || (outst && !mem_rvalid)) stale <= 1'b1;
            end else if (!mem_req && !outst && !mem_ack && !mem_rvalid && !stale
                         && xs != X_OFF && (bn < 2'd2 || bn < need)) begin
                mem_req  <= 1'b1;
                mem_addr <= fpc;
                fpc      <= fpc + 1'b1;
            end

            if (stack_clear) sp <= 4'd0;
        end
    end

    task stop;
        begin
            xs  <= X_OFF;
            in2 <= 1'b0;
        end
    endtask

    task restart(input [AW:1] to);
        begin
            xs     <= X_RUN;
            wr_req <= 1'b0;
            flush  = 1'b1;
            f_to   = to;
        end
    endtask
endmodule
