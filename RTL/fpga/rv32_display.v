`timescale 1ns / 1ps

/*
 * ========================================================================
 *  RV32 Display - Barrido de cuatro digitos
 * ------------------------------------------------------------------------
 *  Muestra el texto fijo "rv32" en los displays de siete segmentos Nexys3.
 *  No muestra instrucciones, PC ni registros de la CPU.
 *  an_o, seg_o y dp_o son activos en bajo porque los displays son de anodo comun.
 *
 *  SCAN_HZ indica cambios de digito por segundo, no barridos completos.
 *  Con SCAN_HZ = 1000 se selecciona un digito cada milisegundo y cada uno
 *  reaparece a 250 Hz. CLK_FREQ debe coincidir con el reloj interno real.
 *
 *  Orden visual de izquierda a derecha: AN3 = r, AN2 = v, AN1 = 3, AN0 = 2.
 *  seg_o[6:0] = {CG, CF, CE, CD, CC, CB, CA}; un cero enciende el segmento.
 *  El punto decimal de AN0 refleja dcm_error_i mientras ese digito esta activo.
 *  El barrido necesita clk_i; no constituye un monitor independiente del reloj.
 *
 *  rst_i es sincrono, activo en alto: reinicia contador y seleccion del digito.
 *  Los patrones se decodifican combinacionalmente a partir de digit_select.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module rv32_display #(
    // Frecuencia interna en Hz; debe coincidir con clk_i.
    parameter integer CLK_FREQ = 50_000_000,
    // Cambios de digito por segundo; cada digito ve SCAN_HZ/4.
    parameter integer SCAN_HZ  = 1000

) (

    // --------------------------------------------------------
    //          Reloj y reset
    // --------------------------------------------------------
    input wire clk_i,  // Reloj del modulo; flanco ascendente.
    input wire rst_i,  // Reset activo en alto.

    // --------------------------------------------------------
    //          Puertos de displays
    // --------------------------------------------------------
    input  wire       dcm_error_i,  // Indicador usado por el punto decimal AN0.
    output reg  [6:0] seg_o,        // Segmentos {CG..CA}, activos en bajo.
    output reg  [3:0] an_o,         // Seleccion AN3..AN0, activa en bajo.
    output reg        dp_o          // Punto decimal, activo en bajo.

);

    // ============================================================
    //              clog2
    // ============================================================
    //
    //   Calcula el numero minimo de bits necesarios para representar
    //   un contador o indice de tamano "value".
    //
    //   Ejemplos:
    //      clog2(16) = 4 bits
    //      clog2(27) = 5 bits
    //      clog2(434) = 9 bits
    //
    //   Se utiliza durante sintesis para dimensionar registros de
    //   forma automatica.
    //
    // ============================================================

    function integer clog2;
        input integer value;
        integer temp;
        begin
            temp = value - 1;
            for (clog2 = 0; temp > 0; clog2 = clog2 + 1) temp = temp >> 1;
        end
    endfunction

    // ============================================================
    //              Divisor de barrido
    // ============================================================
    //
    //  SCAN_HZ indica cuantas veces por segundo cambia el digito
    //  activo.
    //
    //  Con SCAN_HZ = 1000:
    //
    //      cada digito se actualiza a 250 Hz.
    //
    // ============================================================

    localparam integer SCAN_DIV = CLK_FREQ / SCAN_HZ;
    localparam integer SCAN_COUNT_WIDTH = (SCAN_DIV <= 1) ? 1 : clog2(SCAN_DIV);

    reg [SCAN_COUNT_WIDTH-1:0] scan_count;
    reg [1:0]                  digit_select;

    // ============================================================
    //              Contador de barrido
    // ============================================================

    always @(posedge clk_i) begin
        if (rst_i) begin
            scan_count   <= {SCAN_COUNT_WIDTH{1'b0}};
            digit_select <= 2'd0;
        end else begin
            if (scan_count == SCAN_DIV - 1) begin
                scan_count   <= {SCAN_COUNT_WIDTH{1'b0}};
                digit_select <= digit_select + 1'b1;
            end else begin
                scan_count <= scan_count + 1'b1;
            end
        end
    end

    // ============================================================
    //              Decodificacion de segmentos
    // ============================================================
    //
    // seg_o[6:0] = {CG, CF, CE, CD, CC, CB, CA}
    //
    // Patrones activos en bajo.
    //
    // Orden visual:
    //      AN3  AN2  AN1  AN0
    //       r    v    3    2
    //
    // ============================================================

    always @* begin
        an_o  = 4'b1111;
        seg_o = 7'b1111111;
        dp_o  = 1'b1;
        case (digit_select)
            // ------------------------------------------------
            //  r
            // ------------------------------------------------
            2'd0: begin
                an_o  = 4'b0111;
                seg_o = 7'b0101111;
            end
            // ------------------------------------------------
            //  v
            // ------------------------------------------------
            2'd1: begin
                an_o  = 4'b1011;
                seg_o = 7'b1100011;
            end
            // ------------------------------------------------
            //  3
            // ------------------------------------------------
            2'd2: begin
                an_o  = 4'b1101;
                seg_o = 7'b0110000;
            end
            // ------------------------------------------------
            // 2
            // ------------------------------------------------
            //
            // El DP de este digito representa dcm_error_i.
            //
            // ------------------------------------------------
            2'd3: begin
                an_o  = 4'b1110;
                seg_o = 7'b0100100;
                dp_o  = dcm_error_i ? 1'b0 : 1'b1;
            end
            default: begin
                an_o  = 4'b1111;
                seg_o = 7'b1111111;
                dp_o  = 1'b1;
            end
        endcase
    end
endmodule
