// Minimal models of Gowin primitives for simulation
`timescale 1ns/1ps
module OSER10 #(parameter GSREN = "false", parameter LSREN = "true") (
    output reg Q, input D0, D1, D2, D3, D4, D5, D6, D7, D8, D9,
    input PCLK, input FCLK, input RESET);
    initial Q = 1'b0;
endmodule
module ELVDS_OBUF (input I, output O, output OB);
    assign O = I; assign OB = ~I;
endmodule
