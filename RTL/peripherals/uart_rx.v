`timescale 1ns / 1ps

/*
 * ========================================================================
 *  UART Receiver - Recepcion 8N1
 * ------------------------------------------------------------------------
 *  Convierte la entrada serie rx_i en bytes. Dos flip-flops sincronizan la
 *  entrada asincrona antes de utilizarla en la maquina de estados.
 *
 *  IDLE detecta nivel bajo. START_BIT espera aproximadamente medio bit y
 *  confirma que sigue bajo. DATA_BITS espera un periodo completo entre
 *  muestras, capturando cada dato cerca de su centro, de D0 a D7.
 *  STOP_BIT verifica nivel alto y genera rx_valid_o durante un ciclo de clk_i.
 *  Si la parada es baja, la trama se descarta sin producir rx_valid_o.
 *
 *  sample_count cuenta pulsos de sample_tick_i, no directamente ciclos de clk_i.
 *  Con OVERSAMPLE = 16, START_SAMPLE = 7 y LAST_SAMPLE = 15. Tras centrar
 *  el inicio, terminar una cuenta de 16 muestras coincide con el centro del
 *  bit siguiente; no significa muestrear el borde final del bit fisico.
 *  Se toma una muestra por bit de datos; no hay votacion mayoritaria.
 *
 *  rx_data_o permanece con el ultimo byte valido hasta una recepcion posterior.
 *  La RX FIFO de uart0_wbm debe capturar el pulso; este bloque no acepta
 *  backpressure. rst_i es sincrono, activo en alto, y reinicia el receptor.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module uart_rx #(
    // Muestras RX por bit; configuracion del proyecto: 16.
    parameter integer OVERSAMPLE = 16

) (

    // --------------------------------------------------------
    //          Reloj y reset
    // --------------------------------------------------------
    input wire clk_i,  // Reloj del modulo; flanco ascendente.
    input wire rst_i,  // Reset activo en alto.

    // --------------------------------------------------------
    //          Habilitacion temporal
    // --------------------------------------------------------
    input wire sample_tick_i,  // Habilitacion de una muestra RX.

    // --------------------------------------------------------
    //              Interfaz de recepcion
    // --------------------------------------------------------
    input  wire       rx_i,       // Entrada serie asincrona, reposo alto.
    output reg  [7:0] rx_data_o,  // Ultimo byte 8N1 recibido correctamente.
    output reg        rx_valid_o  // Pulso de un ciclo por trama 8N1 valida.

);

    // ============================================================
    //              clog2
    // ============================================================

    function integer clog2;
        input integer value;
        integer temp;
        begin
            temp = value - 1;
            for (clog2 = 0; temp > 0; clog2 = clog2 + 1) temp = temp >> 1;
        end
    endfunction

    // --------------------------------------------------------
    //              Constantes de sobremuestreo
    // --------------------------------------------------------

    localparam integer SAMPLE_COUNT_WIDTH = (OVERSAMPLE <= 1) ? 1 : clog2(OVERSAMPLE);
    localparam integer START_SAMPLE = (OVERSAMPLE / 2) - 1;
    localparam integer LAST_SAMPLE = OVERSAMPLE - 1;

    // --------------------------------------------------------
    //              Estados del receptor / transmisor
    // --------------------------------------------------------

    localparam [2:0] IDLE = 3'd0,  // Espera a que la senal RX detecte el inicio de una transmision.
    START_BIT = 3'd2,  // Verifica el Start Bit cerca de su punto medio.
    DATA_BITS = 3'd3,  // Recibe y almacena los 8 bits de datos, de LSB a MSB.
    STOP_BIT = 3'd4;  // Verifica el Stop Bit y genera rx_valid_o si la trama es correcta.

    reg [2:0]                    state;

    // --------------------------------------------------------
    //              Registros internos
    // --------------------------------------------------------

    reg [SAMPLE_COUNT_WIDTH-1:0] sample_count;
    reg [2:0]                    bit_index;
    reg [7:0]                    rx_buffer;

    // ============================================================
    //              Sincronizacion de la entrada RX
    // ============================================================
    //
    //  rx_i es asincrona respecto a clk_i.
    //
    //  El doble registro reduce el riesgo de metastabilidad antes
    //  de entregar la senal a la FSM.
    //
    // ============================================================

    reg                          rx_meta;
    reg                          rx_sync;

    always @(posedge clk_i) begin
        if (rst_i) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx_i;
            rx_sync <= rx_meta;
        end
    end

    // ============================================================
    //              Maquina de estados de recepcion
    // ============================================================

    always @(posedge clk_i) begin
        if (rst_i) begin
            state        <= IDLE;
            sample_count <= {SAMPLE_COUNT_WIDTH{1'b0}};
            bit_index    <= 3'd0;
            rx_buffer    <= 8'd0;
            rx_data_o      <= 8'd0;
            rx_valid_o     <= 1'b0;
        end else begin
            // rx_valid_o es un pulso de un ciclo.
            rx_valid_o <= 1'b0;
            if (sample_tick_i) begin
                case (state)
                    // ----------------------------------------------
                    //  Esperar Start Bit
                    // ----------------------------------------------
                    IDLE: begin
                        sample_count <= {SAMPLE_COUNT_WIDTH{1'b0}};
                        bit_index    <= 3'd0;
                        if (rx_sync == 1'b0) state <= START_BIT;
                    end

                    // ----------------------------------------------
                    //  Validar Start Bit cerca de su centro
                    // -----------------------------------------
                    START_BIT: begin
                        if (sample_count == START_SAMPLE[SAMPLE_COUNT_WIDTH-1:0]) begin
                            sample_count <= {SAMPLE_COUNT_WIDTH{1'b0}};
                            if (rx_sync == 1'b0) begin
                                bit_index <= 3'd0;
                                state     <= DATA_BITS;
                            end else begin
                                // Falso Start Bit.
                                state <= IDLE;
                            end
                        end else begin
                            sample_count <= sample_count + 1'b1;
                        end
                    end

                    // ----------------------------------------------
                    //  Recibir D0 ... D7, LSB first
                    // ----------------------------------------------
                    DATA_BITS: begin
                        if (sample_count == LAST_SAMPLE[SAMPLE_COUNT_WIDTH-1:0]) begin
                            sample_count         <= {SAMPLE_COUNT_WIDTH{1'b0}};
                            rx_buffer[bit_index] <= rx_sync;
                            if (bit_index == 3'd7) begin
                                bit_index <= 3'd0;
                                state     <= STOP_BIT;
                            end else begin
                                bit_index <= bit_index + 1'b1;
                            end
                        end else begin
                            sample_count <= sample_count + 1'b1;
                        end
                    end

                    // ----------------------------------------------
                    //  Validar Stop Bit
                    // ----------------------------------------------
                    STOP_BIT: begin
                        if (sample_count == LAST_SAMPLE[SAMPLE_COUNT_WIDTH-1:0]) begin
                            sample_count <= {SAMPLE_COUNT_WIDTH{1'b0}};
                            if (rx_sync == 1'b1) begin
                                rx_data_o  <= rx_buffer;
                                rx_valid_o <= 1'b1;
                            end
                            state <= IDLE;
                        end else begin
                            sample_count <= sample_count + 1'b1;
                        end
                    end

                    // ----------------------------------------------
                    //  Recuperacion defensiva
                    // ----------------------------------------------
                    default: begin
                        state <= IDLE;
                    end
                endcase
            end
        end
    end
endmodule
