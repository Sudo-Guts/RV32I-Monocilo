`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monociclo
 *  Modulo   : register_file
 *  Archivo  : register_file.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Banco de 32 registros enteros de 32 bits para la arquitectura RV32I.
 *
 *      El modulo implementa:
 *
 *          - 2 puertos de lectura asincrona para el datapath.
 *          - 1 puerto de escritura sincrona para Writeback.
 *          - 1 puerto adicional de lectura asincrona para debug.
 *
 *      El registro x0 conserva el comportamiento arquitectonico definido
 *      por RISC-V:
 *
 *          - toda lectura de x0 entrega 32'd0.
 *          - cualquier intento de escritura sobre x0 se ignora.
 *
 *      La escritura ocurre en el flanco ascendente de clk_i cuando:
 *
 *          cpu_en_i = 1
 *          we_i     = 1
 *          waddr_i != 0
 *
 *      Las lecturas son combinacionales, por lo que los valores de rs1 y rs2
 *      se encuentran disponibles durante el mismo ciclo de ejecucion de la
 *      instruccion actual.
 *
 *      El banco no se inicializa ni se borra mediante reset. Esta decision
 *      conserva el comportamiento actual del proyecto.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module register_file (

    // ------------------------------------------------------------------------
    // Clock y control de escritura
    // ------------------------------------------------------------------------

    input  wire        clk_i,
    input  wire        cpu_en_i,
    input  wire        we_i,

    // ------------------------------------------------------------------------
    // Puertos del datapath
    // ------------------------------------------------------------------------

    input  wire [4:0]  raddr1_i,
    input  wire [4:0]  raddr2_i,

    input  wire [4:0]  waddr_i,
    input  wire [31:0] wdata_i,

    output wire [31:0] rdata1_o,
    output wire [31:0] rdata2_o,

    // ------------------------------------------------------------------------
    // Puerto de lectura para debug
    // ------------------------------------------------------------------------

    input  wire [4:0]  dbg_raddr_i,
    output wire [31:0] dbg_rdata_o
    
);

/*
 * ============================================================================
 *  REGISTER STORAGE
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Arreglo de registros
// ----------------------------------------------------------------------------

// Se reservan 32 palabras de 32 bits.
reg [31:0] registers [0:31];


/*
 * ============================================================================
 *  ASYNCHRONOUS READ
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Puertos de lectura
// ----------------------------------------------------------------------------

// Las lecturas son combinacionales.
assign rdata1_o    = (raddr1_i    == 5'd0) ? 32'd0 : registers[raddr1_i];
assign rdata2_o    = (raddr2_i    == 5'd0) ? 32'd0 : registers[raddr2_i];
assign dbg_rdata_o = (dbg_raddr_i == 5'd0) ? 32'd0 : registers[dbg_raddr_i];

/*
 * ============================================================================
 *  SYNCHRONOUS WRITE
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Escritura del Register File
// ----------------------------------------------------------------------------

// Solo una instruccion que habilita Writeback puede modificar el banco.
always @(posedge clk_i) begin
    if (cpu_en_i && we_i && (waddr_i != 5'd0))
        registers[waddr_i] <= wdata_i;
end

endmodule