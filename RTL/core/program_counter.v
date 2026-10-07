`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : program_counter
 *  Archivo  : program_counter.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Registro de 32 bits que almacena la direccion de la instruccion actual.
 *
 *      El Program Counter conserva su valor mientras pc_en_i = 0 y captura
 *      next_pc_i en el siguiente flanco ascendente cuando pc_en_i = 1.
 *
 *      En la arquitectura monociclo, cada instruccion completa sus efectos
 *      arquitectonicos en un unico ciclo. Por ello, cpu_core habilita la
 *      actualizacion del PC en cada flanco en el que la CPU esta ejecutando:
 *
 *          pc_en_i = cpu_en_i & ~rst_i
 *
 *      Cuando la CPU se encuentra detenida, pc_en_i = 0 y el Program Counter
 *      conserva la direccion de la instruccion actual.
 *
 *      El reset es sincrono y activo en alto. Durante reset, el Program Counter
 *      toma el valor 32'd0 independientemente del estado de pc_en_i.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module program_counter (

    // ------------------------------------------------------------------------
    // Clock, reset y habilitacion
    // ------------------------------------------------------------------------

    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        pc_en_i,

    // ------------------------------------------------------------------------
    // Program Counter
    // ------------------------------------------------------------------------

    input  wire [31:0] next_pc_i,
    output reg  [31:0] pc_o

);

// ----------------------------------------------------------------------------
// Program Counter Register
// ----------------------------------------------------------------------------

always @(posedge clk_i) begin
    if (rst_i)
        pc_o <= 32'd0;
    else if (pc_en_i)
        pc_o <= next_pc_i;
end

endmodule