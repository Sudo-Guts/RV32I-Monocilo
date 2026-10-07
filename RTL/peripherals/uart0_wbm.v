`timescale 1ns / 1ps

/*
 * ========================================================================
 *  UART0 Wishbone Master - UART bridge + RX FIFO
 * ------------------------------------------------------------------------
 *  Este modulo es el Wishbone Master M0 del SoC. Integra tres funciones:
 *
 *      1. uart.v convierte bits serie 8N1 en bytes y viceversa.
 *      2. La RX FIFO conserva bytes mientras el bridge procesa WB o transmite.
 *      3. La FSM reconstruye la trama del host y genera un Classic SINGLE WB.
 *
 *  La FIFO vive aqui deliberadamente; uart.v queda como una UART pura sin
 *  buffering. Si la FIFO se llena y llega un byte sin poder liberar espacio,
 *  rx_overflow genera un pulso y la FSM entra en DRAIN para resincronizarse.
 *
 *  Solicitud UART, 15 bytes:
 *     0..1 : A5 5A
 *        2 : SEQ
 *        3 : WE                00 = READ, 01 = WRITE
 *        4 : SEL               bits 3:0 validos y distintos de cero
 *     5..8 : ADR               little-endian, direccion de byte alineada
 *    9..12 : DAT               little-endian; cero en READ
 *   13..14 : CRC-16            low byte first; cubre indices 2..12
 *
 *  Respuesta UART, 10 bytes:
 *     0..1 : 5A A5
 *        2 : SEQ
 *        3 : STATUS            00 OK, 01 format, 02 CRC, 03 ERR, 04 timeout
 *     4..7 : DAT               dato de lectura; cero en WRITE/error
 *     8..9 : CRC-16            low byte first; cubre indices 2..7
 *
 *  CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, xorout 0.
 *  La FSM mantiene ADR/DAT/SEL/WE y CYC/STB hasta recibir ACK o ERR.
 *  Solo existe una transaccion Wishbone pendiente.
 *
 *  Al ser un modulo top Wishbone, sus puertos usan mayusculas y sufijos I/O.
 *  Las senales internas no usan _i ni _o.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module uart0_wbm #(

    // ---------------------------------------------------------
    //  Frecuencia interna del SoC.
    // ---------------------------------------------------------
    parameter integer CLK_FREQ = 50_000_000,

    // ---------------------------------------------------------
    //  Velocidad serie compartida con debugger.py.
    // ---------------------------------------------------------
    parameter integer BAUD_RATE = 57600,

    // ---------------------------------------------------------
    //  Numero de muestras RX por periodo de bit.
    // ---------------------------------------------------------
    parameter integer OVERSAMPLE = 16,

    // ---------------------------------------------------------
    //  Log2 de bytes almacenables en la RX FIFO.
    // ---------------------------------------------------------
    parameter integer FIFO_ADDR_WIDTH = 6,

    // ---------------------------------------------------------
    //  Limite de silencio entre bytes de una trama parcial.
    // ---------------------------------------------------------
    parameter integer RX_TIMEOUT_CYCLES = CLK_FREQ / 10

) (

    // ---------------------------------------------------------
    //  Reloj y reset Wishbone.
    // ---------------------------------------------------------
    input wire CLK_I,
    input wire RST_I,

    // ---------------------------------------------------------
    //  Pines serie UART0.
    // ---------------------------------------------------------
    input  wire RX_I,
    output wire TX_O,

    // ---------------------------------------------------------
    //  Wishbone Master M0.
    // ---------------------------------------------------------
    output reg  [31:0] ADR_O,
    output reg  [31:0] DAT_O,
    output wire [3:0]  SEL_O,
    output wire        WE_O,
    output wire        CYC_O,
    output wire        STB_O,
    input  wire [31:0] DAT_I,
    input  wire        ACK_I,
    input  wire        ERR_I,
    input  wire        TIMEOUT_I

);

    // ---------------------------------------------------------
    //  Byte recibido directamente desde uart.v.
    // ---------------------------------------------------------
    wire [7:0] rx_byte_data;
    wire       rx_byte_valid;

    // ---------------------------------------------------------
    //  Envio de bytes al transmisor UART.
    // ---------------------------------------------------------
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;

    // ========================================================================
    //  UART0
    // ------------------------------------------------------------------------
    //  uart.v no contiene FIFO. RX entrega un pulso por byte valido y TX usa
    //  el handshake local tx_start / tx_busy.
    // ========================================================================

    uart #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE),
        .OVERSAMPLE(OVERSAMPLE)
    ) uart_inst (
        .clk_i      (CLK_I),
        .rst_i      (RST_I),
        .rx_i       (RX_I),
        .tx_o       (TX_O),
        .rx_data_o  (rx_byte_data),
        .rx_valid_o (rx_byte_valid),
        .tx_data_i  (tx_data),
        .tx_start_i (tx_start),
        .tx_busy_o  (tx_busy)
    );

    // ---------------------------------------------------------
    //  Profundidad de la RX FIFO.
    // ---------------------------------------------------------
    localparam integer RX_FIFO_DEPTH = (1 << FIFO_ADDR_WIDTH);

    // ---------------------------------------------------------
    //  Memoria interna de la RX FIFO.
    // ---------------------------------------------------------
    reg [7:0] rx_fifo_mem [0:RX_FIFO_DEPTH-1];

    // ---------------------------------------------------------
    //  Punteros y ocupacion de la RX FIFO.
    // ---------------------------------------------------------
    reg [FIFO_ADDR_WIDTH-1:0] rx_fifo_wr_ptr;
    reg [FIFO_ADDR_WIDTH-1:0] rx_fifo_rd_ptr;
    reg [FIFO_ADDR_WIDTH:0]   rx_fifo_count;

    // ---------------------------------------------------------
    //  Estado combinacional de la RX FIFO.
    // ---------------------------------------------------------
    wire rx_fifo_empty;
    wire rx_fifo_full;
    wire rx_fifo_push;
    wire rx_fifo_pop;

    // ---------------------------------------------------------
    //  Interfaz FIFO hacia la FSM del bridge.
    // ---------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_ready;

    // ---------------------------------------------------------
    //  Pulso de overflow de la RX FIFO.
    // ---------------------------------------------------------
    reg rx_overflow;

    // ---------------------------------------------------------
    //  Estado empty/full de la RX FIFO.
    // ---------------------------------------------------------
    assign rx_fifo_empty = (rx_fifo_count == 0);
    assign rx_fifo_full  = (rx_fifo_count == RX_FIFO_DEPTH);

    // ---------------------------------------------------------
    //  Lectura FWFT de la RX FIFO.
    // ---------------------------------------------------------
    assign rx_valid    = ~rx_fifo_empty;
    assign rx_data     = rx_fifo_mem[rx_fifo_rd_ptr];
    assign rx_fifo_pop = rx_valid && rx_ready;

    // ---------------------------------------------------------
    //  Aceptacion de un nuevo byte desde uart.v.
    // ---------------------------------------------------------
    assign rx_fifo_push = rx_byte_valid && (!rx_fifo_full || rx_fifo_pop);

    // ========================================================================
    //  RX FIFO
    // ------------------------------------------------------------------------
    //  Push y pop simultaneos mantienen la ocupacion. Incluso con la FIFO
    //  llena se permite un push si en el mismo flanco se libera una posicion.
    //  rx_overflow es un pulso de un ciclo cuando un byte realmente se pierde.
    // ========================================================================

    always @(posedge CLK_I) begin
        if (RST_I) begin
            rx_fifo_wr_ptr <= {FIFO_ADDR_WIDTH{1'b0}};
            rx_fifo_rd_ptr <= {FIFO_ADDR_WIDTH{1'b0}};
            rx_fifo_count  <= {(FIFO_ADDR_WIDTH + 1){1'b0}};
            rx_overflow    <= 1'b0;
        end else begin
            rx_overflow <= 1'b0;

            if (rx_byte_valid && rx_fifo_full && !rx_fifo_pop)
                rx_overflow <= 1'b1;

            if (rx_fifo_push) begin
                rx_fifo_mem[rx_fifo_wr_ptr] <= rx_byte_data;
                rx_fifo_wr_ptr              <= rx_fifo_wr_ptr + 1'b1;
            end

            if (rx_fifo_pop)
                rx_fifo_rd_ptr <= rx_fifo_rd_ptr + 1'b1;

            case ({rx_fifo_push, rx_fifo_pop})
                2'b10:   rx_fifo_count <= rx_fifo_count + 1'b1;
                2'b01:   rx_fifo_count <= rx_fifo_count - 1'b1;
                default: rx_fifo_count <= rx_fifo_count;
            endcase
        end
    end

    // ---------------------------------------------------------
    //  Estados de la FSM UART/Wishbone.
    // ---------------------------------------------------------
    localparam [3:0] SYNC0     = 4'd0;
    localparam [3:0] SYNC1     = 4'd1;
    localparam [3:0] RECEIVE   = 4'd2;
    localparam [3:0] EXECUTE   = 4'd3;
    localparam [3:0] WB_WAIT   = 4'd4;
    localparam [3:0] PREPARE   = 4'd5;
    localparam [3:0] TX_SEND   = 4'd6;
    localparam [3:0] TX_ACCEPT = 4'd7;
    localparam [3:0] TX_WAIT   = 4'd8;
    localparam [3:0] DRAIN     = 4'd9;
    localparam [3:0] TX_CRC    = 4'd10;

    // ---------------------------------------------------------
    //  Estado actual e indices de recepcion/transmision.
    // ---------------------------------------------------------
    reg [3:0] state;
    reg [3:0] index;
    reg [3:0] tx_index;

    // ---------------------------------------------------------
    //  Campos conservados de la solicitud UART.
    // ---------------------------------------------------------
    reg [7:0] sequence_id;
    reg [7:0] operation;
    reg [7:0] selection;
    reg [7:0] crc_low;

    // ---------------------------------------------------------
    //  Estado de la respuesta UART.
    // ---------------------------------------------------------
    reg [7:0]  status;
    reg [31:0] response_data;

    // ---------------------------------------------------------
    //  Acumuladores CRC de request y response.
    // ---------------------------------------------------------
    reg [15:0] rx_crc;
    reg [15:0] tx_crc;

    // ---------------------------------------------------------
    //  Recovery ante timeout u overflow.
    // ---------------------------------------------------------
    reg [31:0] idle_count;
    reg        overflow_pending;

    // ---------------------------------------------------------
    //  Wishbone control derivado de los campos conservados.
    // ---------------------------------------------------------
    assign SEL_O = selection[3:0];
    assign WE_O  = operation[0];
    assign CYC_O = (state == WB_WAIT) && !RST_I;
    assign STB_O = CYC_O;

    // ---------------------------------------------------------
    //  Backpressure local entre la FSM y la RX FIFO.
    // ---------------------------------------------------------
    assign rx_ready = !RST_I &&
                      (state == SYNC0 || state == SYNC1 ||
                       state == RECEIVE || state == DRAIN);

    // ========================================================================
    //  CRC-16/CCITT-FALSE de un byte
    // ------------------------------------------------------------------------
    //  La funcion es combinacional. Los ocho pasos implementan poly 0x1021.
    //  El acumulador se registra en rx_crc o tx_crc fuera de la funcion.
    // ========================================================================

    function [15:0] crc_byte;
        input [15:0] crc;
        input [7:0] value;
        reg [15:0] c;
        integer k;
        begin
            c = crc ^ {value, 8'd0};
            for (k = 0; k < 8; k = k + 1)
                c = c[15] ? (c << 1) ^ 16'h1021 : (c << 1);
            crc_byte = c;
        end
    endfunction

    // ---------------------------------------------------------
    //  Byte actual de la response UART.
    // ---------------------------------------------------------
    reg [7:0] tx_byte;

    // ========================================================================
    //  Multiplexor de bytes de respuesta
    // ------------------------------------------------------------------------
    //  TX_CRC utiliza los indices 2..7; TX_SEND transmite los indices 0..9.
    //  Se comparte la seleccion de byte para calcular y transmitir la misma trama.
    // ========================================================================

    always @* begin
        case (tx_index)
            4'd0: tx_byte = 8'h5a;
            4'd1: tx_byte = 8'ha5;
            4'd2: tx_byte = sequence_id;
            4'd3: tx_byte = status;
            4'd4: tx_byte = response_data[7:0];
            4'd5: tx_byte = response_data[15:8];
            4'd6: tx_byte = response_data[23:16];
            4'd7: tx_byte = response_data[31:24];
            4'd8: tx_byte = tx_crc[7:0];
            4'd9: tx_byte = tx_crc[15:8];
            default: tx_byte = 8'd0;
        endcase
    end

    // ========================================================================
    //  FSM de recepcion, Wishbone transaction y respuesta
    // ------------------------------------------------------------------------
    //  SYNC0/SYNC1 buscan A5 5A. RECEIVE consume la trama desde la RX FIFO.
    //  EXECUTE valida formato. WB_WAIT mantiene el Classic SINGLE hasta ACK/ERR.
    //  PREPARE/TX_CRC construyen el CRC de respuesta. TX_SEND/TX_ACCEPT/TX_WAIT
    //  respetan el handshake start/busy de uart_tx. DRAIN vacia la FIFO despues
    //  de un overflow y exige un intervalo completo de silencio antes de rearmar.
    // ========================================================================

    always @(posedge CLK_I) begin
        if (RST_I) begin
            state            <= SYNC0;
            index            <= 4'd0;
            tx_index         <= 4'd0;
            sequence_id      <= 8'd0;
            operation        <= 8'd0;
            selection        <= 8'd0;
            crc_low          <= 8'd0;
            status           <= 8'd0;
            rx_crc           <= 16'hffff;
            tx_crc           <= 16'd0;
            response_data    <= 32'd0;
            idle_count       <= 32'd0;
            ADR_O            <= 32'd0;
            DAT_O            <= 32'd0;
            tx_data          <= 8'd0;
            tx_start         <= 1'b0;
            overflow_pending <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (rx_overflow)
                overflow_pending <= 1'b1;

            if (state == SYNC1 || state == RECEIVE || state == DRAIN) begin
                if (rx_valid)
                    idle_count <= 32'd0;
                else if (RX_TIMEOUT_CYCLES <= 1)
                    idle_count <= 32'd0;
                else if (idle_count < RX_TIMEOUT_CYCLES - 1)
                    idle_count <= idle_count + 1'b1;
            end else begin
                idle_count <= 32'd0;
            end

            case (state)

                SYNC0: begin
                    if (rx_valid && rx_data == 8'ha5)
                        state <= SYNC1;
                end

                SYNC1: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h5a) begin
                            state  <= RECEIVE;
                            index  <= 4'd0;
                            rx_crc <= 16'hffff;
                        end else if (rx_data != 8'ha5) begin
                            state <= SYNC0;
                        end
                    end
                end

                RECEIVE: begin
                    if (rx_valid) begin
                        if (index <= 10)
                            rx_crc <= crc_byte(rx_crc, rx_data);

                        case (index)
                            4'd0:  sequence_id <= rx_data;
                            4'd1:  operation <= rx_data;
                            4'd2:  selection <= rx_data;
                            4'd3:  ADR_O[7:0] <= rx_data;
                            4'd4:  ADR_O[15:8] <= rx_data;
                            4'd5:  ADR_O[23:16] <= rx_data;
                            4'd6:  ADR_O[31:24] <= rx_data;
                            4'd7:  DAT_O[7:0] <= rx_data;
                            4'd8:  DAT_O[15:8] <= rx_data;
                            4'd9:  DAT_O[23:16] <= rx_data;
                            4'd10: DAT_O[31:24] <= rx_data;
                            4'd11: crc_low <= rx_data;
                            4'd12: begin
                                response_data <= 32'd0;
                                if ({rx_data, crc_low} != rx_crc) begin
                                    status <= 8'h02;
                                    state  <= PREPARE;
                                end else begin
                                    state <= EXECUTE;
                                end
                            end
                            default: state <= SYNC0;
                        endcase

                        index <= index + 1'b1;
                    end
                end

                EXECUTE: begin
                    if (operation > 1 ||
                        selection[7:4] != 0 ||
                        selection[3:0] == 0 ||
                        ADR_O[1:0] != 0 ||
                        (operation == 0 && DAT_O != 0)) begin
                        status <= 8'h01;
                        state  <= PREPARE;
                    end else begin
                        state <= WB_WAIT;
                    end
                end

                WB_WAIT: begin
                    if (ERR_I || ACK_I) begin
                        status        <= ERR_I ? (TIMEOUT_I ? 8'h04 : 8'h03) : 8'h00;
                        response_data <= (!ERR_I && !WE_O) ? DAT_I : 32'd0;
                        state         <= PREPARE;
                    end
                end

                PREPARE: begin
                    tx_crc   <= 16'hffff;
                    tx_index <= 4'd2;
                    state    <= TX_CRC;
                end

                TX_CRC: begin
                    tx_crc <= crc_byte(tx_crc, tx_byte);
                    if (tx_index == 7) begin
                        tx_index <= 4'd0;
                        state    <= TX_SEND;
                    end else begin
                        tx_index <= tx_index + 1'b1;
                    end
                end

                TX_SEND: begin
                    if (!tx_busy) begin
                        tx_data  <= tx_byte;
                        tx_start <= 1'b1;
                        state    <= TX_ACCEPT;
                    end
                end

                TX_ACCEPT: begin
                    if (tx_busy)
                        state <= TX_WAIT;
                end

                TX_WAIT: begin
                    if (!tx_busy) begin
                        if (tx_index == 9) begin
                            state <= SYNC0;
                        end else begin
                            tx_index <= tx_index + 1'b1;
                            state    <= TX_SEND;
                        end
                    end
                end

                DRAIN: begin
                    if (!rx_valid &&
                        ((RX_TIMEOUT_CYCLES <= 1) || (idle_count >= RX_TIMEOUT_CYCLES - 1))) begin
                        overflow_pending <= 1'b0;
                        state            <= SYNC0;
                    end
                end

                default: state <= SYNC0;
            endcase

            if ((state == SYNC1 || state == RECEIVE) &&
                !rx_valid &&
                ((RX_TIMEOUT_CYCLES <= 1) || (idle_count >= RX_TIMEOUT_CYCLES - 1))) begin
                state <= SYNC0;
            end

            if ((state == SYNC0 || state == SYNC1 || state == RECEIVE) &&
                (rx_overflow || overflow_pending)) begin
                state      <= DRAIN;
                idle_count <= 32'd0;
            end
        end
    end

endmodule
