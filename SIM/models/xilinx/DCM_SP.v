`timescale 1ns / 1ps

/*
 * Modelo funcional minimo de DCM_SP para simulacion con Icarus.
 *
 * Implementa solamente el comportamiento utilizado por clock_manager:
 *
 *   CLK0
 *   CLKDV
 *   LOCKED
 *   STATUS
 *
 * No modela jitter, phase shift, deskew ni retardos reales del DCM.
 */

module DCM_SP #(
    parameter real CLKDV_DIVIDE = 2.0,
    parameter real CLKIN_PERIOD = 10.0,

    parameter CLK_FEEDBACK = "1X",
    parameter DESKEW_ADJUST = "SYSTEM_SYNCHRONOUS",
    parameter DUTY_CYCLE_CORRECTION = "TRUE",
    parameter STARTUP_WAIT = "FALSE"
) (

    input wire CLKIN,
    input wire CLKFB,
    input wire RST,

    output wire CLK0,
    output wire CLKDV,
    output wire LOCKED,

    input wire PSCLK,
    input wire PSEN,
    input wire PSINCDEC,
    input wire DSSEN,

    output wire CLK90,
    output wire CLK180,
    output wire CLK270,
    output wire CLK2X,
    output wire CLK2X180,
    output wire CLKFX,
    output wire CLKFX180,

    output wire PSDONE,
    output wire [7:0] STATUS

);

    integer edge_count = 0;
    integer divide_value = CLKDV_DIVIDE;

    reg clkdv_reg = 1'b0;

    /*
     * CLKIN es de 100 MHz.
     *
     * Contamos ambos flancos del reloj de entrada. De esta forma,
     * para DIVIDE=N, CLKDV cambia de estado cada N medios ciclos,
     * generando:
     *
     *     f_CLKDV = f_CLKIN / N
     */
    always @(CLKIN or posedge RST) begin
        if (RST) begin
            edge_count <= 0;
            clkdv_reg  <= 1'b0;
        end else begin
            if (edge_count == divide_value - 1) begin
                edge_count <= 0;
                clkdv_reg  <= ~clkdv_reg;
            end else begin
                edge_count <= edge_count + 1;
            end
        end
    end

    assign CLK0   = CLKIN;
    assign CLKDV  = clkdv_reg;

    /*
     * Modelo funcional simplificado del lock.
     *
     * El DCM real tarda un tiempo en adquirir lock.
     * Para pruebas funcionales del SoC lo consideramos estable
     * inmediatamente después de retirar reset.
     */
    assign LOCKED = ~RST;

    assign STATUS = 8'b00000000;

    /*
     * Salidas del DCM no utilizadas actualmente por clock_manager.
     */
    assign CLK90    = 1'b0;
    assign CLK180   = 1'b0;
    assign CLK270   = 1'b0;
    assign CLK2X    = 1'b0;
    assign CLK2X180 = 1'b0;
    assign CLKFX    = 1'b0;
    assign CLKFX180 = 1'b0;
    assign PSDONE   = 1'b0;

endmodule
