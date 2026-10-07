`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : alu
 *  Archivo  : alu.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Arithmetic Logic Unit del datapath monociclo RV32I.
 *
 *      La ALU es un bloque puramente combinacional que recibe dos operandos
 *      de 32 bits y ejecuta la operacion indicada por opcode_i.
 *
 *      La ALU implementa las operaciones aritmeticas, logicas, de
 *      desplazamiento y comparacion utilizadas por el procesador:
 *
 *          AND   OR    XOR
 *          ADD   SUB
 *          SLT   SLTU
 *          SLL   SRL   SRA
 *
 *      ADD y SUB comparten un sumador/restador de 33 bits. El bit adicional
 *      conserva el carry de salida requerido por algunas comparaciones de
 *      branch.
 *
 *      Durante una instruccion BRANCH, control_unit configura la ALU para
 *      realizar rs1 - rs2. Los flags generados por esta operacion son
 *      utilizados posteriormente por branch_unit para evaluar la condicion
 *      de salto.
 *
 *      La ALU genera cuatro flags:
 *
 *          zero_o
 *              Se activa cuando result_o es igual a cero.
 *
 *          carry_o
 *              Corresponde al bit 32 del sumador/restador compartido.
 *              Durante SUB, carry_o = 1 indica ausencia de borrow.
 *
 *          negative_o
 *              Refleja el bit de signo del resultado: result_o[31].
 *
 *          overflow_o
 *              Indica overflow aritmetico con signo para ADD y SUB.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module alu (

    // ------------------------------------------------------------------------
    // Operandos y seleccion de operacion
    // ------------------------------------------------------------------------

    input wire [31:0] a_i,
    input wire [31:0] b_i,
    input wire [ 3:0] opcode_i,

    // ------------------------------------------------------------------------
    // Resultado y flags
    // ------------------------------------------------------------------------

    output reg  [31:0] result_o,
    output reg         overflow_o,
    output wire        zero_o,
    output wire        carry_o,
    output wire        negative_o

);

  // ----------------------------------------------------------------------------
  // Codigos de operacion de la ALU
  // ----------------------------------------------------------------------------

  localparam [3:0] ALU_AND  = 4'b0000;
  localparam [3:0] ALU_OR   = 4'b0001;
  localparam [3:0] ALU_ADD  = 4'b0010;
  localparam [3:0] ALU_XOR  = 4'b0100;
  localparam [3:0] ALU_SUB  = 4'b0110;
  localparam [3:0] ALU_SLT  = 4'b0111;
  localparam [3:0] ALU_SLL  = 4'b1000;
  localparam [3:0] ALU_SRL  = 4'b1001;
  localparam [3:0] ALU_SRA  = 4'b1010;
  localparam [3:0] ALU_SLTU = 4'b1011;

  /*
 * ============================================================================
 *  SHARED ADDER / SUBTRACTOR
 * ============================================================================
 */

  // ----------------------------------------------------------------------------
  // Sumador/restador de 33 bits
  // ----------------------------------------------------------------------------

  // SUB se implementa mediante complemento a dos:
  //
  //     A - B = A + (~B) + 1
  //
  wire [32:0] arithmetic_result;
  wire [31:0] sum_result;
  wire        carry_out;

  assign arithmetic_result = (opcode_i == ALU_SUB) ? ({1'b0, a_i} + {1'b0, ~b_i} + 33'd1)
                                                 : ({1'b0, a_i} + {1'b0,  b_i});

  assign sum_result = arithmetic_result[31:0];
  assign carry_out = arithmetic_result[32];

  /*
 * ============================================================================
 *  ALU DATAPATH
 * ============================================================================
 */

  // ----------------------------------------------------------------------------
  // Logica combinacional
  // ----------------------------------------------------------------------------

  // Los shifts utilizan solo b_i[4:0], ya que RV32I opera con palabras de
  // 32 bits y admite desplazamientos entre 0 y 31 posiciones.

  always @* begin

    result_o   = 32'd0;
    overflow_o = 1'b0;

    case (opcode_i)

      ALU_ADD: begin
        result_o = sum_result;

        // Overflow signed para A + B:
        // operandos con igual signo y resultado con signo diferente.
        overflow_o = (a_i[31] & b_i[31] & ~sum_result[31]) | (~a_i[31] & ~b_i[31] & sum_result[31]);
      end

      ALU_SUB: begin
        result_o = sum_result;

        // Overflow signed para A - B:
        // operandos con signo diferente y resultado con signo diferente
        // al operando A.
        overflow_o = (a_i[31] & ~b_i[31] & ~sum_result[31]) | (~a_i[31] & b_i[31] & sum_result[31]);
      end

      ALU_AND: result_o = a_i & b_i;

      ALU_OR: result_o = a_i | b_i;

      ALU_XOR: result_o = a_i ^ b_i;

      ALU_SLT: result_o = ($signed(a_i) < $signed(b_i)) ? 32'd1 : 32'd0;

      ALU_SLTU: result_o = (a_i < b_i) ? 32'd1 : 32'd0;

      ALU_SLL: result_o = a_i << b_i[4:0];

      ALU_SRL: result_o = a_i >> b_i[4:0];

      ALU_SRA: result_o = $signed(a_i) >>> b_i[4:0];

      default: result_o = 32'd0;

    endcase

  end

  // ----------------------------------------------------------------------------
  // Flags combinacionales
  // ----------------------------------------------------------------------------

  assign zero_o     = (result_o == 32'd0);
  assign carry_o    = carry_out;
  assign negative_o = result_o[31];

endmodule
