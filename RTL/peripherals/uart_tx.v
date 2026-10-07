`timescale 1ns / 1ps

/*
 * ========================================================================
 *  UART Transmitter - Transmision 8N1
 * ------------------------------------------------------------------------
 *  Convierte un byte en una trama serie: inicio = 0, ocho bits LSB primero
 *  y parada = 1. La linea permanece en 1 cuando no existe transmision.
 *
 *  IDLE acepta tx_start_i y copia tx_data_i. WAIT_START espera el siguiente
 *  baud_tick_i para iniciar un bit de inicio completo. START_BIT, DATA_BITS
 *  y STOP_BIT avanzan exclusivamente con baud_tick_i.
 *  tx_busy_o se mantiene alto desde la aceptacion hasta completar la parada.
 *
 *  El productor debe pulsar tx_start_i solo cuando tx_busy_o = 0. Una solicitud
 *  mientras el transmisor esta ocupado no queda en cola. tx_data_i puede
 *  cambiar despues de la aceptacion porque el byte se conserva en tx_buffer.
 *  rst_i es sincrono y activo en alto: cancela la trama y fuerza reposo alto.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module uart_tx (

    // --------------------------------------------------------
    //          Reloj y reset
    // --------------------------------------------------------
    input wire clk_i,  // Reloj del modulo; flanco ascendente.
    input wire rst_i,  // Reset activo en alto.

    // -----------------------------------------------------
    //          Habilitacion temporal
    // -----------------------------------------------------
    input wire baud_tick_i,  // Habilitacion de avance de un bit TX.

    // -----------------------------------------------------
    //          Interfaz de transmision
    // -----------------------------------------------------
    input  wire [7:0] tx_data_i,   // Byte que se desea transmitir.
    input  wire       tx_start_i,  // Pulso de solicitud con tx_busy_o = 0.
    output reg        tx_o,        // Salida serie 8N1, reposo alto.
    output reg        tx_busy_o    // Transmisor ocupado; no acepta otro byte.

);

    // ----------------------------------------------------------
    //          Estados del receptor / transmisor
    // ----------------------------------------------------------

    localparam [2:0] IDLE = 3'd0,  // Espera una solicitud de transmision mediante tx_start_i.
    WAIT_START = 3'd1,  // Espera el siguiente baud_tick_i para iniciar la trama.
    START_BIT = 3'd2,  // Transmite el Start Bit en nivel bajo.
    DATA_BITS = 3'd3,  // Transmite los 8 bits de datos, de LSB a MSB.
    STOP_BIT = 3'd4;  // Transmite el Stop Bit en nivel alto y finaliza la trama.

    reg [2:0] state;

    // ----------------------------------------------------------
    //          Registros internos
    // ----------------------------------------------------------

    // Copia local del byte para que tx_data_i pueda cambiar mientras
    // una transmision esta en curso.
    reg [7:0] tx_buffer;

    // Selecciona D0 ... D7.
    reg [2:0] bit_index;

    // ============================================================
    //          Maquina de estados de transmision
    // ============================================================

    always @(posedge clk_i) begin
        if (rst_i) begin
            state     <= IDLE;
            tx_o        <= 1'b1;
            tx_busy_o   <= 1'b0;
            tx_buffer <= 8'd0;
            bit_index <= 3'd0;
        end else begin
            case (state)
                // ----------------------------------------------
                //  Linea serial en reposo
                // ----------------------------------------------
                IDLE: begin
                    tx_o      <= 1'b1;
                    tx_busy_o <= 1'b0;
                    if (tx_start_i) begin
                        tx_buffer <= tx_data_i;
                        tx_busy_o   <= 1'b1;
                        // Esperar el siguiente baud_tick_i permite
                        // iniciar la trama alineada temporalmente.
                        state     <= WAIT_START;
                    end
                end

                // ----------------------------------------------
                //  Esperar Frontera de Bit
                // ----------------------------------------------
                WAIT_START: begin
                    tx_o      <= 1'b1;
                    tx_busy_o <= 1'b1;
                    if (baud_tick_i) begin
                        tx_o    <= 1'b0;
                        state <= START_BIT;
                    end
                end

                // ----------------------------------------------
                //  Start Bit
                // ----------------------------------------------
                START_BIT: begin
                    tx_o      <= 1'b0;
                    tx_busy_o <= 1'b1;
                    if (baud_tick_i) begin
                        tx_o        <= tx_buffer[0];
                        bit_index <= 3'd0;
                        state     <= DATA_BITS;
                    end
                end

                // ----------------------------------------------
                //  Data Bits - LSB first
                // ----------------------------------------------
                DATA_BITS: begin
                    tx_busy_o <= 1'b1;
                    if (baud_tick_i) begin
                        if (bit_index == 3'd7) begin
                            tx_o    <= 1'b1;
                            state <= STOP_BIT;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            tx_o        <= tx_buffer[bit_index+1'b1];
                        end
                    end
                end

                // ----------------------------------------------
                //  Stop Bit
                // ----------------------------------------------
                STOP_BIT: begin
                    tx_o      <= 1'b1;
                    tx_busy_o <= 1'b1;
                    if (baud_tick_i) begin
                        tx_busy_o <= 1'b0;
                        state   <= IDLE;
                    end
                end

                // ----------------------------------------------
                //  Recuperacion Defensiva
                // ----------------------------------------------
                default: begin
                    state   <= IDLE;
                    tx_o      <= 1'b1;
                    tx_busy_o <= 1'b0;
                end
            endcase
        end
    end
endmodule
