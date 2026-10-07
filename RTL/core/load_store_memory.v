`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monocilo
 *  Modulo   : load_store_memory
 *  Archivo  : load_store_memory.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Interfaz de la etapa MEMORY entre el datapath del procesador y
 *      Data Memory.
 *
 *      Este modulo encapsula la Load / Store Unit y concentra la logica
 *      asociada al acceso de memoria:
 *
 *          - formateo de LOAD y STORE.
 *          - alineamiento de datos.
 *          - generacion de byte enables.
 *          - deteccion de accesos invalidos o desalineados.
 *          - generacion de write enable hacia Data Memory.
 *          - bloqueo de efectos laterales cuando existe un fault.
 *
 *      La direccion efectiva completa se recibe mediante addr_i.
 *      Sus bits addr_i[1:0] se utilizan para seleccionar el byte lane
 *      correspondiente dentro de la palabra de 32 bits.
 *
 *      La interfaz de memoria conserva la direccion efectiva completa:
 *
 *          dmem_addr_o = addr_i
 *
 *      Mientras no exista manejo de traps, un fault impide la escritura
 *      sobre Data Memory y produce un dato de LOAD seguro.
 *
 *      load_i y store_i son mutuamente excluyentes durante una operacion
 *      normal. La LSU detecta como invalida cualquier activacion simultanea.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module load_store_memory (

    // ------------------------------------------------------------------------
    // Control de ejecucion
    // ------------------------------------------------------------------------

    input  wire        cpu_en_i,

    // ------------------------------------------------------------------------
    // Informacion de la operacion de memoria
    // ------------------------------------------------------------------------

    input  wire [2:0]  funct3_i,
    input  wire [31:0] addr_i,

    input  wire        load_i,
    input  wire        store_i,

    // ------------------------------------------------------------------------
    // Datos del datapath
    // ------------------------------------------------------------------------

    input  wire [31:0] store_data_i,
    output wire [31:0] load_data_o,

    // ------------------------------------------------------------------------
    // Data Memory
    // ------------------------------------------------------------------------

    input  wire [31:0] dmem_rdata_i,

    output wire [31:0] dmem_addr_o,
    output wire [31:0] dmem_wdata_o,
    output wire        dmem_we_o,
    output wire [3:0]  dmem_byte_enable_o,

    // ------------------------------------------------------------------------
    // Informacion de fault
    // ------------------------------------------------------------------------

    output wire        misaligned_o,
    output wire        invalid_access_o,
    output wire        mem_access_fault_o

);

/*
 * ============================================================================
 *  LOAD / STORE UNIT
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Senales internas de formateo y validacion
// ----------------------------------------------------------------------------

wire [31:0] wdata_aligned;
wire [31:0] rdata_aligned;

wire [3:0]  byte_enable;

wire        lsu_misaligned;
wire        lsu_invalid_access;


// ----------------------------------------------------------------------------
// Formateo de datos y validacion del acceso
// ----------------------------------------------------------------------------

load_store_unit u_lsu (
    .funct3_i          (funct3_i),
    .addr_low_i        (addr_i[1:0]),

    .load_i            (load_i),
    .store_i           (store_i),

    .wdata_i           (store_data_i),
    .rdata_i           (dmem_rdata_i),

    .wdata_aligned_o   (wdata_aligned),
    .rdata_aligned_o   (rdata_aligned),

    .wdata_strobe_o    (byte_enable),

    .misaligned_o      (lsu_misaligned),
    .invalid_access_o  (lsu_invalid_access)
);

/*
 * ============================================================================
 *  MEMORY INTERFACE
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Fault aggregation
// ----------------------------------------------------------------------------

// Un fault solo tiene efecto durante una operacion LOAD o STORE activa.
assign mem_access_fault_o = (load_i || store_i) && (lsu_misaligned || lsu_invalid_access);

assign misaligned_o     = lsu_misaligned;
assign invalid_access_o = lsu_invalid_access;

// ----------------------------------------------------------------------------
// Data path hacia y desde memoria
// ----------------------------------------------------------------------------

// La direccion efectiva se conserva completa hacia Data Memory.
assign dmem_addr_o = addr_i;

// La LSU coloca el dato de STORE en los byte lanes correspondientes.
assign dmem_wdata_o = wdata_aligned;

// El dato de LOAD ya sale alineado y extendido a 32 bits.
assign load_data_o = rdata_aligned;


// ----------------------------------------------------------------------------
// Control de escritura de Data Memory
// ----------------------------------------------------------------------------

// Data Memory solo puede modificarse durante un STORE valido y mientras
// la ejecucion de la CPU se encuentre habilitada.
assign dmem_we_o = cpu_en_i & store_i & ~mem_access_fault_o;

// Los byte enables solo son validos durante una escritura aceptada.
assign dmem_byte_enable_o = (cpu_en_i && store_i && !mem_access_fault_o) ? byte_enable : 4'b0000;

endmodule
