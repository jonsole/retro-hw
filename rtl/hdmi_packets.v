// HDMI data islands for a DVI picture (docs/spec/hdmi_packets.md): turns
// a plain video stream (rgb, syncs, de) into what three tmds_encoders with
// HDMI = 1 need to send it as HDMI with stereo 16-bit audio.
//
// The picture goes through 12 pixel clocks late, so the unit sees the
// start of each line's picture coming and can put the video preamble and
// guard band in front of it. In every line's blank, at a fixed place after
// the picture ends, it sends one data island of two packets:
//
//   the first   up to four stereo samples (an Audio Sample packet), or a
//               null packet when none is waiting;
//   the second  what is due: Audio Clock Regeneration (N = 6144, CTS as
//               measured, after every 48 samples), then once a frame the
//               AVI InfoFrame (RGB, full range, 4:3, the VIC parameter) and
//               the Audio InfoFrame; else a null packet.
//
// It needs no line or frame numbers: it learns the line's length from de,
// and wants a blank of at least 92 pixels. Samples come on the system
// clock and cross here: one at a time through a toggle (a sample must stay
// for the few pixel clocks the crossing takes, which any audio rate does).
//
// "on" low (taken at each frame's start) sends the picture as DVI: no
// preambles, guard bands or islands, as tmds_encoder alone would.
module hdmi_packets #(
    parameter VIC = 17                 // the AVI InfoFrame's video code: 17 is 720 x 576p50 at 4:3
) (
    input  wire        clk_pix,
    input  wire        rst,            // synchronous to clk_pix
    input  wire [23:0] rgb,
    input  wire        hsync, vsync,   // as sent
    input  wire        de,
    input  wire        on,             // 1: HDMI with audio. 0: DVI. A level, from any clock

    // The sound, on the system clock
    input  wire        clk,
    input  wire [15:0] aud_l, aud_r,   // signed
    input  wire        aud_v,          // strobe: a new sample

    // To the encoders: lane 0 blue, 1 green, 2 red
    output reg  [23:0] o_rgb,
    output reg         o_de,
    output reg  [1:0]  o_c0, o_c1, o_c2,    // control bits (lane 0: {vsync, hsync})
    output reg  [1:0]  o_m0, o_m1, o_m2,    // 0: as o_de says. 1: guard band. 2: TERC4
    output reg         o_g2,                // lane 2's guard band pattern
    output reg  [3:0]  o_a0, o_a1, o_a2     // TERC4 data
);
    // ================================================================ the sound crosses
    reg  [15:0] h_l, h_r;
    reg         h_t = 1'b0;
    always @(posedge clk) if (aud_v) begin
        h_l <= aud_l;  h_r <= aud_r;  h_t <= ~h_t;
    end
    (* ASYNC_REG = "TRUE" *) reg [1:0] t_s = 2'b00;
    reg         t_d = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] on_s = 2'b00;
    always @(posedge clk_pix) begin
        t_s  <= {t_s[0], h_t};
        t_d  <= t_s[1];
        on_s <= {on_s[0], on};
    end
    wire        stb = (t_s[1] != t_d);         // a sample is steady in h_l, h_r

    // A few samples wait for the next line's island
    reg  [31:0] fifo [0:7];
    reg  [2:0]  wp, rp;
    reg  [3:0]  fcnt;                          // samples waiting
    wire        push = stb && !fcnt[3];
    wire [31:0] f_q  = fifo[rp];
    always @(posedge clk_pix) if (push) fifo[wp] <= {h_r, h_l};

    // Clock regeneration: CTS is the pixel clocks in N / 128 = 48 samples
    reg  [19:0] cts_c, cts;
    reg  [5:0]  sc;
    reg         c_run;                         // the count has begun at a sample
    reg  [11:0] gap;                           // clocks since the last sample

    // ================================================================ the picture, late
    // de_t[k] is de, k + 1 clocks late; the picture goes out with de_t[10]
    reg  [10:0] de_t;
    reg  [25:0] dl [0:10];                     // {rgb, vsync, hsync}
    integer k;
    always @(posedge clk_pix) begin
        de_t  <= rst ? 11'd0 : {de_t[9:0], de};
        dl[0] <= {rgb, vsync, hsync};
        for (k = 1; k <= 10; k = k + 1) dl[k] <= dl[k-1];
    end
    wire        d_now = de_t[10];
    wire [23:0] v_rgb = dl[10][25:2];
    wire        vs    = dl[10][1];
    wire        hs    = dl[10][0];
    reg         d_prev, vs_prev;

    // The place in the line: 0 at the blank's first pixel. The line's length
    // is learnt from one picture line's end to the next, and carries the
    // count through the lines with no picture
    reg  [11:0] x_r, hlen;
    reg         seen, learnt, on_f;
    wire        fall = d_prev && !d_now;
    wire [11:0] x    = fall ? 12'd0 : x_r;
    wire        isl  = on_f && learnt && !d_now;        // this line's blank has an island

    localparam [11:0] X_PRE = 12'd4, X_GB1 = 12'd12, X_PKT = 12'd14, X_GB2 = 12'd78, X_END = 12'd80;
    wire        x_pre = isl && x >= X_PRE && x < X_GB1;
    wire        x_gb  = isl && ((x >= X_GB1 && x < X_PKT) || (x >= X_GB2 && x < X_END));
    wire        x_pkt = isl && x >= X_PKT && x < X_GB2;
    wire [11:0] pk_x  = x - X_PKT;
    wire [4:0]  pp    = pk_x[4:0];                       // the pixel in the packet
    // The picture's own lead-in: 8 clocks of preamble, then 2 of guard band
    wire        v_pre = on_f && !de_t[8] && de_t[0];
    wire        v_gb  = on_f && !de_t[10] && de_t[8];

    // ================================================================ the packets
    // BCH(64, 56) and (32, 24) with x^8 + x^7 + x^6 + 1, a bit at a time, low bit first
    function [7:0] ecc1(input [7:0] e, input b);
        ecc1 = (e >> 1) ^ ((e[0] ^ b) ? 8'h83 : 8'h00);
    endfunction

    // The IEC 60958 channel status, consumer: linear PCM, copy allowed, 48 kHz,
    // 16 bits; the left channel is number 1, the right 2
    function cs_bit(input [7:0] f, input right);
        cs_bit = (f == 8'd2) || (f == (right ? 8'd21 : 8'd20)) || (f == 8'd25) || (f == 8'd33);
    endfunction

    localparam [7:0] AVI_1 = 8'h02,            // RGB; underscanned
                     AVI_2 = 8'h18,            // 4:3; active picture as the picture
                     AVI_3 = 8'h08,            // full range
                     AVI_4 = VIC;
    localparam [7:0] AVI_0 = 8'd0 - (8'h82 + 8'h02 + 8'h0D + AVI_1 + AVI_2 + AVI_3 + AVI_4);
    localparam [7:0] AIF_1 = 8'h01;            // 2 channels; the rest as the stream says
    localparam [7:0] AIF_0 = 8'd0 - (8'h84 + 8'h01 + 8'h0A + AIF_1);

    reg         acr_due, avi_due, aif_due;
    reg  [1:0]  b_kind;                        // the second packet: 0 null, 1 ACR, 2 AVI, 3 audio InfoFrame
    reg         a_aud;                         // the first packet has samples
    reg  [15:0] s_l [0:3], s_r [0:3];          // its samples
    reg  [3:0]  s_p, s_b, s_cl, s_cr;          // present; first of a block of 192; channel status bits
    reg  [7:0]  blk;                           // the sample's place in its block of 192

    function [55:0] sub_aud(input [15:0] l, input [15:0] r, input cl, input cr);
        sub_aud = {^{r, cr}, cr, 2'b00, ^{l, cl}, cl, 2'b00, r, 8'd0, l, 8'd0};
    endfunction
    wire [55:0] sub_acr = {8'h00, 8'h18, 8'h00, cts[7:0], cts[15:8], 4'd0, cts[19:16], 8'h00};    // N = 6144

    reg  [23:0] hdr;                           // going out, low bit first
    reg  [55:0] sp [0:3];
    reg  [7:0]  he, se [0:3];                  // their check bytes as they build
    wire [1:0]  x_slot = x[1:0] - 2'd1;        // x 1 to 4: which sample is fetched

    integer n;
    always @(posedge clk_pix) begin
        d_prev  <= d_now;
        vs_prev <= vs;
        if (rst) begin
            x_r <= 12'd0;  hlen <= 12'hFFF;  seen <= 1'b0;  learnt <= 1'b0;  on_f <= 1'b0;
            wp <= 3'd0;  rp <= 3'd0;  fcnt <= 4'd0;  blk <= 8'd0;
            cts_c <= 20'd0;  sc <= 6'd0;  c_run <= 1'b0;  gap <= 12'd0;
            acr_due <= 1'b0;  avi_due <= 1'b0;  aif_due <= 1'b0;
            a_aud <= 1'b0;  b_kind <= 2'd0;  s_p <= 4'd0;
        end else begin
            // the place in the line
            if (fall) begin
                seen <= 1'b1;
                if (seen) begin hlen <= x_r;  learnt <= 1'b1; end
            end
            x_r <= (!d_now && learnt && x == hlen - 1'b1) ? 12'd0 : x + 1'b1;
            // a frame begins
            if (vs && !vs_prev) begin
                on_f    <= on_s[1];
                avi_due <= 1'b1;
                aif_due <= 1'b1;
            end

            // samples in
            cts_c <= cts_c + 1'b1;
            // (the samples stopping for 4,096 clocks starts the count afresh, so a
            // pause gives no false CTS)
            gap <= stb ? 12'd0 : gap + 1'b1;
            if (gap == 12'hFFF) c_run <= 1'b0;
            if (stb && !c_run) begin
                c_run <= 1'b1;  cts_c <= 20'd0;  sc <= 6'd0;
            end else if (stb) begin
                if (sc == 6'd47) begin
                    sc <= 6'd0;  cts <= cts_c + 1'b1;  cts_c <= 20'd0;  acr_due <= 1'b1;
                end else sc <= sc + 1'b1;
            end
            if (push) wp <= wp + 1'b1;
            fcnt <= fcnt + {3'd0, push};                     // (less the one fetched, below)

            // this line's two packets are chosen as its blank begins
            if (isl && x == 12'd0) begin
                a_aud <= (fcnt != 4'd0);
                s_p   <= 4'd0;
                if (acr_due)      begin b_kind <= 2'd1;  acr_due <= 1'b0; end
                else if (avi_due) begin b_kind <= 2'd2;  avi_due <= 1'b0; end
                else if (aif_due) begin b_kind <= 2'd3;  aif_due <= 1'b0; end
                else              b_kind <= 2'd0;
            end
            // up to four samples are fetched
            if (isl && x >= 12'd1 && x <= 12'd4 && a_aud && fcnt != 4'd0) begin
                s_l[x_slot]  <= f_q[15:0];
                s_r[x_slot]  <= f_q[31:16];
                s_p[x_slot]  <= 1'b1;
                s_b[x_slot]  <= (blk == 8'd0);
                s_cl[x_slot] <= cs_bit(blk, 1'b0);
                s_cr[x_slot] <= cs_bit(blk, 1'b1);
                blk  <= (blk == 8'd191) ? 8'd0 : blk + 1'b1;
                rp   <= rp + 1'b1;
                fcnt <= fcnt + {3'd0, push} - 4'd1;
            end

            // the packets go out: the header a bit a clock, each subpacket two
            if (isl && x == X_PKT - 1'b1) begin
                // the first packet
                he <= 8'd0;
                for (n = 0; n < 4; n = n + 1) begin
                    se[n] <= 8'd0;
                    sp[n] <= s_p[n] ? sub_aud(s_l[n], s_r[n], s_cl[n], s_cr[n]) : 56'd0;
                end
                hdr <= (s_p != 4'd0) ? {s_b & s_p, 4'd0, 4'd0, s_p, 8'h02} : 24'd0;
            end else if (x_pkt && pk_x == 12'd31) begin
                // the second
                he <= 8'd0;
                for (n = 0; n < 4; n = n + 1) begin
                    se[n] <= 8'd0;
                    sp[n] <= (b_kind == 2'd1) ? sub_acr : 56'd0;
                end
                case (b_kind)
                    2'd1: hdr <= 24'h000001;
                    2'd2: begin
                        hdr   <= 24'h0D0282;
                        sp[0] <= {8'h00, 8'h00, AVI_4, AVI_3, AVI_2, AVI_1, AVI_0};
                    end
                    2'd3: begin
                        hdr   <= 24'h0A0184;
                        sp[0] <= {40'd0, AIF_1, AIF_0};
                    end
                    default: hdr <= 24'd0;
                endcase
            end else if (x_pkt) begin
                hdr <= hdr >> 1;
                he  <= (pp < 5'd24) ? ecc1(he, hdr[0]) : he >> 1;
                for (n = 0; n < 4; n = n + 1) begin
                    sp[n] <= sp[n] >> 2;
                    se[n] <= (pp < 5'd28) ? ecc1(ecc1(se[n], sp[n][0]), sp[n][1]) : se[n] >> 2;
                end
            end
        end
    end

    // This pixel's bits
    wire        h_b  = (pp < 5'd24) ? hdr[0] : he[0];
    wire        body = (pp < 5'd28);
    wire [3:0]  b_lo = {body ? sp[3][0] : se[3][0], body ? sp[2][0] : se[2][0],
                        body ? sp[1][0] : se[1][0], body ? sp[0][0] : se[0][0]};
    wire [3:0]  b_hi = {body ? sp[3][1] : se[3][1], body ? sp[2][1] : se[2][1],
                        body ? sp[1][1] : se[1][1], body ? sp[0][1] : se[0][1]};

    // ================================================================ out
    always @(posedge clk_pix) begin
        o_rgb <= v_rgb;
        o_de  <= d_now;
        o_c0  <= {vs, hs};
        o_c1  <= (v_pre || x_pre) ? 2'b01 : 2'b00;           // CTL0: a data period follows
        o_c2  <= x_pre ? 2'b01 : 2'b00;                      // CTL2: ... and it is an island
        o_m0  <= 2'd0;  o_m1 <= 2'd0;  o_m2 <= 2'd0;
        o_g2  <= 1'b0;
        o_a0  <= {1'b1, 1'b1, vs, hs};
        o_a1  <= b_lo;
        o_a2  <= b_hi;
        if (v_gb) begin
            o_m0 <= 2'd1;  o_m1 <= 2'd1;  o_m2 <= 2'd1;      // the picture's guard band
        end else if (x_gb) begin
            o_m0 <= 2'd2;  o_m1 <= 2'd1;  o_m2 <= 2'd1;  o_g2 <= 1'b1;   // an island's
        end else if (x_pkt) begin
            o_m0 <= 2'd2;  o_m1 <= 2'd2;  o_m2 <= 2'd2;
            o_a0 <= {pk_x != 12'd0, h_b, vs, hs};            // (bit 3: 0 in the island's first pixel only)
        end
    end
endmodule
