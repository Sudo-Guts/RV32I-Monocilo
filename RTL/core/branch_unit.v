`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : branch_unit
 *  Archivo  : branch_unit.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Unidad combinacional que determina si una instruccion BRANCH debe
 *      modificar el flujo secuencial del Program Counter.
 *
 *      Durante una instruccion BRANCH, control_unit configura la ALU para
 *      realizar:
 *
 *          rs1 - rs2
 *
 *      branch_unit interpreta las banderas generadas por la ALU junto con
 *      funct3_i para evaluar la condicion de salto.
 *
 *      Instrucciones soportadas:
 *
 *          BEQ   BNE
 *          BLT   BGE
 *          BLTU  BGEU
 *
 *      Comparacion signed:
 *
 *          rs1 < rs2  <=>  negative_i XOR overflow_i
 *
 *      Comparacion unsigned:
 *
 *          La resta se implementa como A + (~B) + 1.
 *          En este esquema, carry_i = 1 indica ausencia de borrow.
 *
 *      Si branch_i = 0, branch_taken_o permanece desactivada sin importar
 *      el valor de funct3_i o de las banderas de la ALU.
 *
 *      El modulo no contiene registros ni estado interno. La decision de
 *      branch se obtiene combinacionalmente durante el mismo ciclo de
 *      ejecucion de la instruccion.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module branch_unit (

    // ------------------------------------------------------------------------
    // Control de la instruccion
    // ------------------------------------------------------------------------

    input  wire       branch_i,
    input  wire [2:0] funct3_i,

    // ------------------------------------------------------------------------
    // Flags de la ALU
    // ------------------------------------------------------------------------

    input  wire       zero_i,
    input  wire       carry_i,
    input  wire       negative_i,
    input  wire       overflow_i,

    // ------------------------------------------------------------------------
    // Decision de branch
    // ------------------------------------------------------------------------

    output reg        branch_taken_o

);

// ----------------------------------------------------------------------------
// Codigos funct3 de instrucciones BRANCH
// ----------------------------------------------------------------------------

localparam [2:0] F3_BEQ  = 3'b000;
localparam [2:0] F3_BNE  = 3'b001;
localparam [2:0] F3_BLT  = 3'b100;
localparam [2:0] F3_BGE  = 3'b101;
localparam [2:0] F3_BLTU = 3'b110;
localparam [2:0] F3_BGEU = 3'b111;

// ----------------------------------------------------------------------------
// Resultados de comparacion
// ----------------------------------------------------------------------------

// Para comparaciones signed, el overflow corrige el bit de signo producido
// por la resta cuando ocurre desbordamiento aritmetico.
wire less_signed;

// Para comparaciones unsigned, carry_i = 0 indica que la resta requirio borrow.
wire less_unsigned;

assign less_signed   = negative_i ^ overflow_i;
assign less_unsigned = ~carry_i;

/*
 * ============================================================================
 *  BRANCH DECODER
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Logica de decision
// ----------------------------------------------------------------------------

always @* begin

    branch_taken_o = 1'b0;

    if (branch_i) begin
        case (funct3_i)

            F3_BEQ:
                branch_taken_o = zero_i;

            F3_BNE:
                branch_taken_o = ~zero_i;

            F3_BLT:
                branch_taken_o = less_signed;

            F3_BGE:
                branch_taken_o = ~less_signed;

            F3_BLTU:
                branch_taken_o = less_unsigned;

            F3_BGEU:
                branch_taken_o = ~less_unsigned;

            default:
                branch_taken_o = 1'b0;

        endcase
    end

end

endmodule