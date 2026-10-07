`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : imm_gen
 *  Archivo  : imm_gen.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Generador combinacional de inmediatos para instrucciones RV32I.
 *
 *      El modulo recibe la instruccion completa de 32 bits y, a partir de su
 *      opcode, identifica el formato correspondiente para reconstruir el
 *      inmediato utilizado por el datapath.
 *
 *      Formatos soportados:
 *
 *          I - I-ALU, LOAD y JALR
 *          S - STORE
 *          B - BRANCH
 *          U - LUI y AUIPC
 *          J - JAL
 *
 *      Los formatos I, S, B y J realizan extension de signo hasta 32 bits.
 *
 *      El formato U conserva instr_i[31:12] y completa los 12 bits menos
 *      significativos con ceros.
 *
 *      Para los formatos B y J, imm_o[0] siempre es cero debido a que el
 *      desplazamiento codificado tiene alineamiento minimo de 2 bytes.
 *
 *      Este modulo no contiene registros ni estado interno. Cualquier cambio
 *      en instr_i se refleja combinacionalmente en imm_o.
 *
 *      En el datapath monociclo, imm_o puede utilizarse durante el mismo ciclo
 *      para:
 *
 *          - operaciones ALU con inmediato.
 *          - calculo de direcciones de LOAD y STORE.
 *          - calculo de destinos de BRANCH, JAL y JALR.
 *          - generacion del valor de LUI y AUIPC.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module imm_gen (

    input  wire [31:0] instr_i,
    output reg  [31:0] imm_o

);

// ----------------------------------------------------------------------------
// Opcodes RV32I que utilizan inmediato
// ----------------------------------------------------------------------------

localparam [6:0] OP_I_ALU  = 7'b0010011;
localparam [6:0] OP_LOAD   = 7'b0000011;
localparam [6:0] OP_STORE  = 7'b0100011;
localparam [6:0] OP_BRANCH = 7'b1100011;

localparam [6:0] OP_JALR   = 7'b1100111;
localparam [6:0] OP_JAL    = 7'b1101111;
localparam [6:0] OP_LUI    = 7'b0110111;
localparam [6:0] OP_AUIPC  = 7'b0010111;

// ----------------------------------------------------------------------------
// Opcode
// ----------------------------------------------------------------------------

wire [6:0] opcode;

assign opcode = instr_i[6:0];

/*
 * ============================================================================
 *  IMMEDIATE GENERATION
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Decodificacion del formato y construccion del inmediato
// ----------------------------------------------------------------------------

always @* begin
    case (opcode)

        // --------------------------------------------------------------------
        // I-Type
        //
        // imm[11:0] = instr[31:20]
        // --------------------------------------------------------------------
        OP_I_ALU,
        OP_LOAD,
        OP_JALR:
            imm_o = {
                {20{instr_i[31]}},
                instr_i[31:20]
            };

        // --------------------------------------------------------------------
        // S-Type
        //
        // imm[11:5] = instr[31:25]
        // imm[4:0]  = instr[11:7]
        // --------------------------------------------------------------------
        OP_STORE:
            imm_o = {
                {20{instr_i[31]}},
                instr_i[31:25],
                instr_i[11:7]
            };

        // --------------------------------------------------------------------
        // B-Type
        //
        // imm[12]   = instr[31]
        // imm[11]   = instr[7]
        // imm[10:5] = instr[30:25]
        // imm[4:1]  = instr[11:8]
        // imm[0]    = 0
        // --------------------------------------------------------------------
        OP_BRANCH:
            imm_o = {
                {19{instr_i[31]}},
                instr_i[31],
                instr_i[7],
                instr_i[30:25],
                instr_i[11:8],
                1'b0
            };

        // --------------------------------------------------------------------
        // U-Type
        //
        // imm[31:12] = instr[31:12]
        // imm[11:0]  = 0
        // --------------------------------------------------------------------
        OP_LUI,
        OP_AUIPC:
            imm_o = {
                instr_i[31:12],
                12'b0
            };

        // --------------------------------------------------------------------
        // J-Type
        //
        // imm[20]    = instr[31]
        // imm[19:12] = instr[19:12]
        // imm[11]    = instr[20]
        // imm[10:1]  = instr[30:21]
        // imm[0]     = 0
        // --------------------------------------------------------------------
        OP_JAL:
            imm_o = {
                {11{instr_i[31]}},
                instr_i[31],
                instr_i[19:12],
                instr_i[20],
                instr_i[30:21],
                1'b0
            };

        default:
            imm_o = 32'd0;

    endcase
end

endmodule
