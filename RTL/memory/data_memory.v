`timescale 1ns / 1ps
`default_nettype none

/*
 * data_memory - RAM fisica compartida, externa a CPU y Wishbone.
 * Dos puertos de lectura asincrona: CPU y mantenimiento.
 * Un puerto efectivo de escritura sincrona a los mismos cuatro bancos.
 * Direcciones locales en bytes; el adaptador maneja la direccion absoluta.
 * No se borra la memoria al aplicar reset.
 * Autor del proyecto: Gustavo Ruiz Luis
 */
module data_memory #(
    parameter integer WORD_ADDR_WIDTH = 8
) (
    input wire clk_i,

    // Puerto local de CPU.
    input wire [31:0] cpu_addr_i,
    input wire [31:0] cpu_wdata_i,
    input wire        cpu_we_i,
    input wire [3:0]  cpu_byte_enable_i,
    output wire [31:0] cpu_rdata_o,

    // Puerto local desde data_memory_wbs.
    input wire [31:0] wb_addr_i,
    input wire [31:0] wb_wdata_i,
    input wire [3:0]  wb_sel_i,
    input wire        wb_we_i,
    output wire [31:0] wb_rdata_o
);

    localparam integer WORDS = (1 << WORD_ADDR_WIDTH);
    localparam [31:0] BYTES = (32'd4 << WORD_ADDR_WIDTH);

    (* ram_style = "distributed" *) reg [7:0] mem_b0 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] mem_b1 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] mem_b2 [0:WORDS-1];
    (* ram_style = "distributed" *) reg [7:0] mem_b3 [0:WORDS-1];

    wire cpu_valid = cpu_addr_i < BYTES;
    wire wb_valid  = wb_addr_i < BYTES;

    wire [WORD_ADDR_WIDTH-1:0] cpu_word_addr =
        cpu_addr_i[WORD_ADDR_WIDTH+1:2];
    wire [WORD_ADDR_WIDTH-1:0] wb_word_addr =
        wb_addr_i[WORD_ADDR_WIDTH+1:2];

    assign cpu_rdata_o = cpu_valid ? {
        mem_b3[cpu_word_addr], mem_b2[cpu_word_addr],
        mem_b1[cpu_word_addr], mem_b0[cpu_word_addr]
    } : 32'h0000_0000;

    assign wb_rdata_o = wb_valid ? {
        mem_b3[wb_word_addr], mem_b2[wb_word_addr],
        mem_b1[wb_word_addr], mem_b0[wb_word_addr]
    } : 32'd0;

    // Las escrituras CPU y WB son excluyentes durante mantenimiento.
    // Prioridad CPU como proteccion ante peticiones simultaneas.
    wire cpu_write = cpu_we_i && cpu_valid;
    wire ram_write = cpu_write || (wb_we_i && wb_valid && (|wb_sel_i));
    wire [WORD_ADDR_WIDTH-1:0] write_addr = cpu_write ? cpu_word_addr : wb_word_addr;
    wire [31:0] write_data = cpu_write ? cpu_wdata_i : wb_wdata_i;
    wire [3:0] write_sel = cpu_write ? cpu_byte_enable_i : wb_sel_i;

    always @(posedge clk_i) begin
        if (ram_write) begin
            if (write_sel[0]) mem_b0[write_addr] <= write_data[7:0];
            if (write_sel[1]) mem_b1[write_addr] <= write_data[15:8];
            if (write_sel[2]) mem_b2[write_addr] <= write_data[23:16];
            if (write_sel[3]) mem_b3[write_addr] <= write_data[31:24];
        end
    end

endmodule
`default_nettype wire
