`timescale 1ns / 1ps

/*
 * ========================================================================
 *  Instruction Memory Wishbone Slave - S0
 * ------------------------------------------------------------------------
 *  Top Wishbone slave que expone la IMEM al crossbar y, al mismo tiempo,
 *  mantiene un puerto local de lectura combinacional para cpu_core.
 *
 *  Mapa externo por defecto:
 *      Ventana crossbar : 0x00000000 .. 0x0000FFFF
 *      Capacidad real   : 4 * 2**WORD_ADDR_WIDTH bytes
 *      Default          : 512 palabras = 2048 bytes
 *
 *  El core usa CPU_ADDR_I con base local cero. Wishbone usa ADR_I absoluto.
 *  Las instrucciones se programan exclusivamente por Wishbone; el puerto
 *  local del core no puede escribir. ACCESS_OK_I permite acceso externo solo
 *  cuando el SoC ha detenido la CPU.
 *
 *  Una lectura local fuera de rango devuelve 0x00000013, equivalente a
 *  ADDI x0, x0, 0. No es I-Cache; no hay tags, refill ni replacement policy.
 *
 *  Al ser un top Wishbone slave, todos sus puertos usan mayusculas.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module instruction_memory_wbs #(

    // ---------------------------------------------------------
    //  Log2 del numero de palabras implementadas.
    // ---------------------------------------------------------
    parameter integer WORD_ADDR_WIDTH = 9,

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
    //  Puerto local de lectura para cpu_core.
    // ---------------------------------------------------------
    input  wire [31:0] CPU_ADDR_I,
    output wire [31:0] CPU_RDATA_O,

    // ---------------------------------------------------------
    //  Autorizacion de mantenimiento externo.
    // ---------------------------------------------------------
    input wire ACCESS_OK_I,

    // ---------------------------------------------------------
    //  Wishbone Slave S0.
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
    //  wb_memory es un bloque interno. Su puerto CPU se configura read-only y
    //  su puerto bus recibe directamente el Classic SINGLE del slave S0.
    // ========================================================================

    wb_memory #(
        .WORD_ADDR_WIDTH (WORD_ADDR_WIDTH),
        .BASE_ADDR       (32'h00000000),
        .CPU_INVALID_DATA(32'h00000013),
        .WAIT_CYCLES     (WAIT_CYCLES)
    ) ram_inst (
        .clk_i      (CLK_I),
        .rst_i      (RST_I),
        .cpu_addr_i (CPU_ADDR_I),
        .cpu_wdata_i(32'd0),
        .cpu_we_i   (1'b0),
        .cpu_sel_i  (4'b0000),
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
