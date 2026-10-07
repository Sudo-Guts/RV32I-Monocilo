`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : cpu_core
 *  Archivo  : cpu_core.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Datapath principal de un procesador RV32I monociclo.
 *
 *      Cada instruccion se resuelve mediante un unico camino combinacional
 *      entre dos flancos de reloj:
 *
 *          PC
 *           |
 *           v
 *          IMEM
 *           |
 *           v
 *      Decode / Register File / Immediate Generator
 *           |
 *           v
 *          ALU
 *           |
 *           v
 *          LSU / Data Memory
 *           |
 *           v
 *      Write Back
 *
 *      Cuando cpu_en_i = 1, el siguiente flanco ascendente compromete los
 *      efectos arquitectonicos de la instruccion actual:
 *
 *          - actualizacion del Program Counter.
 *          - escritura en el Register File, cuando corresponda.
 *          - escritura en Data Memory para instrucciones STORE.
 *
 *      Cuando cpu_en_i = 0, el estado arquitectonico se conserva.
 *
 *      Instruction Memory y Data Memory utilizan interfaces locales
 *      independientes con direcciones de byte y base cero. Estas interfaces
 *      NO implementan Wishbone. La integracion con Wishbone pertenece al nivel
 *      superior del SoC.
 *
 *      El reset es sincrono y activo en alto. Reinicia el Program Counter e
 *      inhibe escrituras durante ese ciclo, pero no borra el Register File ni
 *      las memorias externas al core.
 *
 *      La LSU detecta accesos invalidos y desalineados. Mientras no exista
 *      manejo de traps, estos fallos simplemente inhiben los efectos laterales
 *      sobre Data Memory y Register File.
 *
 *      Esta version no implementa:
 *
 *          - traps o excepciones.
 *          - CSR.
 *          - interrupciones.
 *          - caches.
 *          - pipeline.
 *          - interfaz Wishbone dentro del core.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module cpu_core (

    // ------------------------------------------------------------------------
    // Clock, reset y control de ejecucion
    // ------------------------------------------------------------------------

    input wire clk_i,
    input wire rst_i,
    input wire cpu_en_i,

    // ------------------------------------------------------------------------
    // Instruction Memory
    // ------------------------------------------------------------------------

    input  wire [31:0] imem_rdata_i,
    output wire [31:0] imem_addr_o,

    // ------------------------------------------------------------------------
    // Data Memory
    // ------------------------------------------------------------------------

    input  wire [31:0] dmem_rdata_i,
    output wire [31:0] dmem_addr_o,
    output wire [31:0] dmem_wdata_o,
    output wire        dmem_we_o,
    output wire [ 3:0] dmem_byte_enable_o,

    // ------------------------------------------------------------------------
    // Register File Debug
    // ------------------------------------------------------------------------

    input  wire [ 4:0] dbg_reg_addr_i,
    output wire [31:0] dbg_reg_data_o,

    // ------------------------------------------------------------------------
    // Observacion del nucleo
    // ------------------------------------------------------------------------

    output wire [31:0] dbg_pc_o,
    output wire [31:0] dbg_instr_o,
    output wire [31:0] dbg_wb_data_o,

    // ------------------------------------------------------------------------
    // Observacion de fallos de memoria
    // ------------------------------------------------------------------------

    output wire        dbg_mem_misaligned_o,
    output wire        dbg_mem_invalid_o,
    output wire        dbg_mem_load_o,
    output wire        dbg_mem_store_o,
    output wire [31:0] dbg_mem_addr_o

);

  // ----------------------------------------------------------------------------
  // Senales de control
  // ----------------------------------------------------------------------------

  wire        reg_write;

  wire        load;
  wire        store;

  wire        alu_src_a;
  wire        alu_src_b;

  wire        branch;
  wire        pc_src;
  wire        jalr;

  wire [ 1:0] rd_src;
  wire [ 3:0] alu_control;

  // ----------------------------------------------------------------------------
  // Program Counter y seleccion del siguiente PC
  // ----------------------------------------------------------------------------

  wire [31:0] pc;

  wire [31:0] pc_offset;
  wire [31:0] pc_plus;
  wire [31:0] pc_target;
  wire [31:0] next_pc;

  wire        branch_taken;

  // ----------------------------------------------------------------------------
  // Senales utilizadas posteriormente por el datapath
  // ----------------------------------------------------------------------------

  wire [31:0] imm;
  wire [31:0] alu_result;

  // ----------------------------------------------------------------------------
  // Calculo del siguiente Program Counter
  // ----------------------------------------------------------------------------

  assign pc_offset = branch_taken ? imm : 32'd4;

  assign pc_plus   = pc + pc_offset;

  // JALR requiere limpiar el bit menos significativo de la direccion destino.
  assign pc_target = alu_result & {{31{1'b1}}, ~jalr};

  assign next_pc   = pc_src ? pc_target : pc_plus;

  // ----------------------------------------------------------------------------
  // Program Counter
  // ----------------------------------------------------------------------------

  program_counter u_pc (
      .clk_i  (clk_i),
      .rst_i  (rst_i),
      .pc_en_i(cpu_en_i & ~rst_i),

      .next_pc_i(next_pc),
      .pc_o     (pc)
  );

  assign imem_addr_o = pc;

  // ----------------------------------------------------------------------------
  // Instruccion actual
  // ----------------------------------------------------------------------------

  wire [31:0] instr;

  assign instr = imem_rdata_i;

  // ----------------------------------------------------------------------------
  // Campos de la instruccion
  // ----------------------------------------------------------------------------

  wire [6:0] opcode;
  wire [2:0] funct3;
  wire [6:0] funct7;

  wire [4:0] rs1;
  wire [4:0] rs2;
  wire [4:0] rd;

  assign opcode = instr[6:0];

  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  assign rs1 = instr[19:15];
  assign rs2 = instr[24:20];
  assign rd = instr[11:7];

  // ----------------------------------------------------------------------------
  // Immediate Generator
  // ----------------------------------------------------------------------------

  imm_gen u_imm_gen (
      .instr_i(instr),
      .imm_o  (imm)
  );

  // ----------------------------------------------------------------------------
  // Register File
  // ----------------------------------------------------------------------------

  wire [31:0] rs1_data;
  wire [31:0] rs2_data;

  wire [31:0] rd_data;
  wire        rf_we;

  assign rf_we = reg_write & ~mem_access_fault;

  register_file u_reg_file (
      .clk_i   (clk_i),
      .cpu_en_i(cpu_en_i & ~rst_i),
      .we_i    (rf_we),

      .raddr1_i(rs1),
      .raddr2_i(rs2),

      .waddr_i(rd),
      .wdata_i(rd_data),

      .rdata1_o(rs1_data),
      .rdata2_o(rs2_data),

      .dbg_raddr_i(dbg_reg_addr_i),
      .dbg_rdata_o(dbg_reg_data_o)
  );

  // ----------------------------------------------------------------------------
  // Control Unit
  // ----------------------------------------------------------------------------

  control_unit u_control (
      .opcode_i(opcode),
      .funct3_i(funct3),
      .funct7_i(funct7),

      .alu_src_a_o  (alu_src_a),
      .alu_src_b_o  (alu_src_b),
      .alu_control_o(alu_control),

      .branch_o(branch),
      .pc_src_o(pc_src),
      .jalr_o  (jalr),

      .load_o (load),
      .store_o(store),

      .reg_write_o(reg_write),
      .rd_src_o   (rd_src)
  );

  // ----------------------------------------------------------------------------
  // Multiplexores de entrada de la ALU
  // ----------------------------------------------------------------------------

  wire [31:0] src_a;
  wire [31:0] src_b;

  assign src_a = alu_src_a ? pc : rs1_data;
  assign src_b = alu_src_b ? imm : rs2_data;

  // ----------------------------------------------------------------------------
  // Arithmetic Logic Unit
  // ----------------------------------------------------------------------------

  wire zero;
  wire carry;
  wire negative;
  wire overflow;

  alu u_alu (
      .a_i     (src_a),
      .b_i     (src_b),
      .opcode_i(alu_control),

      .result_o(alu_result),

      .zero_o    (zero),
      .overflow_o(overflow),
      .carry_o   (carry),
      .negative_o(negative)
  );

  // ----------------------------------------------------------------------------
  // Branch Unit
  // ----------------------------------------------------------------------------

  branch_unit u_branch (
      .branch_i(branch),
      .funct3_i(funct3),

      .zero_i    (zero),
      .carry_i   (carry),
      .negative_i(negative),
      .overflow_i(overflow),

      .branch_taken_o(branch_taken)
  );

  // ----------------------------------------------------------------------------
  // Load / Store Memory
  // ----------------------------------------------------------------------------

  wire [31:0] load_data;

  wire        lsu_misaligned;
  wire        lsu_invalid_access;
  wire        mem_access_fault;

  load_store_memory u_memory (
      .cpu_en_i(cpu_en_i & ~rst_i),

      .funct3_i(funct3),
      .addr_i  (alu_result),

      .load_i (load),
      .store_i(store),

      .store_data_i(rs2_data),
      .load_data_o (load_data),

      .dmem_rdata_i(dmem_rdata_i),

      .dmem_addr_o       (dmem_addr_o),
      .dmem_wdata_o      (dmem_wdata_o),
      .dmem_we_o         (dmem_we_o),
      .dmem_byte_enable_o(dmem_byte_enable_o),

      .misaligned_o      (lsu_misaligned),
      .invalid_access_o  (lsu_invalid_access),
      .mem_access_fault_o(mem_access_fault)
  );

  // ----------------------------------------------------------------------------
  // Writeback Mux
  // ----------------------------------------------------------------------------

  assign rd_data = (rd_src == 2'b00) ? alu_result :
                 (rd_src == 2'b01) ? load_data  :
                 (rd_src == 2'b10) ? pc_plus    :
                 (rd_src == 2'b11) ? imm        :
                                     32'd0;

  /*
 * ============================================================================
 *  DEBUG
 * ============================================================================
 */

  // ----------------------------------------------------------------------------
  // Senales de observacion
  // ----------------------------------------------------------------------------

  // Las salidas de debug observan directamente el camino combinacional actual.
  assign dbg_pc_o = pc;
  assign dbg_instr_o = instr;
  assign dbg_wb_data_o = rd_data;

  assign dbg_mem_misaligned_o = lsu_misaligned;
  assign dbg_mem_invalid_o = lsu_invalid_access;

  assign dbg_mem_load_o = load;
  assign dbg_mem_store_o = store;
  assign dbg_mem_addr_o = alu_result;

endmodule
