`timescale 1ns / 1ps

/*
 * Modelo funcional de simulacion.
 * No representa retardos de la red global de reloj.
 */

module BUFG (
    input  wire I,
    output wire O
);

    assign O = I;

endmodule
