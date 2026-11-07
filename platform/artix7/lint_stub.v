// Stand-ins for the Xilinx primitives in platform/artix7, for linting the
// board builds (fpga/lint.sh): the same ports and parameters as used, no
// logic. Never simulated or synthesised.
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

module OBUFDS #(parameter IOSTANDARD = "DEFAULT") (input wire I, output wire O, output wire OB);
    assign O  = I;
    assign OB = !I;
endmodule

module MMCME2_BASE #(
    parameter real    CLKIN1_PERIOD    = 0.0,
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter real    CLKFBOUT_MULT_F  = 5.0,
    parameter real    CLKOUT0_DIVIDE_F = 1.0,
    parameter integer CLKOUT1_DIVIDE   = 1,
    parameter integer CLKOUT2_DIVIDE   = 1,
    parameter real    CLKOUT2_PHASE    = 0.0
) (
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
    output wire CLKFBOUT, CLKFBOUTB,
    output wire CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
    output wire CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
    output wire LOCKED
);
    assign {CLKFBOUT, CLKFBOUTB, CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
            CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6} = {13{CLKIN1}};
    assign LOCKED = 1'b1;
endmodule

module OSERDESE2 #(
    parameter DATA_RATE_OQ   = "DDR",
    parameter DATA_RATE_TQ   = "DDR",
    parameter integer DATA_WIDTH     = 4,
    parameter SERDES_MODE    = "MASTER",
    parameter integer TRISTATE_WIDTH = 4,
    parameter [0:0] INIT_OQ  = 1'b0
) (
    input  wire CLK, CLKDIV, D1, D2, D3, D4, D5, D6, D7, D8,
    input  wire SHIFTIN1, SHIFTIN2, OCE, RST, T1, T2, T3, T4, TCE, TBYTEIN,
    output wire OQ, OFB, TQ, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2
);
    assign {OQ, OFB, TQ, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2} = 7'd0;
endmodule

module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter [0:0] INIT   = 1'b0,
    parameter SRTYPE       = "SYNC"
) (
    input  wire C, CE, D1, D2, R, S,
    output wire Q
);
    assign Q = D1;
endmodule

module IOBUF (inout wire IO, input wire I, input wire T, output wire O);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule
