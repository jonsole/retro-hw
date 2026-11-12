// hdmi_packets.v with three tmds_encoders (HDMI = 1), checked by a decoder
// of the 10-bit words as an HDMI sink reads them.
//
// A small picture (200 x 6 in lines of 300, frames of 10 lines) with random
// pixels, and random samples on a system clock that is not the pixel
// clock's. The decoder follows the stream's periods by HDMI's rules and
// checks:
//   - the picture, de and the syncs come out as they went in, LAT clocks
//     late (the syncs also inside islands, from lane 0's TERC4 bits);
//   - every data period has its 8-clock preamble and 2-clock guard band,
//     and 12 or more control words stand between two data periods;
//   - every packet's header and four subpackets divide by the BCH
//     polynomial (a long division here, not the core's shift register);
//   - Audio Sample packets carry every sample sent, once, in order, with
//     its parity, channel status (48 kHz, 16 bits, left 1 and right 2) and
//     block starts every 192 samples;
//   - Audio Clock Regeneration has N = 6144 and the CTS the two clocks give;
//   - the AVI and Audio InfoFrames come once a frame, sum to zero and say
//     RGB, full range, 4:3, the VIC, two channels;
//   - with "on" low the stream is DVI: only control words and pixels.
`timescale 1ns/1ps
module tb_hdmi_packets;
    parameter HACT = 200, HTOT = 300, VACT = 6, VTOT = 10;
    parameter APER = 361;                  // system clocks a sample
    localparam LAT = 13;                   // the core's 12 clocks and the encoder's 1

    reg clk_pix = 1'b0, clk = 1'b0;
    always #18.5 clk_pix = ~clk_pix;       // 37 ns
    always #5    clk     = ~clk;           // 10 ns
    reg rst = 1'b1, on = 1'b1;

    // ---------------------------------------------------------------- the picture
    integer hc = 0, vc = 0, frames = 0;
    reg [23:0] rgb = 24'd0;
    reg        hsync = 1'b1, vsync = 1'b1, de = 1'b0;
    always @(posedge clk_pix) begin
        if (hc == HTOT - 1) begin
            hc <= 0;
            if (vc == VTOT - 1) begin vc <= 0; frames <= frames + 1; end else vc <= vc + 1;
        end else hc <= hc + 1;
        de    <= (hc < HACT) && (vc < VACT);
        hsync <= !(hc >= HACT + 10 && hc < HACT + 40);          // active low, as 576p's
        vsync <= !(vc >= VACT + 1 && vc < VACT + 3);
        rgb   <= $random;
    end

    // ---------------------------------------------------------------- the sound
    reg [15:0] aud_l = 16'd0, aud_r = 16'd0;
    reg        aud_v = 1'b0;
    reg [31:0] sent [0:65535];
    integer    n_sent = 0, acnt = 0;
    reg        aud_run = 1'b1;                 // 0: no samples come (a machine with its sound stopped)
    always @(posedge clk) begin
        aud_v <= 1'b0;
        if (!rst) begin
            acnt <= (acnt == APER - 1) ? 0 : acnt + 1;
            if (acnt == 0 && aud_run) begin
                aud_l <= $random;  aud_r <= $random;  aud_v <= 1'b1;
            end
        end
        if (aud_v) begin sent[n_sent] = {aud_r, aud_l};  n_sent = n_sent + 1; end
    end

    // ---------------------------------------------------------------- the unit and its encoders
    wire [23:0] p_rgb;
    wire        p_de, p_g2;
    wire [1:0]  p_c0, p_c1, p_c2, p_m0, p_m1, p_m2;
    wire [3:0]  p_a0, p_a1, p_a2;
    wire [9:0]  q0, q1, q2;
    hdmi_packets #(.VIC(17)) dut (
        .clk_pix(clk_pix), .rst(rst), .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de), .on(on),
        .clk(clk), .aud_l(aud_l), .aud_r(aud_r), .aud_v(aud_v),
        .o_rgb(p_rgb), .o_de(p_de), .o_c0(p_c0), .o_c1(p_c1), .o_c2(p_c2),
        .o_m0(p_m0), .o_m1(p_m1), .o_m2(p_m2), .o_g2(p_g2), .o_a0(p_a0), .o_a1(p_a1), .o_a2(p_a2));
    tmds_encoder #(.HDMI(1)) e0 (.clk(clk_pix), .d(p_rgb[7:0]),   .c(p_c0), .de(p_de), .m(p_m0), .g(1'b0), .a(p_a0), .q(q0));
    tmds_encoder #(.HDMI(1)) e1 (.clk(clk_pix), .d(p_rgb[15:8]),  .c(p_c1), .de(p_de), .m(p_m1), .g(1'b1), .a(p_a1), .q(q1));
    tmds_encoder #(.HDMI(1)) e2 (.clk(clk_pix), .d(p_rgb[23:16]), .c(p_c2), .de(p_de), .m(p_m2), .g(p_g2), .a(p_a2), .q(q2));

    // ---------------------------------------------------------------- the sink
    localparam [9:0] GA = 10'b1011001100, GB = 10'b0100110011;
    function [2:0] ctl(input [9:0] w);              // {is a control word, c1, c0}
        case (w)
            10'b1101010100: ctl = 3'b100;
            10'b0010101011: ctl = 3'b101;
            10'b0101010100: ctl = 3'b110;
            10'b1010101011: ctl = 3'b111;
            default:        ctl = 3'b000;
        endcase
    endfunction
    function [4:0] terc(input [9:0] w);             // {is a TERC4 word, its four bits}
        case (w)
            10'b1010011100: terc = 5'h10;  10'b1001100011: terc = 5'h11;
            10'b1011100100: terc = 5'h12;  10'b1011100010: terc = 5'h13;
            10'b0101110001: terc = 5'h14;  10'b0100011110: terc = 5'h15;
            10'b0110001110: terc = 5'h16;  10'b0100111100: terc = 5'h17;
            10'b1011001100: terc = 5'h18;  10'b0100111001: terc = 5'h19;
            10'b0110011100: terc = 5'h1A;  10'b1011000110: terc = 5'h1B;
            10'b1010001110: terc = 5'h1C;  10'b1001110001: terc = 5'h1D;
            10'b0101100011: terc = 5'h1E;  10'b1011000011: terc = 5'h1F;
            default:        terc = 5'h00;
        endcase
    endfunction
    function [7:0] tmds8(input [9:0] w);
        reg [7:0] v;
        integer i;
        begin
            v = w[9] ? ~w[7:0] : w[7:0];
            tmds8[0] = v[0];
            for (i = 1; i < 8; i = i + 1) tmds8[i] = w[8] ? (v[i] ^ v[i-1]) : ~(v[i] ^ v[i-1]);
        end
    endfunction
    // Does a block (bits in the order sent, n of them, check byte last) divide
    // by x^8 + x^7 + x^6 + 1? The first bit sent is the highest power
    function bch_ok(input [63:0] blk, input integer n);
        reg [63:0] r;
        integer i;
        begin
            r = 64'd0;
            for (i = 0; i < n; i = i + 1) r[n - 1 - i] = blk[i];      // the first sent to the top
            for (i = n - 1; i >= 8; i = i - 1)
                if (r[i]) r = r ^ (64'h1C1 << (i - 8));               // 1_1100_0001: the polynomial
            bch_ok = (r[7:0] == 8'd0);
        end
    endfunction

    integer errors = 0, cyc = 0;
    task fail(input [8*40-1:0] what, input integer got, input integer want);
        begin
            errors = errors + 1;
            if (errors <= 15) $display("ERROR @%0d (line %0d, pixel %0d): %0s: got %0d (%h), want %0d (%h)", cyc, vc, hc, what, got, got, want, want);
        end
    endtask

    // the inputs, LAT clocks ago
    reg [26:0] past [0:LAT];
    integer    j;
    always @(posedge clk_pix) begin
        past[0] <= {rgb, vsync, hsync, de};
        for (j = 1; j <= LAT; j = j + 1) past[j] <= past[j-1];
    end
    wire [23:0] x_rgb = past[LAT-1][26:3];
    wire        x_vs  = past[LAT-1][2], x_hs = past[LAT-1][1], x_de = past[LAT-1][0];

    localparam S_CTL = 0, S_VGB = 1, S_VID = 2, S_IGB = 3, S_PKT = 4, S_IGE = 5;
    integer st = S_CTL, n_ctl = 100, n_vpre = 0, n_ipre = 0, gcnt = 0, pix = 0, pkt_in_isl = 0;
    reg [31:0] hbits;
    reg [63:0] sb [0:3];
    reg        hdmi_seen = 1'b0;                   // islands or guard bands have come since "on" last changed
    integer n_isl = 0, n_aud = 0, n_smp = 0, n_acr = 0, n_avi = 0, n_aif = 0, n_null = 0, n_skip = 0,
            n_vid = 0, n_blk = 0, n_dvi_lines = 0, n_full = 0, n_null1 = 0;
    integer rx = 0, blk_i = 0, s, i2, sum;
    reg        relax = 1'b1, dvi_expected = 1'b0;
    reg [2:0]  k0, k1, k2;
    reg [4:0]  t0, t1, t2;
    reg [55:0] d;
    reg [23:0] hb;
    reg [15:0] gl, gr;
    reg        cl, cr;
    integer    cts_got;
    real       cts_want;

    task packet;
        begin
            hb = hbits[23:0];
            if (!bch_ok({32'd0, hbits}, 32)) fail("header check byte", hbits, 0);
            for (s = 0; s < 4; s = s + 1) if (!bch_ok(sb[s], 64)) fail("subpacket check byte", s, 0);
            case (hb[7:0])
                8'h00: begin
                    n_null = n_null + 1;
                    if (pkt_in_isl == 0) n_null1 = n_null1 + 1;
                    if (hb != 24'd0 || sb[0][55:0] != 0 || sb[1][55:0] != 0 || sb[2][55:0] != 0 || sb[3][55:0] != 0) fail("null packet not empty", hb, 0);
                end
                8'h02: begin
                    n_aud = n_aud + 1;
                    if (pkt_in_isl != 0) fail("samples not in the first packet", pkt_in_isl, 0);
                    if (hb[12] !== 1'b0 || hb[15:13] !== 3'd0 || hb[19:16] !== 4'd0) fail("audio header", hb, 0);
                    if (hb[11:8] == 4'd0) fail("audio packet with no sample", 0, 1);
                    for (s = 0; s < 4; s = s + 1) begin
                        d = sb[s][55:0];
                        if (hb[8 + s]) begin
                            if (s > 0 && !hb[8 + s - 1]) fail("samples not packed from 0", s, 0);
                            gl = d[23:8];  gr = d[47:32];
                            if (d[7:0] !== 8'd0 || d[31:24] !== 8'd0) fail("sample's low byte", d[7:0], 0);
                            // every sample once, in order (after a spell of DVI some are lost: the FIFO fills)
                            while (rx < n_sent && sent[rx] !== {gr, gl} && relax) begin rx = rx + 1; n_skip = n_skip + 1; end
                            if (rx >= n_sent || sent[rx] !== {gr, gl}) fail("sample", {gr, gl}, rx < n_sent ? sent[rx] : 0);
                            else rx = rx + 1;
                            n_smp = n_smp + 1;
                            cl = (blk_i == 2) || (blk_i == 20) || (blk_i == 25) || (blk_i == 33);
                            cr = (blk_i == 2) || (blk_i == 21) || (blk_i == 25) || (blk_i == 33);
                            if (d[48] !== 1'b0 || d[49] !== 1'b0 || d[52] !== 1'b0 || d[53] !== 1'b0) fail("valid or user bit", d[55:48], 0);
                            if (d[50] !== cl) fail("left channel status", d[50], cl);
                            if (d[54] !== cr) fail("right channel status", d[54], cr);
                            if (d[51] !== (^{gl, cl})) fail("left parity", d[51], ^{gl, cl});
                            if (d[55] !== (^{gr, cr})) fail("right parity", d[55], ^{gr, cr});
                            if (hb[20 + s] !== (blk_i == 0)) fail("block start", hb[20 + s], blk_i == 0);
                            if (blk_i == 0) n_blk = n_blk + 1;
                            blk_i = (blk_i == 191) ? 0 : blk_i + 1;
                        end else begin
                            if (d !== 56'd0 || hb[20 + s] !== 1'b0) fail("an absent sample not empty", s, 0);
                        end
                    end
                end
                8'h01: begin
                    n_acr = n_acr + 1;
                    if (hb !== 24'h000001) fail("ACR header", hb, 1);
                    d = sb[0][55:0];
                    if (sb[1][55:0] !== d || sb[2][55:0] !== d || sb[3][55:0] !== d) fail("ACR subpackets differ", 0, 0);
                    if ({d[35:32], d[47:40], d[55:48]} !== 20'd6144) fail("N", {d[35:32], d[47:40], d[55:48]}, 6144);
                    cts_got  = {d[11:8], d[23:16], d[31:24]};
                    cts_want = 48.0 * APER * 10.0 / 37.0;
                    if (cts_got < cts_want - 2.0 || cts_got > cts_want + 2.0) fail("CTS", cts_got, cts_want);
                    if (d[7:0] !== 8'd0 || d[15:12] !== 4'd0 || d[39:36] !== 4'd0) fail("ACR spare bits", d[39:0], 0);
                end
                8'h82: begin
                    n_avi = n_avi + 1;
                    if (hb !== 24'h0D0282) fail("AVI header", hb, 24'h0D0282);
                    sum = hb[7:0] + hb[15:8] + hb[23:16];
                    for (s = 0; s < 4; s = s + 1) for (i2 = 0; i2 < 7; i2 = i2 + 1) sum = sum + sb[s][8*i2 +: 8];
                    if (sum % 256 != 0) fail("AVI checksum", sum % 256, 0);
                    d = sb[0][55:0];
                    if (d[15:8] !== 8'h02) fail("AVI byte 1 (RGB, underscan)", d[15:8], 8'h02);
                    if (d[23:16] !== 8'h18) fail("AVI byte 2 (4:3)", d[23:16], 8'h18);
                    if (d[31:24] !== 8'h08) fail("AVI byte 3 (full range)", d[31:24], 8'h08);
                    if (d[39:32] !== 8'd17) fail("AVI byte 4 (VIC)", d[39:32], 17);
                    if (d[55:40] !== 16'd0 || sb[1][55:0] !== 0 || sb[2][55:0] !== 0 || sb[3][55:0] !== 0) fail("AVI rest", 1, 0);
                end
                8'h84: begin
                    n_aif = n_aif + 1;
                    if (hb !== 24'h0A0184) fail("audio InfoFrame header", hb, 24'h0A0184);
                    sum = hb[7:0] + hb[15:8] + hb[23:16];
                    for (s = 0; s < 4; s = s + 1) for (i2 = 0; i2 < 7; i2 = i2 + 1) sum = sum + sb[s][8*i2 +: 8];
                    if (sum % 256 != 0) fail("audio InfoFrame checksum", sum % 256, 0);
                    if (sb[0][15:8] !== 8'h01) fail("audio InfoFrame byte 1 (2 channels)", sb[0][15:8], 1);
                    if (sb[0][55:16] !== 40'd0 || sb[1][55:0] !== 0 || sb[2][55:0] !== 0 || sb[3][55:0] !== 0) fail("audio InfoFrame rest", 1, 0);
                end
                default: fail("packet type", hb[7:0], 0);
            endcase
        end
    endtask

    always @(posedge clk_pix) if (!rst) begin
        cyc = cyc + 1;
        k0 = ctl(q0);  k1 = ctl(q1);  k2 = ctl(q2);
        t0 = terc(q0); t1 = terc(q1); t2 = terc(q2);
        if (cyc > LAT + 2) begin
            case (st)
                S_CTL: begin
                    if (k0[2] && k1[2] && k2[2]) begin
                        // a control word on every lane
                        if (x_de) fail("control words in the picture", 0, 1);
                        if (k0[1:0] !== {x_vs, x_hs}) fail("syncs", k0[1:0], {x_vs, x_hs});
                        if (k1[1] || k2[1]) fail("CTL1 or CTL3 set", {k2[1], k1[1]}, 0);
                        n_ctl  = n_ctl + 1;
                        n_vpre = (k1[0] && !k2[0]) ? n_vpre + 1 : 0;
                        n_ipre = (k1[0] && k2[0]) ? n_ipre + 1 : 0;
                        if (!k1[0] && k2[0]) fail("CTL2 without CTL0", 1, 0);
                        if (dvi_expected && (k1[0] || k2[0])) fail("a preamble in DVI", 1, 0);
                    end else begin
                        // a data period begins
                        if (n_ctl < 12 && n_isl + n_vid > 1) fail("control period too short", n_ctl, 12);
                        if (n_ipre == 8) begin
                            if (x_de) fail("an island in the picture", 0, 1);
                            st = S_IGB;  gcnt = 0;  pkt_in_isl = 0;
                        end else if (n_vpre == 8) begin
                            st = S_VGB;  gcnt = 0;
                        end else if (n_vpre == 0 && n_ipre == 0 && (dvi_expected || relax)) begin
                            st = S_VID;                                   // DVI: the picture with no lead-in
                        end else begin
                            fail("data with a bad preamble", n_vpre * 100 + n_ipre, 8);
                            st = S_VID;
                        end
                        n_ctl = 0;  n_vpre = 0;  n_ipre = 0;
                    end
                end
                default: ;
            endcase
            case (st)
                S_VGB: begin
                    if (q0 !== GA || q1 !== GB || q2 !== GA) fail("video guard band", q1, GB);
                    if (x_de) fail("guard band over the picture", 0, 1);
                    hdmi_seen = 1'b1;
                    gcnt = gcnt + 1;
                    if (gcnt == 2) st = S_VID + 100;                      // (the picture from the next clock)
                end
                S_VID: begin
                    if (k0[2] && k1[2] && k2[2]) begin
                        // the picture has ended: this is the control period's first word
                        if (x_de) fail("the picture cut short", 0, 1);
                        if (k0[1:0] !== {x_vs, x_hs}) fail("syncs", k0[1:0], {x_vs, x_hs});
                        st = S_CTL;  n_ctl = 1;  n_vid = n_vid + 1;
                        if (dvi_expected) n_dvi_lines = n_dvi_lines + 1; else n_full = n_full + 1;
                    end else begin
                        if (!x_de) fail("pixels outside the picture", 1, 0);
                        if ({tmds8(q2), tmds8(q1), tmds8(q0)} !== x_rgb) fail("pixel", {tmds8(q2), tmds8(q1), tmds8(q0)}, x_rgb);
                    end
                end
                S_IGB, S_IGE: begin
                    if (q1 !== GB || q2 !== GB) fail("island guard band", q1, GB);
                    if (!t0[4] || t0[3:2] !== 2'b11) fail("island guard band, lane 0", t0, 5'h1C);
                    if (t0[1:0] !== {x_vs, x_hs}) fail("syncs in a guard band", t0[1:0], {x_vs, x_hs});
                    hdmi_seen = 1'b1;
                    gcnt = gcnt + 1;
                    if (gcnt == 2) begin
                        if (st == S_IGB) begin st = S_PKT + 100;  pix = 0; end
                        else begin st = S_CTL + 100;  n_ctl = 0;  n_isl = n_isl + 1; end
                    end
                end
                S_PKT: begin
                    if (pix == 0 && q1 === GB && q2 === GB) begin
                        // not another packet: the trailing guard band (this is its first word)
                        if (pkt_in_isl == 0) fail("an island with no packet", 0, 1);
                        if (!t0[4] || t0[3:2] !== 2'b11) fail("island guard band, lane 0", t0, 5'h1C);
                        st = S_IGE;  gcnt = 1;
                    end else begin
                        if (!t0[4] || !t1[4] || !t2[4]) fail("not TERC4 in a packet", {t2[4], t1[4], t0[4]}, 7);
                        if (t0[1:0] !== {x_vs, x_hs}) fail("syncs in a packet", t0[1:0], {x_vs, x_hs});
                        if (t0[3] !== !(pix == 0 && pkt_in_isl == 0)) fail("lane 0 bit 3", t0[3], !(pix == 0 && pkt_in_isl == 0));
                        hbits[pix] = t0[2];
                        for (s = 0; s < 4; s = s + 1) begin sb[s][2*pix] = t1[s];  sb[s][2*pix + 1] = t2[s]; end
                        pix = pix + 1;
                        if (pix == 32) begin
                            packet;
                            pix = 0;  pkt_in_isl = pkt_in_isl + 1;
                        end
                    end
                end
                default: ;
            endcase
            if (st >= 100) st = st - 100;
        end
    end

    // ---------------------------------------------------------------- the run
    integer f0;
    initial begin
        repeat (6) @(posedge clk_pix);
        rst = 1'b0;
        // HDMI: the first frame or two go out as DVI, until a frame begins
        dvi_expected = 1'b0;
        wait (frames == 3);  relax = 1'b0;                       // from here every sample must come, in order
        wait (frames == `ifdef SHORT 30 `else 400 `endif);
        // DVI for a while: no islands, no preambles, no guard bands
        relax = 1'b1;  on = 1'b0;
        f0 = frames;
        wait (frames == f0 + 2);  dvi_expected = 1'b1;  hdmi_seen = 1'b0;
        wait (frames == f0 + 12);
        if (hdmi_seen) fail("HDMI words while off", 1, 0);
        dvi_expected = 1'b0;  on = 1'b1;
        wait (frames == f0 + 15);  relax = 1'b0;
        // no samples for a while: the first packet is a null packet
        wait (frames == f0 + 20);  aud_run = 1'b0;
        wait (frames == f0 + 26);  aud_run = 1'b1;
        wait (frames == f0 + `ifdef SHORT 40 `else 200 `endif);
        @(posedge clk_pix);
        $display("%0d frames: %0d picture lines with their lead-in, %0d as DVI; %0d islands; %0d audio packets with %0d samples (%0d sent, %0d lost to DVI), %0d blocks begun; %0d ACR, %0d AVI, %0d audio InfoFrames, %0d null packets (%0d in place of samples)",
                 frames, n_full, n_dvi_lines, n_isl, n_aud, n_smp, n_sent, n_skip, n_blk, n_acr, n_avi, n_aif, n_null, n_null1);
        if (n_sent - rx > 12) fail("samples left unsent at the end", n_sent - rx, 0);
        if (n_isl < 1000 || n_smp < 2000 || n_blk < 5 || n_acr < 20 || n_avi < 100 || n_aif < 100 || n_null == 0 || n_null1 < 20 || n_dvi_lines < 30 || n_skip == 0) begin
            errors = errors + 1;
            $display("ERROR: a case never came up");
        end
        if (n_avi > frames || n_aif > frames) fail("InfoFrames more than once a frame", n_avi, frames);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
