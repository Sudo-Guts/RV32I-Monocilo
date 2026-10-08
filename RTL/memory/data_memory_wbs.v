`timescale 1ns / 1ps
`default_nettype none

/*
 * data_memory_wbs: adaptador Wishbone Classic SINGLE de S1.
 * NO contiene memoria fisica. cpu_soc instancia la RAM por separado.
 * Valida accesos, permisos, timeout local de espera y ACK/ERR.
 * MEM_ADDR_O es una direccion local en bytes; MEM_WE_O es un pulso
 * que escribe la RAM fisica al flanco que confirma ACK.
 * Autor del proyecto: Gustavo Ruiz Luis
 */
module data_memory_wbs #(
    parameter integer WORD_ADDR_WIDTH = 8,
    parameter integer WAIT_CYCLES = 0
) (
    input wire CLK_I,
    input wire RST_I,
    input wire ACCESS_OK_I,

    // Wishbone Slave.
    input  wire [31:0] ADR_I,
    input  wire [31:0] DAT_I,
    input  wire [3:0]  SEL_I,
    input  wire        WE_I,
    input  wire        CYC_I,
    input  wire        STB_I,
    output wire [31:0] DAT_O,
    output wire        ACK_O,
    output wire        ERR_O,

    // Puerto hacia RAM fisica (no es Wishbone).
    output wire [31:0] MEM_ADDR_O,
    output wire [31:0] MEM_WDATA_O,
    output wire [3:0]  MEM_SEL_O,
    output wire        MEM_WE_O,
    input  wire [31:0] MEM_RDATA_I
);

    localparam [31:0] BASE_ADDR = 32'h0001_0000;
    localparam [31:0] BYTES = (32'd4 << WORD_ADDR_WIDTH);

    wire [31:0] offset = ADR_I - BASE_ADDR;

    wire wb_valid = (ADR_I >= BASE_ADDR) &&
                    (offset < BYTES) &&
                    (ADR_I[1:0] == 2'b00) &&
                    (SEL_I != 4'b0000);

    reg served;
    reg [31:0] wait_count;

    wire request = CYC_I && STB_I && !served && !RST_I;

    assign ERR_O = request && (!wb_valid || !ACCESS_OK_I);
    assign ACK_O = request && wb_valid && ACCESS_OK_I &&
                   (wait_count >= WAIT_CYCLES);

    assign MEM_ADDR_O  = offset;
    assign MEM_WDATA_O = DAT_I;
    assign MEM_SEL_O   = SEL_I;
    assign MEM_WE_O    = ACK_O && WE_I;
    assign DAT_O       = MEM_RDATA_I;

    always @(posedge CLK_I) begin
        if (RST_I) begin
            served <= 1'b0;
            wait_count <= 32'd0;
        end else if (!CYC_I || !STB_I) begin
            served <= 1'b0;
            wait_count <= 32'd0;
        end else if (!served) begin
            if (ACK_O || ERR_O)
                served <= 1'b1;
            else
                wait_count <= wait_count + 1'b1;
        end
    end
endmodule
`default_nettype wire
