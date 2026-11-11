// Audio engine: NCH sample channels from memory, mixed to one signed stereo
// sample every "rate" clocks (docs/spec/audio_engine.md). From retro68k's
// audio.v: the same sound, with the registers' bus, the interrupt and the
// DACs left to the machine.
//
// Each channel plays a block of 8- or 16-bit samples (LC, LEN) at a step
// of 4.16 samples per output sample, with a left and a right volume. At a
// block's end it takes LC and LEN again (a loop, or the next block queued)
// and strobes ev; a one-shot channel stops instead.
//
// The channels' settings are small RAMs, a field each, written by the
// machine through set_*; the engine reads them a channel at a time. A
// read-back (rb_re) borrows the engine's read for a clock, so it is always
// answered in the next clock. The blocks in play and the positions are
// RAMs the engine alone writes. One multiplier does the interpolation and
// both volumes in turn.
//
//   NCH     channels, 1 to 4
//   AW      word address width
//   LE      1: little-endian memory (of two 8-bit samples in a word, the
//           first is the low byte)
//   INTERP  0: no interpolation built (every channel as NEAREST)
//   RDBACK  0: no read-back (rb_q is 0)
module audio_engine #(
    parameter NCH    = 4,
    parameter AW     = 21,
    parameter LE     = 0,
    parameter INTERP = 1,
    parameter RDBACK = 1
) (
    input  wire            clk,
    input  wire            rst,            // every channel stopped; the settings stay

    input  wire [15:0]     rate,           // clocks per output sample (0: 65536)
    input  wire [NCH-1:0]  start,          // strobes: start (again) at the next output sample
    input  wire [NCH-1:0]  stop,           // strobes: stop; wins over start
    output reg  [NCH-1:0]  on,             // playing
    output reg  [NCH-1:0]  ev,             // strobes: took LC and LEN, or a one-shot block ended

    // Settings: fields 0 CTRL, 1 LC, 2 LEN, 3 STEP, 4 VOL (5 POS, read only)
    input  wire            set_we,
    input  wire [1:0]      set_ch,
    input  wire [2:0]      set_f,
    input  wire [23:0]     set_d,
    input  wire [2:0]      set_be,         // bytes written: bits 7-0, 15-8, 23-16
    input  wire            rb_re,          // (RDBACK) read field rb_f of channel rb_ch
    input  wire [1:0]      rb_ch,
    input  wire [2:0]      rb_f,
    output reg  [23:0]     rb_q,           // ... here in the next clock, and held

    // Memory (a requester on dmac.v): reads, one at a time
    output reg             mem_req,
    output reg  [AW-1:0]   mem_addr,
    input  wire            mem_ack,
    input  wire            mem_rvalid,
    input  wire [15:0]     mem_rdata,

    output reg  signed [15:0] out_l,       // the last output sample
    output reg  signed [15:0] out_r,
    output reg             out_v           // strobe: they are new
);
    localparam BW = AW + 1;                // a byte address, a length or a position in samples
    localparam TW = BW - 16;               // the top byte lane's width (1 to 8)

    // ================================================================ settings
    // A field a RAM, a byte lane each, so a machine can write bytes
    reg  [2:0]      s_ctrl [0:3];
    reg  [7:0]      s_lc0 [0:3], s_lc1 [0:3], s_len0 [0:3], s_len1 [0:3], s_st0 [0:3], s_st1 [0:3];
    reg  [TW-1:0]   s_lc2 [0:3], s_len2 [0:3];
    reg  [3:0]      s_st2 [0:3];
    reg  [6:0]      s_vl [0:3], s_vr [0:3];
    integer k;
    initial for (k = 0; k < 4; k = k + 1) begin
        s_ctrl[k] = 3'd0;
        s_lc0[k] = 8'd0;  s_lc1[k] = 8'd0;  s_lc2[k] = {TW{1'b0}};
        s_len0[k] = 8'd0; s_len1[k] = 8'd0; s_len2[k] = {TW{1'b0}};
        s_st0[k] = 8'd0;  s_st1[k] = 8'd0;  s_st2[k] = 4'd1;           // STEP 0x10000
        s_vl[k] = 7'd0;   s_vr[k] = 7'd0;
    end
    always @(posedge clk) if (set_we) begin
        if (set_f == 3'd0 && set_be[0]) s_ctrl[set_ch] <= set_d[2:0];
        if (set_f == 3'd1 && set_be[0]) s_lc0[set_ch]  <= set_d[7:0];
        if (set_f == 3'd1 && set_be[1]) s_lc1[set_ch]  <= set_d[15:8];
        if (set_f == 3'd1 && set_be[2]) s_lc2[set_ch]  <= set_d[16 +: TW];
        if (set_f == 3'd2 && set_be[0]) s_len0[set_ch] <= set_d[7:0];
        if (set_f == 3'd2 && set_be[1]) s_len1[set_ch] <= set_d[15:8];
        if (set_f == 3'd2 && set_be[2]) s_len2[set_ch] <= set_d[16 +: TW];
        if (set_f == 3'd3 && set_be[0]) s_st0[set_ch]  <= set_d[7:0];
        if (set_f == 3'd3 && set_be[1]) s_st1[set_ch]  <= set_d[15:8];
        if (set_f == 3'd3 && set_be[2]) s_st2[set_ch]  <= set_d[19:16];
        if (set_f == 3'd4 && set_be[0]) s_vr[set_ch]   <= set_d[6:0];
        if (set_f == 3'd4 && set_be[2]) s_vl[set_ch]   <= set_d[22:16];
    end

    // One read of them all: the engine's channel, or a read-back's for its clock
    reg  [1:0]      ch;
    wire            stall = (RDBACK != 0) && rb_re;
    wire [1:0]      sa    = stall ? rb_ch : ch;
    wire [2:0]      q_ctrl = s_ctrl[sa];
    wire [BW-1:0]   q_lc   = {s_lc2[sa], s_lc1[sa], s_lc0[sa]};
    wire [BW-1:0]   q_len  = {s_len2[sa], s_len1[sa], s_len0[sa]};
    wire [19:0]     q_step = {s_st2[sa], s_st1[sa], s_st0[sa]};
    wire [6:0]      q_vl   = s_vl[sa], q_vr = s_vr[sa];
    function [6:0] vclip(input [6:0] v);
        vclip = (v > 7'd64) ? 7'd64 : v;
    endfunction

    // ================================================================ the blocks in play
    reg  [BW-1:0]    b_lc [0:3], b_len [0:3];
    reg  [BW+15:0]   pos  [0:3];               // samples, and a 16-bit fraction
    wire [BW-1:0]    p_lc = b_lc[sa], p_len = b_len[sa];
    initial for (k = 0; k < 4; k = k + 1) begin
        b_lc[k] = {BW{1'b0}};  b_len[k] = {BW{1'b0}};  pos[k] = {(BW+16){1'b0}};
    end
    wire [BW+15:0]   p_pos = pos[sa];

    always @(posedge clk) begin
        if (rst || RDBACK == 0) rb_q <= 24'd0;
        else if (rb_re) case (rb_f)
            3'd0:    rb_q <= {21'd0, q_ctrl};
            3'd1:    rb_q <= 24'd0 | q_lc;
            3'd2:    rb_q <= 24'd0 | q_len;
            3'd3:    rb_q <= {4'd0, q_step};
            3'd4:    rb_q <= {1'b0, q_vl, 9'd0, q_vr};
            3'd5:    rb_q <= 24'd0 | p_pos[BW+15:16];
            default: rb_q <= 24'd0;
        endcase
    end

    // ================================================================ engine
    localparam E_IDLE = 4'd0, E_CH = 4'd1, E_GO = 4'd2, E_RD0 = 4'd3, E_RD1 = 4'd4, E_INT = 4'd5,
               E_W1 = 4'd6, E_MIX = 4'd7, E_W2 = 4'd8, E_L = 4'd9, E_W3 = 4'd10, E_R = 4'd11,
               E_ADV = 4'd12, E_OUT = 4'd13, E_G2 = 4'd14;
    reg  [3:0]      es;
    reg  [15:0]     cnt;                       // clocks to the next output sample; 0: due
    reg  [NCH-1:0]  startp;                    // starts waiting
    reg  [2:0]      c_ctrl;                    // the channel's settings, as taken when it was begun
    reg  [19:0]     c_step;
    reg  [6:0]      c_vl, c_vr;
    reg  [BW-1:0]   a0, a1;                    // byte addresses of s0 and s1
    reg  [15:0]     frac;
    reg             d_v;                       // a word has come back
    reg  [15:0]     d_r, d0, d1;
    reg  signed [15:0] s0_r, smp;
    reg  signed [16:0] ma, mb;                 // the multiplier's inputs
    reg  signed [33:0] mp;                     // ... and its product, a clock later
    // (the sums stay out of the multiplier's DSP block, or the tools build one for each)
    (* use_dsp = "no" *) reg signed [23:0] acc_l, acc_r;
    reg             pend;                      // a read is out: only then is a word back taken
    reg             i1ok;                      // the sample after this one is in the block
    reg  [BW+15:0]  pn, pw;                    // the next position; and less the block's length
    reg  [BW-1:0]   cl;                        // the block's length
    reg             pastr;                     // the next position is past the block's end

    wire            b16    = c_ctrl[0];
    wire            near   = (INTERP == 0) || c_ctrl[1];

    // The channel's place (E_GO)
    wire [BW-1:0]   ip   = p_pos[BW+15:16];
    wire [BW-1:0]   ipn  = ip + 1'b1;
    wire [BW-1:0]   pa0  = p_lc + (b16 ? {ip[BW-2:0], 1'b0}  : ip);
    // At a block's last sample s1 is the first sample of the block to come:
    // the one at the address register now (not for a one-shot, or a length of 0)
    // (worked out a clock after a0, from a0, to keep the paths short: E_G2)
    wire            xend = !i1ok && !c_ctrl[2] && (q_len != {BW{1'b0}});
    wire [BW-1:0]   pa1  = xend ? q_lc : a0 + {{(BW-2){1'b0}}, i1ok && b16, i1ok && !b16};
    function signed [15:0] pick(input [15:0] w, input odd, input b16_);
        pick = b16_ ? w : {(odd == (LE == 0)) ? w[7:0] : w[15:8], 8'd0};
    endfunction

    // Moving on: the sums are made in the clocks of the volume multiplies
    // (pn and cl in E_L, pw and pastr in E_W3), and used in E_ADV
    wire [BW+15:0]  pnext = pn;
    wire            past  = pastr;
    wire [BW+15:0]  pwrap = pw;

    wire            take  = startp[ch] && !stop[ch];
    wire            last_ch = ({30'd0, ch} == NCH - 1);
    integer i;

    always @(posedge clk) begin
        ev    <= {NCH{1'b0}};
        out_v <= 1'b0;
        mp    <= ma * mb;
        if (mem_ack) mem_req <= 1'b0;
        if (mem_rvalid && pend) begin
            d_v  <= 1'b1;
            d_r  <= mem_rdata;
            pend <= 1'b0;
        end
        if (rst) begin
            es <= E_IDLE;  cnt <= 16'd0;  ch <= 2'd0;
            on <= {NCH{1'b0}};  startp <= {NCH{1'b0}};
            mem_req <= 1'b0;  d_v <= 1'b0;  pend <= 1'b0;
            out_l <= 16'sd0;  out_r <= 16'sd0;
        end else begin
            if (cnt != 16'd0) cnt <= cnt - 1'b1;

            // (a read-back holds the engine for its clock, but not the start of
            // an output sample, which reads nothing: the period stays exact)
            if (!stall || es == E_IDLE) case (es)
                E_IDLE: if (cnt == 16'd0) begin
                    cnt   <= rate - 1'b1;
                    acc_l <= 24'sd0;
                    acc_r <= 24'sd0;
                    ch    <= 2'd0;
                    es    <= E_CH;
                end

                // The channel is begun: its settings are taken, and a start
                // waiting takes the block
                E_CH: begin
                    c_ctrl <= q_ctrl;
                    c_step <= q_step;
                    c_vl   <= vclip(q_vl);
                    c_vr   <= vclip(q_vr);
                    if (take) begin
                        b_lc[ch]   <= q_lc;
                        b_len[ch]  <= q_len;
                        pos[ch]    <= {(BW+16){1'b0}};
                        ev[ch]     <= 1'b1;
                        on[ch]     <= (q_len != {BW{1'b0}});
                        startp[ch] <= 1'b0;
                    end
                    if (take ? (q_len != {BW{1'b0}}) : (on[ch] && !stop[ch])) es <= E_GO;
                    else if (last_ch) es <= E_OUT;
                    else ch <= ch + 1'b1;
                end

                E_GO: begin
                    a0   <= pa0;
                    frac <= p_pos[15:0];
                    i1ok <= (ipn < p_len);
                    es   <= E_G2;
                end

                E_G2: begin
                    a1       <= pa1;
                    d_v      <= 1'b0;
                    mem_req  <= 1'b1;  pend <= 1'b1;
                    mem_addr <= a0[BW-1:1];
                    es       <= E_RD0;
                end

                E_RD0: if (d_v) begin
                    d_v <= 1'b0;
                    d0  <= d_r;
                    d1  <= d_r;
                    if (!near && a1[BW-1:1] != a0[BW-1:1]) begin
                        mem_req  <= 1'b1;  pend <= 1'b1;
                        mem_addr <= a1[BW-1:1];
                        es       <= E_RD1;
                    end else es <= E_INT;
                end

                E_RD1: if (d_v) begin
                    d_v <= 1'b0;
                    d1  <= d_r;
                    es  <= E_INT;
                end

                E_INT: begin : interp
                    reg signed [15:0] s0, s1;
                    s0   = pick(d0, a0[0], b16);
                    s1   = pick(d1, a1[0], b16);
                    s0_r <= s0;
                    if (near) begin
                        smp <= s0;
                        ma  <= {s0[15], s0};
                        mb  <= {10'd0, c_vl};
                        es  <= E_W2;
                    end else begin
                        ma  <= {s1[15], s1} - {s0[15], s0};
                        mb  <= {1'b0, frac};
                        es  <= E_W1;
                    end
                end

                E_W1: es <= E_MIX;

                E_MIX: begin : mix
                    reg signed [15:0] s;
                    s   = s0_r + mp[31:16];
                    smp <= s;
                    ma  <= {s[15], s};
                    mb  <= {10'd0, c_vl};
                    es  <= E_W2;
                end

                E_W2: es <= E_L;

                E_L: begin
                    acc_l <= acc_l + mp[23:0];
                    mb    <= {10'd0, c_vr};
                    pn    <= p_pos + {{(BW-4){1'b0}}, c_step};
                    cl    <= p_len;
                    es    <= E_W3;
                end

                E_W3: begin
                    pw    <= pn - {cl, 16'd0};
                    pastr <= (pn[BW+15:16] >= cl);
                    es    <= E_R;
                end

                E_R: begin
                    acc_r <= acc_r + mp[23:0];
                    es    <= E_ADV;
                end

                E_ADV: begin
                    if (past && c_ctrl[2]) begin
                        on[ch] <= 1'b0;                             // a one-shot block is done
                        ev[ch] <= 1'b1;
                    end else if (past) begin
                        b_lc[ch]  <= q_lc;                          // on into the next block
                        b_len[ch] <= q_len;
                        pos[ch]   <= (pwrap[BW+15:16] < q_len) ? pwrap : {{BW{1'b0}}, pwrap[15:0]};
                        ev[ch]    <= 1'b1;
                        if (q_len == {BW{1'b0}}) on[ch] <= 1'b0;
                    end else
                        pos[ch] <= pnext;
                    if (last_ch) es <= E_OUT;
                    else begin
                        ch <= ch + 1'b1;
                        es <= E_CH;
                    end
                end

                E_OUT: begin
                    out_l <= acc_l[23:8];
                    out_r <= acc_r[23:8];
                    out_v <= 1'b1;
                    es    <= E_IDLE;
                end

                default: es <= E_IDLE;
            endcase

            // Starting and stopping (after the engine: a stop wins)
            for (i = 0; i < NCH; i = i + 1) begin
                if (start[i]) startp[i] <= 1'b1;
                if (stop[i]) begin
                    startp[i] <= 1'b0;
                    on[i]     <= 1'b0;
                end
            end
        end
    end
endmodule
