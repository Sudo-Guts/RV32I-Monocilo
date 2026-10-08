`timescale 1ns / 1ps

/*
 * ========================================================================
 *  CPU SoC - Top Entity / Nexys3
 * ------------------------------------------------------------------------
 *  Entidad superior fisica del proyecto RV32I monociclo. Integra clock/reset,
 *  UART0 Wishbone master, crossbar, loader, debugger, CPU, IMEM, DMEM y display.
 *
 *  Jerarquia Wishbone:
 *
 *      M0  uart0_wbm
 *      M1  program_loader_wb
 *      M2  reservado para CPU multiciclo
 *      M3  reservado para CPU multiciclo
 *
 *      S0  instruction_memory_wbs
 *      S1  data_memory_wbs
 *      S2  program_loader_wb
 *      S3  debug_controller_wbs
 *
 *  wb_crossbar implementa cuatro entradas Master, cuatro Slaves y dos canales
 *  dinamicos. En esta revision monociclo M2/M3 permanecen inactivos.
 *  cpu_core conserva accesos locales punto a punto hacia IMEM y DMEM; esos
 *  accesos NO pasan por Wishbone para mantener el datapath monociclo.
 *
 *  uart0_wbm contiene la RX FIFO y el protocol bridge. uart.v queda reducido
 *  a convertir bits serie <-> bytes.
 *
 *  El top no es un modulo Wishbone; por convencion sus puertos fisicos usan
 *  minusculas con sufijo _i / _o. Si el UCF anterior usaba clk/rst/rx/tx,
 *  debe actualizarse a clk_i/rst_i/rx_i/tx_o y a seg_o/an_o/dp_o.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module cpu_soc #(

    // ---------------------------------------------------------
    //  Frecuencia interna solicitada.
    // ---------------------------------------------------------
    parameter integer CLK_FREQ = 50_000_000,

    // ---------------------------------------------------------
    //  Configuracion de UART0.
    // ---------------------------------------------------------
    parameter integer BAUD_RATE = 57600,
    parameter integer OVERSAMPLE = 16,
    parameter integer UART_FIFO_ADDR_WIDTH = 6,

    // ---------------------------------------------------------
    //  Capacidad de las memorias locales.
    // ---------------------------------------------------------
    parameter integer IMEM_WORD_ADDR_WIDTH = 9,
    parameter integer DMEM_WORD_ADDR_WIDTH = 8,

    // ---------------------------------------------------------
    //  Timeout de recepcion UART y wait states de las memorias.
    //  El timeout del bus Wishbone es fijo: 1024 ciclos en wb_crossbar.
    // ---------------------------------------------------------
    parameter integer RX_TIMEOUT_CYCLES  = CLK_FREQ / 10,
    parameter integer MEMORY_WAIT_CYCLES = 0

) (

    // ---------------------------------------------------------
    //  Reloj fisico y reset externo.
    // ---------------------------------------------------------
    input wire clk_i,
    input wire rst_i,

    // ---------------------------------------------------------
    //  UART0 fisica.
    // ---------------------------------------------------------
    input  wire rx_i,
    output wire tx_o,

    // ---------------------------------------------------------
    //  Display de siete segmentos.
    // ---------------------------------------------------------
    output wire [6:0] seg_o,
    output wire [3:0] an_o,
    output wire       dp_o

);

  // ---------------------------------------------------------
  //  Validez de la configuracion de reloj.
  // ---------------------------------------------------------
  localparam integer CLK_CONFIG_VALID =
        (CLK_FREQ == 100_000_000) ||
        (CLK_FREQ == 50_000_000)  ||
        (CLK_FREQ == 33_333_333)  ||
        (CLK_FREQ == 25_000_000)  ||
        (CLK_FREQ == 20_000_000)  ||
        (CLK_FREQ == 12_500_000)  ||
        (CLK_FREQ == 6_250_000);

  // ---------------------------------------------------------
  //  Divisor correspondiente al reloj fisico de 100 MHz.
  // ---------------------------------------------------------
  localparam integer CLOCK_DIVIDE = CLK_CONFIG_VALID ? (100_000_000 / CLK_FREQ) : 2;

  // ---------------------------------------------------------
  //  Frecuencia interna realmente producida.
  // ---------------------------------------------------------
  localparam integer SYSTEM_CLK_FREQ = 100_000_000 / CLOCK_DIVIDE;

  // ---------------------------------------------------------
  //  Reloj interno y estado del clock manager.
  // ---------------------------------------------------------
  wire clk_sys;
  wire clk_locked;
  wire clock_stopped;

  // ========================================================================
  //  Clock Manager
  // ------------------------------------------------------------------------
  //  La entrada fisica sigue siendo 100 MHz. El DCM/bypass genera clk_sys.
  // ========================================================================

  clock_manager #(
      .CLK_DIVIDE(CLOCK_DIVIDE)
  ) clock_manager_inst (
      .clk_i          (clk_i),
      .rst_i          (rst_i),
      .clock_stopped_o(clock_stopped),
      .clk_o          (clk_sys),
      .locked_o       (clk_locked)
  );

  // ---------------------------------------------------------
  //  Solicitud asincrona de reset global.
  // ---------------------------------------------------------
  wire reset_request;

  // ---------------------------------------------------------
  //  Sincronizador de liberacion del reset.
  // ---------------------------------------------------------
  (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync = 2'b11;

  // ---------------------------------------------------------
  //  Reset sincronizado para todos los bloques del SoC.
  // ---------------------------------------------------------
  wire rst_sys;

  // ---------------------------------------------------------
  //  El sistema permanece en reset sin lock o con CLK_FREQ invalido.
  // ---------------------------------------------------------
  assign reset_request = rst_i || !clk_locked || !CLK_CONFIG_VALID;
  assign rst_sys       = reset_sync[1];

  // ========================================================================
  //  Reset synchronizer
  // ------------------------------------------------------------------------
  //  La asercion es inmediata. La liberacion requiere dos flancos de clk_sys.
  //  CORE_RESET del debugger es independiente y solo reinicia cpu_core.
  // ========================================================================

  always @(posedge clk_sys or posedge reset_request) begin
    if (reset_request) reset_sync <= 2'b11;
    else reset_sync <= {reset_sync[0], 1'b0};
  end

  // ---------------------------------------------------------
  //  Buses empaquetados de los cuatro Wishbone masters.
  // ---------------------------------------------------------
  wire [127:0] m_adr;
  wire [127:0] m_wdata;
  wire [127:0] m_rdata;
  wire [ 15:0] m_sel;
  wire [  3:0] m_we;
  wire [  3:0] m_cyc;
  wire [  3:0] m_stb;
  wire [  3:0] m_ack;
  wire [  3:0] m_err;
  wire [  3:0] m_timeout;

  // ---------------------------------------------------------
  //  Buses empaquetados de los cuatro Wishbone slaves.
  // ---------------------------------------------------------
  wire [127:0] s_adr;
  wire [127:0] s_wdata;
  wire [127:0] s_rdata;
  wire [ 15:0] s_sel;
  wire [  3:0] s_we;
  wire [  3:0] s_cyc;
  wire [  3:0] s_stb;
  wire [  3:0] s_ack;
  wire [  3:0] s_err;

  // ========================================================================
  //  UART0 Wishbone Master - M0
  // ------------------------------------------------------------------------
  //  RX_I/TX_O son los pines serie fisicos. La RX FIFO y el parser de tramas
  //  viven dentro de uart0_wbm. Cada trama valida produce un Classic SINGLE.
  // ========================================================================

  uart0_wbm #(
      .CLK_FREQ         (SYSTEM_CLK_FREQ),
      .BAUD_RATE        (BAUD_RATE),
      .OVERSAMPLE       (OVERSAMPLE),
      .FIFO_ADDR_WIDTH  (UART_FIFO_ADDR_WIDTH),
      .RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)
  ) uart0_inst (
      .CLK_I    (clk_sys),
      .RST_I    (rst_sys),
      .RX_I     (rx_i),
      .TX_O     (tx_o),
      .ADR_O    (m_adr[31:0]),
      .DAT_O    (m_wdata[31:0]),
      .SEL_O    (m_sel[3:0]),
      .WE_O     (m_we[0]),
      .CYC_O    (m_cyc[0]),
      .STB_O    (m_stb[0]),
      .DAT_I    (m_rdata[31:0]),
      .ACK_I    (m_ack[0]),
      .ERR_I    (m_err[0]),
      .TIMEOUT_I(m_timeout[0])
  );

  // ========================================================================
  //  Wishbone Masters reservados - M2 y M3
  // ------------------------------------------------------------------------
  //  El crossbar ya dispone de cuatro entradas para la futura CPU multiciclo.
  //  Mientras el core actual conserve puertos locales IMEM/DMEM, M2 y M3
  //  permanecen inactivos y no solicitan ningun recurso.
  // ========================================================================

  assign m_adr[127:64]   = 64'd0;
  assign m_wdata[127:64] = 64'd0;
  assign m_sel[15:8]     = 8'd0;
  assign m_we[3:2]       = 2'b00;
  assign m_cyc[3:2]      = 2'b00;
  assign m_stb[3:2]      = 2'b00;

  // ========================================================================
  //  Wishbone Crossbar
  // ------------------------------------------------------------------------
  //  M0 = UART0, M1 = loader. M2/M3 quedan reservados para el futuro core
  //  multiciclo. S0 = IMEM, S1 = DMEM, S2 = loader, S3 = debug.
  //  CH0 y CH1 son recursos dinamicos: cada uno registra Master y Slave.
  //  El crossbar aplica un timeout fijo de 1024 ciclos por Master.
  // ========================================================================

  wb_crossbar crossbar_inst (
      .CLK_I      (clk_sys),
      .RST_I      (rst_sys),
      .M_ADR_I    (m_adr),
      .M_DAT_I    (m_wdata),
      .M_SEL_I    (m_sel),
      .M_WE_I     (m_we),
      .M_CYC_I    (m_cyc),
      .M_STB_I    (m_stb),
      .M_DAT_O    (m_rdata),
      .M_ACK_O    (m_ack),
      .M_ERR_O    (m_err),
      .M_TIMEOUT_O(m_timeout),
      .S_ADR_O    (s_adr),
      .S_DAT_O    (s_wdata),
      .S_SEL_O    (s_sel),
      .S_WE_O     (s_we),
      .S_CYC_O    (s_cyc),
      .S_STB_O    (s_stb),
      .S_DAT_I    (s_rdata),
      .S_ACK_I    (s_ack),
      .S_ERR_I    (s_err)
  );

  // ---------------------------------------------------------
  //  Estado de ejecucion administrado por el debugger.
  // ---------------------------------------------------------
  wire        cpu_en;
  wire        cpu_rst;
  wire        cpu_halted;

  // ---------------------------------------------------------
  //  Estado del program loader.
  // ---------------------------------------------------------
  wire        loader_busy;
  wire        loader_start_pending;

  // ---------------------------------------------------------
  //  Deteccion de solicitudes externas a IMEM/DMEM.
  // ---------------------------------------------------------
  wire        external_memory_request;

  // ---------------------------------------------------------
  //  Interlock global de operaciones de mantenimiento.
  // ---------------------------------------------------------
  wire        maintenance_busy;

  // ---------------------------------------------------------
  //  Interfaz local CPU <-> IMEM.
  // ---------------------------------------------------------
  wire [31:0] imem_addr;
  wire [31:0] imem_rdata;

  // ---------------------------------------------------------
  //  Interfaz local CPU <-> DMEM.
  // ---------------------------------------------------------
  wire [31:0] dmem_addr;
  wire [31:0] dmem_wdata;
  wire [31:0] dmem_rdata;
  wire        dmem_we;
  wire [ 3:0] dmem_byte_enable;

  // ---------------------------------------------------------
  //  Observacion del register file y datapath.
  // ---------------------------------------------------------
  wire [ 4:0] reg_index;
  wire [31:0] reg_data;
  wire [31:0] cpu_pc;
  wire [31:0] cpu_instr;
  wire [31:0] cpu_wb_data;

  // ---------------------------------------------------------
  //  Fallos actuales de la LSU.
  // ---------------------------------------------------------
  wire        mem_misaligned;
  wire        mem_invalid;

  // ---------------------------------------------------------
  //  Una request de los Masters de mantenimiento actuales hacia memoria
  //  externa bloquea RUN/STEP/CORE_RESET.
  // ---------------------------------------------------------
  assign external_memory_request =
        (m_cyc[0] && m_stb[0] && (m_adr[31:17]  == 15'd0)) ||
        (m_cyc[1] && m_stb[1] && (m_adr[63:49]  == 15'd0));

  // ---------------------------------------------------------
  //  RUN/STEP/CORE_RESET quedan bloqueados mientras existe mantenimiento.
  // ---------------------------------------------------------
  assign maintenance_busy = loader_busy || loader_start_pending || external_memory_request;

  // ========================================================================
  //  Program Loader Wishbone - S2 + M1
  // ------------------------------------------------------------------------
  //  S2 expone registros de configuracion al host. Al aceptar START, el mismo
  //  modulo se convierte en M1 y realiza una transaccion hacia IMEM o DMEM.
  // ========================================================================

  program_loader_wb loader_inst (
      .CLK_I          (clk_sys),
      .RST_I          (rst_sys),
      .CPU_HALTED_I   (cpu_halted),
      .BUSY_O         (loader_busy),
      .START_PENDING_O(loader_start_pending),
      .S_ADR_I        (s_adr[95:64]),
      .S_DAT_I        (s_wdata[95:64]),
      .S_SEL_I        (s_sel[11:8]),
      .S_WE_I         (s_we[2]),
      .S_CYC_I        (s_cyc[2]),
      .S_STB_I        (s_stb[2]),
      .S_DAT_O        (s_rdata[95:64]),
      .S_ACK_O        (s_ack[2]),
      .S_ERR_O        (s_err[2]),
      .M_ADR_O        (m_adr[63:32]),
      .M_DAT_O        (m_wdata[63:32]),
      .M_SEL_O        (m_sel[7:4]),
      .M_WE_O         (m_we[1]),
      .M_CYC_O        (m_cyc[1]),
      .M_STB_O        (m_stb[1]),
      .M_DAT_I        (m_rdata[63:32]),
      .M_ACK_I        (m_ack[1]),
      .M_ERR_I        (m_err[1]),
      .M_TIMEOUT_I    (m_timeout[1])
  );

  // ========================================================================
  //  Debug Controller Wishbone Slave - S3
  // ------------------------------------------------------------------------
  //  Convierte register accesses WB en RUN/HALT/STEP/CORE_RESET y expone
  //  PC, instruction, write-back, register file y LAST_* al host.
  // ========================================================================

  debug_controller_wbs #(
      .IMEM_WORD_ADDR_WIDTH(IMEM_WORD_ADDR_WIDTH),
      .DMEM_WORD_ADDR_WIDTH(DMEM_WORD_ADDR_WIDTH)
  ) debugger_inst (
      .CLK_I               (clk_sys),
      .RST_I               (rst_sys),
      .ADR_I               (s_adr[127:96]),
      .DAT_I               (s_wdata[127:96]),
      .SEL_I               (s_sel[15:12]),
      .WE_I                (s_we[3]),
      .CYC_I               (s_cyc[3]),
      .STB_I               (s_stb[3]),
      .DAT_O               (s_rdata[127:96]),
      .ACK_O               (s_ack[3]),
      .ERR_O               (s_err[3]),
      .MAINTENANCE_BUSY_I  (maintenance_busy),
      .CPU_EN_O            (cpu_en),
      .CPU_RST_O           (cpu_rst),
      .CPU_RUNNING_O       (),
      .CPU_HALTED_O        (cpu_halted),
      .CPU_PC_I            (cpu_pc),
      .CPU_INSTR_I         (cpu_instr),
      .CPU_WB_DATA_I       (cpu_wb_data),
      .CPU_DBG_REG_ADDR_O  (reg_index),
      .CPU_DBG_REG_DATA_I  (reg_data),
      .CPU_MEM_MISALIGNED_I(mem_misaligned),
      .CPU_MEM_INVALID_I   (mem_invalid)
  );

  // ========================================================================
  //  RV32I single-cycle core
  // ------------------------------------------------------------------------
  //  El core sigue usando puertos locales hacia memoria; Wishbone queda en la
  //  infraestructura de programacion, control e inspeccion externa.
  // ========================================================================

  cpu_core core_inst (
      .clk_i               (clk_sys),
      .rst_i               (cpu_rst),
      .cpu_en_i            (cpu_en),
      .imem_addr_o         (imem_addr),
      .imem_rdata_i        (imem_rdata),
      .dmem_addr_o         (dmem_addr),
      .dmem_wdata_o        (dmem_wdata),
      .dmem_we_o           (dmem_we),
      .dmem_byte_enable_o  (dmem_byte_enable),
      .dmem_rdata_i        (dmem_rdata),
      .dbg_reg_addr_i      (reg_index),
      .dbg_reg_data_o      (reg_data),
      .dbg_pc_o            (cpu_pc),
      .dbg_instr_o         (cpu_instr),
      .dbg_wb_data_o       (cpu_wb_data),
      .dbg_mem_misaligned_o(mem_misaligned),
      .dbg_mem_invalid_o   (mem_invalid),
      .dbg_mem_load_o      (),
      .dbg_mem_store_o     (),
      .dbg_mem_addr_o      ()
  );


  // IMEM: almacenamiento fisico fuera de cpu_core y adaptador Wishbone S0.
  // Los dos puertos comparten los mismos bancos de RAM.
  wire [31:0] imem_wb_addr;
  wire [31:0] imem_wb_wdata;
  wire [31:0] imem_wb_rdata;
  wire [3:0]  imem_wb_sel;
  wire        imem_wb_we;

  instruction_memory #(
      .WORD_ADDR_WIDTH(IMEM_WORD_ADDR_WIDTH)
  ) imem_inst (
      .clk_i(clk_sys),
      .cpu_addr_i (imem_addr),
      .cpu_rdata_o(imem_rdata),
      .wb_addr_i (imem_wb_addr),
      .wb_wdata_i(imem_wb_wdata),
      .wb_sel_i  (imem_wb_sel),
      .wb_we_i   (imem_wb_we),
      .wb_rdata_o(imem_wb_rdata)
  );

  instruction_memory_wbs #(
      .WORD_ADDR_WIDTH(IMEM_WORD_ADDR_WIDTH),
      .WAIT_CYCLES(MEMORY_WAIT_CYCLES)
  ) imem_wbs_inst (
      .CLK_I       (clk_sys),
      .RST_I       (rst_sys),
      .ACCESS_OK_I (cpu_halted),
      .ADR_I       (s_adr[31:0]),
      .DAT_I       (s_wdata[31:0]),
      .SEL_I       (s_sel[3:0]),
      .WE_I        (s_we[0]),
      .CYC_I       (s_cyc[0]),
      .STB_I       (s_stb[0]),
      .DAT_O       (s_rdata[31:0]),
      .ACK_O       (s_ack[0]),
      .ERR_O       (s_err[0]),
      .MEM_ADDR_O  (imem_wb_addr),
      .MEM_WDATA_O (imem_wb_wdata),
      .MEM_SEL_O   (imem_wb_sel),
      .MEM_WE_O    (imem_wb_we),
      .MEM_RDATA_I (imem_wb_rdata)
  );

  // DMEM: almacenamiento fisico fuera de cpu_core y adaptador Wishbone S1.
  // Los dos puertos comparten los mismos bancos de RAM.
  wire [31:0] dmem_wb_addr;
  wire [31:0] dmem_wb_wdata;
  wire [31:0] dmem_wb_rdata;
  wire [3:0]  dmem_wb_sel;
  wire        dmem_wb_we;

  data_memory #(
      .WORD_ADDR_WIDTH(DMEM_WORD_ADDR_WIDTH)
  ) dmem_inst (
      .clk_i(clk_sys),
      .cpu_addr_i        (dmem_addr),
      .cpu_wdata_i       (dmem_wdata),
      .cpu_we_i          (dmem_we),
      .cpu_byte_enable_i (dmem_byte_enable),
      .cpu_rdata_o       (dmem_rdata),
      .wb_addr_i (dmem_wb_addr),
      .wb_wdata_i(dmem_wb_wdata),
      .wb_sel_i  (dmem_wb_sel),
      .wb_we_i   (dmem_wb_we),
      .wb_rdata_o(dmem_wb_rdata)
  );

  data_memory_wbs #(
      .WORD_ADDR_WIDTH(DMEM_WORD_ADDR_WIDTH),
      .WAIT_CYCLES(MEMORY_WAIT_CYCLES)
  ) dmem_wbs_inst (
      .CLK_I       (clk_sys),
      .RST_I       (rst_sys),
      .ACCESS_OK_I (cpu_halted),
      .ADR_I       (s_adr[63:32]),
      .DAT_I       (s_wdata[63:32]),
      .SEL_I       (s_sel[7:4]),
      .WE_I        (s_we[1]),
      .CYC_I       (s_cyc[1]),
      .STB_I       (s_stb[1]),
      .DAT_O       (s_rdata[63:32]),
      .ACK_O       (s_ack[1]),
      .ERR_O       (s_err[1]),
      .MEM_ADDR_O  (dmem_wb_addr),
      .MEM_WDATA_O (dmem_wb_wdata),
      .MEM_SEL_O   (dmem_wb_sel),
      .MEM_WE_O    (dmem_wb_we),
      .MEM_RDATA_I (dmem_wb_rdata)
  );

  // ========================================================================
  //  RV32 display
  // ------------------------------------------------------------------------
  //  Muestra "rv32" y usa el decimal point como indicacion del estado DCM.
  // ========================================================================

  rv32_display #(
      .CLK_FREQ(SYSTEM_CLK_FREQ),
      .SCAN_HZ (1000)
  ) display_inst (
      .clk_i      (clk_sys),
      .rst_i      (rst_sys),
      .dcm_error_i(clock_stopped),
      .seg_o      (seg_o),
      .an_o       (an_o),
      .dp_o       (dp_o)
  );

endmodule
