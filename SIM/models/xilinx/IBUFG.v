`timescale 1ns / 1ps

/*
 * Modelo funcional de simulacion.
 * No representa retardos ni comportamiento fisico del Spartan-6.
 */

module IBUFG (
    input  wire I,
    output wire O
);

  assign O = I;

endmodule
