`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : control_unit
 *  Archivo  : control_unit.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Unidad de control combinacional para el datapath monociclo RV32I.
 *
 *      La unidad recibe los campos principales de la instruccion actual:
 *
 *          opcode
 *          funct3
 *          funct7
 *
 *      y genera directamente las senales que configuran el datapath durante
 *      el mismo ciclo de ejecucion.
 *
 *      Las senales de control determinan:
 *
 *          - operandos utilizados por la ALU.
 *          - operacion ejecutada por la ALU.
 *          - acceso LOAD o STORE.
 *          - evaluacion de BRANCH.
 *          - seleccion del siguiente Program Counter.
 *          - fuente de datos para Writeback.
 *          - habilitacion de escritura del Register File.
 *
 *      Para un opcode no reconocido todas las senales permanecen inactivas,
 *      por lo que la instruccion no produce efectos arquitectonicos.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module control_unit (

    // ------------------------------------------------------------------------
    // Campos de la instruccion
    // ------------------------------------------------------------------------

    input  wire [6:0] opcode_i,
    input  wire [2:0] funct3_i,
    input  wire [6:0] funct7_i,

    // ------------------------------------------------------------------------
    // Control de la ALU
    // ------------------------------------------------------------------------

    output reg        alu_src_a_o,
    output reg        alu_src_b_o,
    output reg [3:0]  alu_control_o,

    // ------------------------------------------------------------------------
    // Control de flujo
    // ------------------------------------------------------------------------

    output reg        branch_o,
    output reg        pc_src_o,
    output reg        jalr_o,

    // ------------------------------------------------------------------------
    // Control de memoria
    // ------------------------------------------------------------------------

    output reg        load_o,
    output reg        store_o,

    // ------------------------------------------------------------------------
    // Control de Writeback
    // ------------------------------------------------------------------------

    output reg        reg_write_o,
    output reg [1:0]  rd_src_o

);

// ----------------------------------------------------------------------------
// Opcodes RV32I
// ----------------------------------------------------------------------------

localparam [6:0] OP_R       = 7'b0110011;
localparam [6:0] OP_I_ALU   = 7'b0010011;
localparam [6:0] OP_LOAD    = 7'b0000011;
localparam [6:0] OP_STORE   = 7'b0100011;
localparam [6:0] OP_BRANCH  = 7'b1100011;

localparam [6:0] OP_JAL     = 7'b1101111;
localparam [6:0] OP_JALR    = 7'b1100111;
localparam [6:0] OP_LUI     = 7'b0110111;
localparam [6:0] OP_AUIPC   = 7'b0010111;


// ----------------------------------------------------------------------------
// Valores funct3 para operaciones ALU
// ----------------------------------------------------------------------------

localparam [2:0] F3_ADD_SUB = 3'b000;
localparam [2:0] F3_SLL     = 3'b001;
localparam [2:0] F3_SLT     = 3'b010;
localparam [2:0] F3_SLTU    = 3'b011;
localparam [2:0] F3_XOR     = 3'b100;
localparam [2:0] F3_SRL_SRA = 3'b101;
localparam [2:0] F3_OR      = 3'b110;
localparam [2:0] F3_AND     = 3'b111;

// ----------------------------------------------------------------------------
// Codigos de operacion de la ALU
// ----------------------------------------------------------------------------

localparam [3:0] ALU_AND    = 4'b0000;
localparam [3:0] ALU_OR     = 4'b0001;
localparam [3:0] ALU_ADD    = 4'b0010;
localparam [3:0] ALU_XOR    = 4'b0100;
localparam [3:0] ALU_SUB    = 4'b0110;
localparam [3:0] ALU_SLT    = 4'b0111;
localparam [3:0] ALU_SLL    = 4'b1000;
localparam [3:0] ALU_SRL    = 4'b1001;
localparam [3:0] ALU_SRA    = 4'b1010;
localparam [3:0] ALU_SLTU   = 4'b1011;

// ----------------------------------------------------------------------------
// Fuentes de Writeback
// ----------------------------------------------------------------------------

localparam [1:0] WB_ALU     = 2'b00;
localparam [1:0] WB_MEM     = 2'b01;
localparam [1:0] WB_PC4     = 2'b10;
localparam [1:0] WB_IMM     = 2'b11;

/*
 * ============================================================================
 *  ALU DECODER
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Decodificacion de operaciones aritmeticas y logicas
// ----------------------------------------------------------------------------

function [3:0] decode_alu;

    input [6:0] funct7;
    input [2:0] funct3;
    input [6:0] opcode;

    begin
        case (funct3)

            F3_ADD_SUB: begin
                if (opcode == OP_I_ALU)
                    decode_alu = ALU_ADD;
                else if (funct7 == 7'b0100000)
                    decode_alu = ALU_SUB;
                else
                    decode_alu = ALU_ADD;
            end

            F3_SLL:
                decode_alu = ALU_SLL;

            F3_SLT:
                decode_alu = ALU_SLT;

            F3_SLTU:
                decode_alu = ALU_SLTU;

            F3_XOR:
                decode_alu = ALU_XOR;

            F3_SRL_SRA: begin
                if (funct7 == 7'b0100000)
                    decode_alu = ALU_SRA;
                else
                    decode_alu = ALU_SRL;
            end

            F3_OR:
                decode_alu = ALU_OR;

            F3_AND:
                decode_alu = ALU_AND;

            default:
                decode_alu = ALU_ADD;

        endcase
    end

endfunction

/*
 * ============================================================================
 *  CONTROL DECODER
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Decodificacion combinacional de la instruccion
// ----------------------------------------------------------------------------

always @* begin

    // ------------------------------------------------------------------------
    // Valores seguros por defecto
    // ------------------------------------------------------------------------

    alu_src_a_o   = 1'b0;
    alu_src_b_o   = 1'b0;
    alu_control_o = ALU_ADD;

    branch_o      = 1'b0;
    pc_src_o      = 1'b0;
    jalr_o        = 1'b0;

    load_o        = 1'b0;
    store_o       = 1'b0;

    reg_write_o   = 1'b0;
    rd_src_o      = WB_ALU;

    // ------------------------------------------------------------------------
    // Decode principal
    // ------------------------------------------------------------------------

    case (opcode_i)

        // --------------------------------------------------------------------
        // R-Type:
        //      rd <- rs1 OP rs2
        // --------------------------------------------------------------------

        OP_R: begin

            alu_src_a_o   = 1'b0;        // rs1
            alu_src_b_o   = 1'b0;        // rs2
            alu_control_o = decode_alu(funct7_i, funct3_i, opcode_i);

            reg_write_o   = 1'b1;
            rd_src_o      = WB_ALU;

        end

        // --------------------------------------------------------------------
        // I-Type ALU:
        //      rd <- rs1 OP immediate
        // --------------------------------------------------------------------

        OP_I_ALU: begin

            alu_src_a_o   = 1'b0;        // rs1
            alu_src_b_o   = 1'b1;        // immediate
            alu_control_o = decode_alu(funct7_i, funct3_i, opcode_i);

            reg_write_o   = 1'b1;
            rd_src_o      = WB_ALU;

        end

        // --------------------------------------------------------------------
        // LOAD:
        //      address = rs1 + immediate
        //      rd      = Memory[address]
        // --------------------------------------------------------------------

        OP_LOAD: begin

            alu_src_a_o   = 1'b0;        // rs1
            alu_src_b_o   = 1'b1;        // immediate
            alu_control_o = ALU_ADD;

            load_o        = 1'b1;

            reg_write_o   = 1'b1;
            rd_src_o      = WB_MEM;

        end

        // --------------------------------------------------------------------
        // STORE:
        //      address         = rs1 + immediate
        //      Memory[address] = rs2
        // --------------------------------------------------------------------

        OP_STORE: begin

            alu_src_a_o   = 1'b0;        // rs1
            alu_src_b_o   = 1'b1;        // immediate
            alu_control_o = ALU_ADD;

            store_o       = 1'b1;

        end

        // --------------------------------------------------------------------
        // BRANCH:
        //      La ALU ejecuta rs1 - rs2, branch_unit utiliza los flags 
        //      generados para evaluar BEQ/BNE/BLT/BGE/BLTU/BGEU.
        // --------------------------------------------------------------------

        OP_BRANCH: begin

            alu_src_a_o   = 1'b0;        // rs1
            alu_src_b_o   = 1'b0;        // rs2
            alu_control_o = ALU_SUB;

            branch_o      = 1'b1;

        end

        // --------------------------------------------------------------------
        // JAL:
        //      target = PC + immediate
        //      rd     = PC + 4
        // --------------------------------------------------------------------

        OP_JAL: begin

            alu_src_a_o   = 1'b1;        // PC
            alu_src_b_o   = 1'b1;        // immediate
            alu_control_o = ALU_ADD;

            pc_src_o      = 1'b1;

            reg_write_o   = 1'b1;
            rd_src_o      = WB_PC4;

        end

        // --------------------------------------------------------------------
        // JALR:
        //      target = rs1 + immediate
        //      rd     = PC + 4
        // cpu_core limpia posteriormente target[0].
        // --------------------------------------------------------------------

        OP_JALR: begin

            alu_src_a_o   = 1'b0;        // rs1
            alu_src_b_o   = 1'b1;        // immediate
            alu_control_o = ALU_ADD;

            pc_src_o      = 1'b1;
            jalr_o        = 1'b1;

            reg_write_o   = 1'b1;
            rd_src_o      = WB_PC4;

        end

        // --------------------------------------------------------------------
        // LUI
        //      rd <- immediate
        // --------------------------------------------------------------------

        OP_LUI: begin

            reg_write_o = 1'b1;
            rd_src_o    = WB_IMM;

        end

        // --------------------------------------------------------------------
        // AUIPC
        //      rd <- PC + immediate
        // --------------------------------------------------------------------

        OP_AUIPC: begin

            alu_src_a_o   = 1'b1;        // PC
            alu_src_b_o   = 1'b1;        // immediate
            alu_control_o = ALU_ADD;

            reg_write_o   = 1'b1;
            rd_src_o      = WB_ALU;

        end

        // --------------------------------------------------------------------
        // Opcode no implementado
        // --------------------------------------------------------------------

        default: begin

            // Los valores por defecto mantienen todos los efectos
            // arquitectonicos deshabilitados.

        end

    endcase

end

endmodule