`timescale 1ns / 1ps

/*
 * ========================================================================
 *  Wishbone Memory - Internal shared RAM primitive
 * ------------------------------------------------------------------------
 *  Memoria de palabras de 32 bits organizada en cuatro bancos de 8 bits.
 *  Tiene un puerto local para CPU y un puerto interno compatible con Wishbone.
 *
 *  Este archivo NO es un top Wishbone del SoC: instruction_memory_wbs y
 *  data_memory_wbs son los slaves visibles por crossbar_wb. Por esa razon,
 *  sus puertos siguen la convencion normal en minusculas con _i / _o.
 *
 *  El puerto CPU usa direcciones locales de byte. El puerto bus usa una
 *  direccion absoluta y resta BASE_ADDR. Las lecturas son asincronas y la
 *  escritura fisica ocurre en el flanco que acepta una operacion.
 *
 *  Perfil implementado: Classic SINGLE, 32-bit data, 8-bit granularity,
 *  little-endian. No hay STALL, RTY ni burst transfers.
 *
 *  access_ok_i es una autorizacion local del SoC, no una senal Wishbone B4.
 *  wait_count permite agregar wait states al puerto bus sin afectar CPU.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module wb_memory #(

    // ---------------------------------------------------------
    //  Capacidad: 2**WORD_ADDR_WIDTH palabras de 32 bits.
    // ---------------------------------------------------------
    parameter integer WORD_ADDR_WIDTH = 8,

    // ---------------------------------------------------------
    //  Base absoluta visible desde Wishbone.
    // ---------------------------------------------------------
    parameter [31:0] BASE_ADDR = 32'h00010000,

    // ---------------------------------------------------------
    //  Valor local fuera de rango.
    // ---------------------------------------------------------
    parameter [31:0] CPU_INVALID_DATA = 32'h00000000,

    // ---------------------------------------------------------
    //  Wait states adicionales del puerto bus.
    // ---------------------------------------------------------
    parameter integer WAIT_CYCLES = 0

) (

    // ---------------------------------------------------------
    //  Reloj y reset.
    // ---------------------------------------------------------
    input wire clk_i,
    input wire rst_i,

    // ---------------------------------------------------------
    //  Puerto local de CPU.
    // ---------------------------------------------------------
    input  wire [31:0] cpu_addr_i,
    input  wire [31:0] cpu_wdata_i,
    input  wire        cpu_we_i,
    input  wire [3:0]  cpu_sel_i,
    output wire [31:0] cpu_rdata_o,

    // ---------------------------------------------------------
    //  Autorizacion del puerto bus.
    // ---------------------------------------------------------
    input wire access_ok_i,

    // ---------------------------------------------------------
    //  Puerto interno compatible con Wishbone slave.
    // ---------------------------------------------------------
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire [3:0]  sel_i,
    input  wire        we_i,
    input  wire        cyc_i,
    input  wire        stb_i,
    output wire [31:0] dat_o,
    output wire        ack_o,
    output wire        err_o

);

    // ---------------------------------------------------------
    //  Numero de palabras y bytes implementados.
    // ---------------------------------------------------------
    localparam integer WORDS = (1 << WORD_ADDR_WIDTH);
    localparam [31:0]  BYTES = WORDS * 4;

    // ---------------------------------------------------------
    //  Bancos de bytes de la RAM distribuida.
    // ---------------------------------------------------------
    (* ram_style="distributed" *) reg [7:0] mem_b0 [0:WORDS-1];
    (* ram_style="distributed" *) reg [7:0] mem_b1 [0:WORDS-1];
    (* ram_style="distributed" *) reg [7:0] mem_b2 [0:WORDS-1];
    (* ram_style="distributed" *) reg [7:0] mem_b3 [0:WORDS-1];

    // ---------------------------------------------------------
    //  Direcciones internas de CPU y bus.
    // ---------------------------------------------------------
    wire [31:0] offset;
    wire [WORD_ADDR_WIDTH-1:0] cpu_word_addr;
    wire [WORD_ADDR_WIDTH-1:0] wb_word_addr;

    // ---------------------------------------------------------
    //  Validacion de rango y formato.
    // ---------------------------------------------------------
    wire cpu_valid;
    wire wb_valid;

    // ---------------------------------------------------------
    //  Calculo de offset y word address.
    // ---------------------------------------------------------
    assign offset        = adr_i - BASE_ADDR;
    assign cpu_word_addr = cpu_addr_i[WORD_ADDR_WIDTH+1:2];
    assign wb_word_addr  = offset[WORD_ADDR_WIDTH+1:2];

    // ---------------------------------------------------------
    //  Validacion de accesos.
    // ---------------------------------------------------------
    assign cpu_valid = (cpu_addr_i < BYTES);
    assign wb_valid  = (adr_i >= BASE_ADDR) &&
                       (offset < BYTES) &&
                       (adr_i[1:0] == 2'b00) &&
                       (sel_i != 4'b0000);

    // ---------------------------------------------------------
    //  Estado del Classic SINGLE pendiente.
    // ---------------------------------------------------------
    reg        served;
    reg [31:0] wait_count;

    // ---------------------------------------------------------
    //  Request efectivo del puerto bus.
    // ---------------------------------------------------------
    wire request;

    // ---------------------------------------------------------
    //  Deteccion de request nuevo.
    // ---------------------------------------------------------
    assign request = cyc_i && stb_i && !served && !rst_i;

    // ---------------------------------------------------------
    //  Terminacion del acceso bus.
    // ---------------------------------------------------------
    assign err_o = request && (!wb_valid || !access_ok_i);
    assign ack_o = request && wb_valid && access_ok_i && (wait_count >= WAIT_CYCLES);

    // ---------------------------------------------------------
    //  Lectura asincrona del puerto bus.
    // ---------------------------------------------------------
    assign dat_o = {
        mem_b3[wb_word_addr],
        mem_b2[wb_word_addr],
        mem_b1[wb_word_addr],
        mem_b0[wb_word_addr]
    };

    // ---------------------------------------------------------
    //  Lectura asincrona del puerto local.
    // ---------------------------------------------------------
    assign cpu_rdata_o = cpu_valid ? {
        mem_b3[cpu_word_addr],
        mem_b2[cpu_word_addr],
        mem_b1[cpu_word_addr],
        mem_b0[cpu_word_addr]
    } : CPU_INVALID_DATA;

    // ---------------------------------------------------------
    //  Seleccion del unico camino de escritura fisica.
    // ---------------------------------------------------------
    wire cpu_write;
    wire write_enable;
    wire [WORD_ADDR_WIDTH-1:0] write_addr;
    wire [31:0] write_data;
    wire [3:0]  write_sel;

    // ---------------------------------------------------------
    //  La CPU conserva prioridad defensiva sobre una escritura WB.
    // ---------------------------------------------------------
    assign cpu_write   = cpu_we_i && cpu_valid;
    assign write_enable = cpu_write || (ack_o && we_i);
    assign write_addr   = cpu_write ? cpu_word_addr : wb_word_addr;
    assign write_data   = cpu_write ? cpu_wdata_i : dat_i;
    assign write_sel    = cpu_write ? cpu_sel_i : sel_i;

    // ========================================================================
    //  Control de transaction y escritura por byte
    // ------------------------------------------------------------------------
    //  served garantiza una sola aceptacion mientras CYC/STB permanezcan altos.
    //  El reset limpia control, no el contenido de RAM.
    // ========================================================================

    always @(posedge clk_i) begin
        if (rst_i) begin
            served     <= 1'b0;
            wait_count <= 32'd0;
        end else begin
            if (!cyc_i || !stb_i) begin
                served     <= 1'b0;
                wait_count <= 32'd0;
            end else if (!served) begin
                if (ack_o || err_o)
                    served <= 1'b1;
                else
                    wait_count <= wait_count + 1'b1;
            end

            if (write_enable) begin
                if (write_sel[0]) mem_b0[write_addr] <= write_data[7:0];
                if (write_sel[1]) mem_b1[write_addr] <= write_data[15:8];
                if (write_sel[2]) mem_b2[write_addr] <= write_data[23:16];
                if (write_sel[3]) mem_b3[write_addr] <= write_data[31:24];
            end
        end
    end

endmodule
