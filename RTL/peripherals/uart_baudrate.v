`timescale 1ns / 1ps

/*
 * ========================================================================
 *  UART Baudrate Generator - Ticks fraccionales
 * ------------------------------------------------------------------------
 *  Genera habilitaciones sin crear nuevos dominios de reloj:
 *      baud_tick_o:   frecuencia media BAUD_RATE, para el transmisor.
 *      sample_tick_o: frecuencia media BAUD_RATE * OVERSAMPLE, para el receptor.
 *  Todos los registros de UART siguen utilizando el mismo clk_i del sistema.
 *
 *  En cada flanco se suma la frecuencia deseada a un acumulador. Cuando
 *  alcanza CLK_FREQ se resta CLK_FREQ y se activa el tick correspondiente.
 *  Conservar el residuo evita el error acumulado de un divisor entero.
 *  Los intervalos pueden alternar entre dos cantidades de ciclos adyacentes.
 *
 *  Ejemplo: 50 MHz / 57600 no es entero; baud_tick_o alterna intervalos de
 *  868 y 869 ciclos, manteniendo el promedio requerido por el enlace.
 *  El modulo exige CLK_FREQ y BAUD_RATE positivos, OVERSAMPLE >= 4 y una
 *  frecuencia de muestras no superior a clk_i. Una configuracion invalida
 *  mantiene fases y ticks en cero. El receptor se utiliza con OVERSAMPLE par.
 *  rst_i es sincrono y activo en alto; reinicia ambas fases.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module uart_baudrate #(
    // Frecuencia interna en Hz; debe coincidir con clk_i.
    parameter integer CLK_FREQ   = 50_000_000,
    // Velocidad serie compartida con debugger.py.
    parameter integer BAUD_RATE  = 57600,
    // Muestras RX por bit; configuracion del proyecto: 16.
    parameter integer OVERSAMPLE = 16
) (

    // ---------------------------------------------------------
    //  Reloj y reset
    // ---------------------------------------------------------
    input wire clk_i,  // Reloj del modulo; flanco ascendente.
    input wire rst_i,  // Reset activo en alto.

    // ---------------------------------------------------------
    //  Habilitaciones de tiempo para TX y RX
    // ---------------------------------------------------------
    output reg baud_tick_o,   // Habilitacion de avance de un bit TX.
    output reg sample_tick_o  // Habilitacion de una muestra RX.
);

    // ========================================================================
    //  Ancho de los acumuladores
    // ------------------------------------------------------------------------
    // ========================================================================

    function integer clog2;
        input integer value;
        integer temp;
        begin
            temp = value - 1;
            for (clog2 = 0; temp > 0; clog2 = clog2 + 1) temp = temp >> 1;
        end
    endfunction

    // ========================================================================
    //  Constantes de frecuencia y validacion
    // ------------------------------------------------------------------------
    // ========================================================================

    localparam integer WIDTH = (CLK_FREQ <= 2) ? 1 : clog2(CLK_FREQ);
    localparam integer SAMPLE_RATE = BAUD_RATE * OVERSAMPLE;
    localparam
        CONFIG_VALID = CLK_FREQ > 0 && BAUD_RATE > 0 && OVERSAMPLE >= 4 && SAMPLE_RATE <= CLK_FREQ;
    localparam [WIDTH:0] LIMIT = CLK_FREQ[WIDTH:0];
    localparam [WIDTH:0] BAUD_STEP = BAUD_RATE[WIDTH:0];
    localparam [WIDTH:0] SAMPLE_STEP = SAMPLE_RATE[WIDTH:0];

    // ========================================================================
    //  Suma de fase y conservacion del residuo
    // ------------------------------------------------------------------------
    // ========================================================================

    reg [WIDTH-1:0] baud_phase, sample_phase;
    wire [WIDTH:0] baud_sum = {1'b0, baud_phase} + BAUD_STEP;
    wire [WIDTH:0] sample_sum = {1'b0, sample_phase} + SAMPLE_STEP;
    wire [WIDTH:0] baud_next = (baud_sum >= LIMIT) ? baud_sum - LIMIT : baud_sum;
    wire [WIDTH:0] sample_next = (sample_sum >= LIMIT) ? sample_sum - LIMIT : sample_sum;

    // ========================================================================
    //  Registro de fase y habilitaciones
    // ------------------------------------------------------------------------
    // ========================================================================

    always @(posedge clk_i) begin
        if (rst_i || !CONFIG_VALID) begin
            baud_phase   <= 0;
            sample_phase <= 0;
            baud_tick_o    <= 0;
            sample_tick_o  <= 0;
        end else begin
            baud_phase   <= baud_next[WIDTH-1:0];
            sample_phase <= sample_next[WIDTH-1:0];
            baud_tick_o    <= (baud_sum >= LIMIT);
            sample_tick_o  <= (sample_sum >= LIMIT);
        end
    end
endmodule
