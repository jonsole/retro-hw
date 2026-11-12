// DVI over HDMI on the Next (docs/spec/platform.md): three TMDS data pairs and
// the clock pair. Each 10-bit word goes out least significant bit first
// through a 10:1 OSERDESE2 pair (DDR at 5 x the pixel clock).
// Pair order: 0 blue, 1 green, 2 red, 3 clock, as in the Next's own
// hdmi_out_xilinx_a7.vhd (which also sends least significant bit first).
//
//   AUDIO  1: HDMI with stereo sound: rtl/hdmi_packets.v puts data islands in
//             the blank (the picture goes out 12 pixel clocks later). hdmi_on
//             low sends DVI all the same. 0: DVI only, as it always was; clk,
//             the aud_ inputs and hdmi_on are not used
//   VIC    (AUDIO) the picture's video code for the AVI InfoFrame
module hdmi_out #(
    parameter AUDIO = 0,
    parameter VIC   = 17
) (
    input  wire       clk_pix,
    input  wire       clk_pix5,
    input  wire       rst,           // synchronous to clk_pix
    input  wire [23:0] rgb,
    input  wire       hsync, vsync,  // active level as sent
    input  wire       de,
    input  wire       hdmi_on,       // (AUDIO) 1: HDMI with sound. 0: DVI. A level
    input  wire       clk,           // (AUDIO) the system clock, for the samples
    input  wire [15:0] aud_l, aud_r, // (AUDIO) signed samples
    input  wire       aud_v,         // (AUDIO) strobe: a new sample
    output wire [3:0] tmds_p,
    output wire [3:0] tmds_n
);
    wire [9:0] w [0:3];
    generate if (AUDIO != 0) begin : hdmi
        wire [23:0] p_rgb;
        wire        p_de, p_g2;
        wire [1:0]  p_c0, p_c1, p_c2, p_m0, p_m1, p_m2;
        wire [3:0]  p_a0, p_a1, p_a2;
        hdmi_packets #(.VIC(VIC)) pk (
            .clk_pix(clk_pix), .rst(rst), .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de), .on(hdmi_on),
            .clk(clk), .aud_l(aud_l), .aud_r(aud_r), .aud_v(aud_v),
            .o_rgb(p_rgb), .o_de(p_de), .o_c0(p_c0), .o_c1(p_c1), .o_c2(p_c2),
            .o_m0(p_m0), .o_m1(p_m1), .o_m2(p_m2), .o_g2(p_g2), .o_a0(p_a0), .o_a1(p_a1), .o_a2(p_a2));
        tmds_encoder #(.HDMI(1)) eb (.clk(clk_pix), .d(p_rgb[7:0]),   .c(p_c0), .de(p_de), .m(p_m0), .g(1'b0), .a(p_a0), .q(w[0]));
        tmds_encoder #(.HDMI(1)) eg (.clk(clk_pix), .d(p_rgb[15:8]),  .c(p_c1), .de(p_de), .m(p_m1), .g(1'b1), .a(p_a1), .q(w[1]));
        tmds_encoder #(.HDMI(1)) er (.clk(clk_pix), .d(p_rgb[23:16]), .c(p_c2), .de(p_de), .m(p_m2), .g(p_g2), .a(p_a2), .q(w[2]));
    end else begin : dvi
        tmds_encoder eb (.clk(clk_pix), .d(rgb[7:0]),   .c({vsync, hsync}), .de(de), .m(2'd0), .g(1'b0), .a(4'd0), .q(w[0]));
        tmds_encoder eg (.clk(clk_pix), .d(rgb[15:8]),  .c(2'b00),          .de(de), .m(2'd0), .g(1'b0), .a(4'd0), .q(w[1]));
        tmds_encoder er (.clk(clk_pix), .d(rgb[23:16]), .c(2'b00),          .de(de), .m(2'd0), .g(1'b0), .a(4'd0), .q(w[2]));
    end endgenerate
    assign w[3] = 10'b0000011111;

    genvar ch;
    generate for (ch = 0; ch < 4; ch = ch + 1) begin : lane
        wire s1, s2, ser;
        OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
                    .SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1), .INIT_OQ(1'b0)) m (
            .OQ(ser), .OFB(), .TQ(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2(),
            .CLK(clk_pix5), .CLKDIV(clk_pix),
            .D1(w[ch][0]), .D2(w[ch][1]), .D3(w[ch][2]), .D4(w[ch][3]),
            .D5(w[ch][4]), .D6(w[ch][5]), .D7(w[ch][6]), .D8(w[ch][7]),
            .SHIFTIN1(s1), .SHIFTIN2(s2), .OCE(1'b1), .RST(rst),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b0), .TBYTEIN(1'b0)
        );
        OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
                    .SERDES_MODE("SLAVE"), .TRISTATE_WIDTH(1), .INIT_OQ(1'b0)) s (
            .OQ(), .OFB(), .TQ(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(s1), .SHIFTOUT2(s2),
            .CLK(clk_pix5), .CLKDIV(clk_pix),
            .D1(1'b0), .D2(1'b0), .D3(w[ch][8]), .D4(w[ch][9]),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .OCE(1'b1), .RST(rst),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b0), .TBYTEIN(1'b0)
        );
        OBUFDS #(.IOSTANDARD("TMDS_33")) ob (.I(ser), .O(tmds_p[ch]), .OB(tmds_n[ch]));
    end endgenerate
endmodule
