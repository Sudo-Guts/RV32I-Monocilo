`timescale 1ns / 1ps

/*
 * ========================================================================
 *  Data Memory Wishbone Slave - S1
 * ------------------------------------------------------------------------
 *  Top Wishbone slave que expone la DMEM al crossbar y mantiene un puerto
 *  local de lectura/escritura para la LSU del cpu_core monociclo.
 *
 *  Mapa externo por defecto:
 *      Ventana crossbar : 0x00010000 .. 0x0001FFFF
 *      Capacidad real   : 4 * 2**WORD_ADDR_WIDTH bytes
 *      Default          : 256 palabras = 1024 bytes
 *
 *  El puerto local usa direcciones de byte con base cero. Wishbone usa
 *  direcciones absolutas. CPU_BYTE_ENABLE_I permite SB/SH/SW por byte lane.
 *  ACCESS_OK_I permite acceso externo solamente con la CPU detenida.
 *
 *  No es D-Cache y no implementa coherencia. El reset conserva el contenido
 *  de RAM y solo reinicia el control de transaction dentro de wb_memory.
 *
 *  Al ser un top Wishbone slave, todos sus puertos usan mayusculas.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module data_memory_wbs #(

    // ---------------------------------------------------------
    //  Log2 del numero de palabras implementadas.
    // ---------------------------------------------------------
    parameter integer WORD_ADDR_WIDTH = 8,

    // ---------------------------------------------------------
    //  Wait states adicionales del acceso Wishbone.
    // ---------------------------------------------------------
    parameter integer WAIT_CYCLES = 0

) (

    // ---------------------------------------------------------
    //  Reloj y reset.
    // ---------------------------------------------------------
    input wire CLK_I,
    input wire RST_I,

    // ---------------------------------------------------------
    //  Puerto local para la LSU del cpu_core.
    // ---------------------------------------------------------
    input  wire [31:0] CPU_ADDR_I,
    input  wire [31:0] CPU_WDATA_I,
    input  wire        CPU_WE_I,
    input  wire [3:0]  CPU_BYTE_ENABLE_I,
    output wire [31:0] CPU_RDATA_O,

    // ---------------------------------------------------------
    //  Autorizacion de mantenimiento externo.
    // ---------------------------------------------------------
    input wire ACCESS_OK_I,

    // ---------------------------------------------------------
    //  Wishbone Slave S1.
    // ---------------------------------------------------------
    input  wire [31:0] ADR_I,
    input  wire [31:0] DAT_I,
    input  wire [3:0]  SEL_I,
    input  wire        WE_I,
    input  wire        CYC_I,
    input  wire        STB_I,
    output wire [31:0] DAT_O,
    output wire        ACK_O,
    output wire        ERR_O

);

    // ========================================================================
    //  Shared RAM instance
    // ------------------------------------------------------------------------
    //  El puerto local recibe los LOAD/STORE del core. El puerto bus atiende
    //  programacion e inspeccion externa mientras ACCESS_OK_I permanece alto.
    // ========================================================================

    wb_memory #(
        .WORD_ADDR_WIDTH (WORD_ADDR_WIDTH),
        .BASE_ADDR       (32'h00010000),
        .CPU_INVALID_DATA(32'h00000000),
        .WAIT_CYCLES     (WAIT_CYCLES)
    ) ram_inst (
        .clk_i      (CLK_I),
        .rst_i      (RST_I),
        .cpu_addr_i (CPU_ADDR_I),
        .cpu_wdata_i(CPU_WDATA_I),
        .cpu_we_i   (CPU_WE_I),
        .cpu_sel_i  (CPU_BYTE_ENABLE_I),
        .cpu_rdata_o(CPU_RDATA_O),
        .access_ok_i(ACCESS_OK_I),
        .adr_i      (ADR_I),
        .dat_i      (DAT_I),
        .sel_i      (SEL_I),
        .we_i       (WE_I),
        .cyc_i      (CYC_I),
        .stb_i      (STB_I),
        .dat_o      (DAT_O),
        .ack_o      (ACK_O),
        .err_o      (ERR_O)
    );

endmodule
