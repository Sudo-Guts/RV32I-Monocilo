`timescale 1ns / 1ps

/*
 * ========================================================================
 *  UART - Serial byte interface
 * ------------------------------------------------------------------------
 *  Integra solamente la capa fisica/logica del enlace serie:
 *
 *      uart_baudrate -> uart_rx / uart_tx
 *
 *  La linea utiliza 8N1: un start bit en bajo, ocho bits LSB first y un
 *  stop bit en alto. No hay paridad ni control de flujo RTS/CTS.
 *
 *  Este modulo NO contiene FIFO. rx_valid_o es un pulso de un ciclo cuando
 *  uart_rx termina una trama valida y rx_data_o conserva el byte recibido.
 *  El buffering pertenece al modulo consumidor; en este proyecto la RX FIFO
 *  vive dentro de uart0_wbm.v.
 *
 *  TX tampoco contiene FIFO. El consumidor presenta tx_data_i y genera un
 *  pulso tx_start_i solamente cuando tx_busy_o = 0.
 *
 *  Todos los puertos de este modulo no-Wishbone usan nombres minusculos con
 *  sufijo _i / _o. Las conexiones internas no usan esos sufijos.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module uart #(

    // ---------------------------------------------------------
    //  Frecuencia interna del modulo.
    // ---------------------------------------------------------
    parameter integer CLK_FREQ = 50_000_000,

    // ---------------------------------------------------------
    //  Velocidad serie compartida con debugger.py.
    // ---------------------------------------------------------
    parameter integer BAUD_RATE = 57600,

    // ---------------------------------------------------------
    //  Numero de muestras RX por periodo de bit.
    // ---------------------------------------------------------
    parameter integer OVERSAMPLE = 16

) (

    // ---------------------------------------------------------
    //  Reloj y reset.
    // ---------------------------------------------------------
    input wire clk_i,
    input wire rst_i,

    // ---------------------------------------------------------
    //  Pines serie.
    // ---------------------------------------------------------
    input  wire rx_i,
    output wire tx_o,

    // ---------------------------------------------------------
    //  Byte recibido por la UART.
    // ---------------------------------------------------------
    output wire [7:0] rx_data_o,
    output wire       rx_valid_o,

    // ---------------------------------------------------------
    //  Byte enviado por la UART.
    // ---------------------------------------------------------
    input  wire [7:0] tx_data_i,
    input  wire       tx_start_i,
    output wire       tx_busy_o

);

    // ---------------------------------------------------------
    //  Ticks compartidos por RX y TX.
    // ---------------------------------------------------------
    wire baud_tick;
    wire sample_tick;

    // ========================================================================
    //  Baud-rate generator
    // ------------------------------------------------------------------------
    //  baud_tick avanza una posicion del transmisor.
    //  sample_tick habilita el oversampling del receptor.
    // ========================================================================

    uart_baudrate #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE),
        .OVERSAMPLE(OVERSAMPLE)
    ) baudrate_inst (
        .clk_i        (clk_i),
        .rst_i        (rst_i),
        .baud_tick_o  (baud_tick),
        .sample_tick_o(sample_tick)
    );

    // ========================================================================
    //  UART receiver
    // ------------------------------------------------------------------------
    //  Convierte la trama 8N1 recibida por rx_i en un byte y un pulso valid.
    //  No existe backpressure en este nivel; uart0_wbm debe capturar el pulso.
    // ========================================================================

    uart_rx #(
        .OVERSAMPLE(OVERSAMPLE)
    ) rx_inst (
        .clk_i        (clk_i),
        .rst_i        (rst_i),
        .sample_tick_i(sample_tick),
        .rx_i         (rx_i),
        .rx_data_o    (rx_data_o),
        .rx_valid_o   (rx_valid_o)
    );

    // ========================================================================
    //  UART transmitter
    // ------------------------------------------------------------------------
    //  Copia tx_data_i al aceptar tx_start_i y mantiene tx_busy_o durante
    //  la transmision completa del byte.
    // ========================================================================

    uart_tx tx_inst (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .baud_tick_i(baud_tick),
        .tx_data_i  (tx_data_i),
        .tx_start_i (tx_start_i),
        .tx_o       (tx_o),
        .tx_busy_o  (tx_busy_o)
    );

endmodule
