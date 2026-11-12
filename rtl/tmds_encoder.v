// DVI TMDS encoder (DVI 1.0, section 3.2.2): 8 data bits to 10 bits with
// transition minimising and DC balance; the control codes during blanking.
//
//   HDMI  1: also HDMI's guard bands and TERC4 words, chosen by m (for data
//            islands: rtl/hdmi_packets.v drives it). 0: m, g and a are not used
module tmds_encoder #(
    parameter HDMI = 0
) (
    input  wire       clk,         // pixel clock
    input  wire [7:0] d,
    input  wire [1:0] c,           // control bits (blue: {vsync, hsync})
    input  wire       de,          // 1 = data, 0 = control period
    input  wire [1:0] m,           // (HDMI) 0: as de says. 1: a guard band word. 2: TERC4 of a
    input  wire       g,           // (HDMI) the guard band word: 0 1011001100, 1 0100110011
    input  wire [3:0] a,           // (HDMI) four bits for TERC4
    output reg  [9:0] q
);
    function [9:0] terc4(input [3:0] v);
        case (v)
            4'h0: terc4 = 10'b1010011100;  4'h1: terc4 = 10'b1001100011;
            4'h2: terc4 = 10'b1011100100;  4'h3: terc4 = 10'b1011100010;
            4'h4: terc4 = 10'b0101110001;  4'h5: terc4 = 10'b0100011110;
            4'h6: terc4 = 10'b0110001110;  4'h7: terc4 = 10'b0100111100;
            4'h8: terc4 = 10'b1011001100;  4'h9: terc4 = 10'b0100111001;
            4'hA: terc4 = 10'b0110011100;  4'hB: terc4 = 10'b1011000110;
            4'hC: terc4 = 10'b1010001110;  4'hD: terc4 = 10'b1001110001;
            4'hE: terc4 = 10'b0101100011;  default: terc4 = 10'b1011000011;
        endcase
    endfunction
    wire [1:0] mm = (HDMI != 0) ? m : 2'd0;

    function [3:0] ones8(input [7:0] v);
        ones8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
    endfunction

    // Stage 1: transition minimising
    wire [3:0] n1d   = ones8(d);
    wire       use_x = (n1d > 4) || (n1d == 4 && d[0] == 1'b0);
    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar i;
    generate for (i = 1; i < 8; i = i + 1) begin : xm
        assign qm[i] = use_x ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
    end endgenerate
    assign qm[8] = ~use_x;

    // Stage 2: DC balance
    wire [3:0] n1 = ones8(qm[7:0]);
    wire [3:0] n0 = 4'd8 - n1;
    reg  signed [4:0] cnt = 5'sd0;          // running disparity

    always @(posedge clk) begin
        if (mm == 2'd1) begin
            cnt <= 5'sd0;
            q   <= g ? 10'b0100110011 : 10'b1011001100;
        end else if (mm == 2'd2) begin
            cnt <= 5'sd0;
            q   <= terc4(a);
        end else if (!de) begin
            cnt <= 5'sd0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || n1 == n0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + $signed({1'b0, n1}) - $signed({1'b0, n0})
                         : cnt + $signed({1'b0, n0}) - $signed({1'b0, n1});
        end else if ((cnt > 0 && n1 > n0) || (cnt < 0 && n0 > n1)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + $signed({3'd0, qm[8], 1'b0}) + $signed({1'b0, n0}) - $signed({1'b0, n1});
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - $signed({3'd0, ~qm[8], 1'b0}) + $signed({1'b0, n1}) - $signed({1'b0, n0});
        end
    end
endmodule
