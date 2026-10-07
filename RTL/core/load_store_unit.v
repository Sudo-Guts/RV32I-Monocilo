`timescale 1ns / 1ps

/*
 * ============================================================================
 *  Proyecto : Procesador RV32I - Monocilo
 *  Modulo   : load_store_unit
 *  Archivo  : load_store_unit.v
 * ----------------------------------------------------------------------------
 *  Descripcion:
 *      Load / Store Unit para una interfaz de Data Memory de 32 bits con
 *      habilitacion independiente por byte.
 *
 *      La LSU adapta las operaciones de memoria de RV32I al ancho de palabra
 *      de la memoria y realiza las siguientes funciones:
 *
 *          - seleccion del byte o halfword solicitado por LOAD.
 *          - extension con signo o con ceros del dato leido.
 *          - alineacion del dato de STORE sobre el byte lane correspondiente.
 *          - generacion de write strobe para cada byte lane.
 *          - deteccion de accesos desalineados.
 *          - deteccion de codigos funct3 no soportados.
 *
 *      LOAD soportados:
 *
 *          LB    LH    LW    LBU    LHU
 *
 *      STORE soportados:
 *
 *          SB    SH    SW
 *
 *      Reglas de alineamiento:
 *
 *          Byte      -> cualquier addr_low_i[1:0]
 *          Halfword  -> addr_low_i[0]   = 0
 *          Word      -> addr_low_i[1:0] = 00
 *
 *      La interfaz asume memoria little-endian.
 *
 *      rdata_i debe contener la palabra de 32 bits asociada a la direccion
 *      alineada que contiene el byte o halfword solicitado. addr_low_i
 *      selecciona el byte lane dentro de esa palabra.
 *
 *      Mientras no exista manejo de traps, un acceso invalido o desalineado
 *      produce salidas seguras:
 *
 *          wdata_aligned_o = 32'd0
 *          rdata_aligned_o = 32'd0
 *          wdata_strobe_o  = 4'b0000
 *
 *      cpu_core utiliza misaligned_o e invalid_access_o para impedir efectos
 *      laterales sobre Data Memory y Register File.
 *
 *      load_i y store_i son mutuamente excluyentes durante una operacion
 *      normal. Si ambos se activan simultaneamente, la LSU marca el acceso
 *      como invalido.
 *
 * ----------------------------------------------------------------------------
 *  Autor : Gustavo Ruiz Luis
 * ============================================================================
 */

module load_store_unit (

    // ------------------------------------------------------------------------
    // Control de la instruccion
    // ------------------------------------------------------------------------

    input  wire [2:0]  funct3_i,
    input  wire [1:0]  addr_low_i,

    input  wire        load_i,
    input  wire        store_i,

    // ------------------------------------------------------------------------
    // Data Memory datapath
    // ------------------------------------------------------------------------

    input  wire [31:0] wdata_i,
    input  wire [31:0] rdata_i,

    // ------------------------------------------------------------------------
    // Datos formateados
    // ------------------------------------------------------------------------

    output reg  [31:0] wdata_aligned_o,
    output reg  [31:0] rdata_aligned_o,

    output reg  [3:0]  wdata_strobe_o,

    // ------------------------------------------------------------------------
    // Informacion de fault
    // ------------------------------------------------------------------------

    output reg         misaligned_o,
    output reg         invalid_access_o

);

// ----------------------------------------------------------------------------
// Codigos funct3 para LOAD
// ----------------------------------------------------------------------------

localparam [2:0] F3_LB  = 3'b000;
localparam [2:0] F3_LH  = 3'b001;
localparam [2:0] F3_LW  = 3'b010;
localparam [2:0] F3_LBU = 3'b100;
localparam [2:0] F3_LHU = 3'b101;

// ----------------------------------------------------------------------------
// Codigos funct3 para STORE
// ----------------------------------------------------------------------------

localparam [2:0] F3_SB  = 3'b000;
localparam [2:0] F3_SH  = 3'b001;
localparam [2:0] F3_SW  = 3'b010;

/*
 * ============================================================================
 *  LOAD DATA SELECTION
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Seleccion de byte y halfword
// ----------------------------------------------------------------------------
// La palabra de memoria se interpreta como little-endian:
//
//     addr_low_i = 00 -> rdata_i[7:0]
//     addr_low_i = 01 -> rdata_i[15:8]
//     addr_low_i = 10 -> rdata_i[23:16]
//     addr_low_i = 11 -> rdata_i[31:24]
//
// Para halfword existen dos posiciones alineadas posibles:
//
//     addr_low_i[1] = 0 -> rdata_i[15:0]
//     addr_low_i[1] = 1 -> rdata_i[31:16]
//
// La validez del alineamiento se verifica posteriormente.

reg [7:0]  byte_selected;
reg [15:0] half_selected;

always @* begin
    case (addr_low_i)

        2'b00:
            byte_selected = rdata_i[7:0];

        2'b01:
            byte_selected = rdata_i[15:8];

        2'b10:
            byte_selected = rdata_i[23:16];

        2'b11:
            byte_selected = rdata_i[31:24];

        default:
            byte_selected = 8'd0;

    endcase

    half_selected = addr_low_i[1] ? rdata_i[31:16] : rdata_i[15:0];
end

/*
 * ============================================================================
 *  LOAD / STORE DATAPATH
 * ============================================================================
 */

// ----------------------------------------------------------------------------
// Formateo, alineamiento y validacion
// ----------------------------------------------------------------------------

always @* begin

    // Salidas seguras por defecto.
    wdata_aligned_o = 32'd0;
    rdata_aligned_o = 32'd0;
    wdata_strobe_o  = 4'b0000;

    misaligned_o    = 1'b0;
    invalid_access_o = 1'b0;

    // ------------------------------------------------------------------------
    // Combinacion de control invalida
    // ------------------------------------------------------------------------

    if (load_i && store_i) begin
        invalid_access_o = 1'b1;
    end

    // ------------------------------------------------------------------------
    // LOAD
    // ------------------------------------------------------------------------

    else if (load_i) begin
        case (funct3_i)

            // LB - signed byte
            F3_LB: begin
                rdata_aligned_o = {{24{byte_selected[7]}}, byte_selected};
            end

            // LH - signed halfword
            F3_LH: begin
                if (addr_low_i[0])
                    misaligned_o = 1'b1;
                else
                    rdata_aligned_o = {{16{half_selected[15]}}, half_selected};
            end

            // LW - 32-bit word
            F3_LW: begin
                if (addr_low_i != 2'b00)
                    misaligned_o = 1'b1;
                else
                    rdata_aligned_o = rdata_i;
            end

            // LBU - unsigned byte
            F3_LBU: begin
                rdata_aligned_o = {24'd0, byte_selected};
            end

            // LHU - unsigned halfword
            F3_LHU: begin
                if (addr_low_i[0])
                    misaligned_o = 1'b1;
                else
                    rdata_aligned_o = {16'd0, half_selected};
            end

            default: begin
                invalid_access_o = 1'b1;
            end

        endcase
    end

    // ------------------------------------------------------------------------
    // STORE
    // ------------------------------------------------------------------------

    else if (store_i) begin
        case (funct3_i)

            // SB - el byte menos significativo de rs2 se coloca en el
            // byte lane seleccionado por addr_low_i.
            F3_SB: begin
                case (addr_low_i)

                    2'b00:
                        wdata_aligned_o = {24'd0, wdata_i[7:0]};

                    2'b01:
                        wdata_aligned_o = {16'd0, wdata_i[7:0], 8'd0};

                    2'b10:
                        wdata_aligned_o = {8'd0, wdata_i[7:0], 16'd0};

                    2'b11:
                        wdata_aligned_o = {wdata_i[7:0], 24'd0};

                    default:
                        wdata_aligned_o = 32'd0;

                endcase

                wdata_strobe_o = 4'b0001 << addr_low_i;
            end

            // SH - solo son validas las posiciones 00 y 10.
            F3_SH: begin
                if (addr_low_i[0]) begin
                    misaligned_o = 1'b1;
                end
                else if (addr_low_i[1]) begin
                    wdata_aligned_o = {wdata_i[15:0], 16'd0};

                    wdata_strobe_o = 4'b1100;
                end
                else begin
                    wdata_aligned_o = {16'd0, wdata_i[15:0]};

                    wdata_strobe_o = 4'b0011;
                end
            end

            // SW - una palabra solo es valida cuando addr_low_i = 00.
            F3_SW: begin
                if (addr_low_i != 2'b00) begin
                    misaligned_o = 1'b1;
                end
                else begin
                    wdata_aligned_o = wdata_i;
                    wdata_strobe_o  = 4'b1111;
                end
            end

            default: begin
                invalid_access_o = 1'b1;
            end

        endcase
    end

    // ------------------------------------------------------------------------
    // Safe outputs on fault
    // ------------------------------------------------------------------------

    // Un fault invalida cualquier dato o strobe calculado previamente.
    if (misaligned_o || invalid_access_o) begin
        wdata_aligned_o = 32'd0;
        rdata_aligned_o = 32'd0;
        wdata_strobe_o  = 4'b0000;
    end

end

endmodule
