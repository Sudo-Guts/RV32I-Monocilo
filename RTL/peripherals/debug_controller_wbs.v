`timescale 1ns / 1ps

/*
 * ========================================================================
 *  Debug Controller Wishbone Slave - S3
 * ------------------------------------------------------------------------
 *  Esclavo Wishbone que convierte escrituras de registros en RUN, HALT,
 *  STEP y CORE_RESET. Lee directamente PC, instruccion, write-back y el
 *  puerto de depuracion del banco de registros. No es maestro del crossbar.
 *
 *  RUN mantiene CPU_EN_O activo. HALT lo desactiva despues del flanco de
 *  aceptacion; la instruccion de ese flanco puede ser la ultima ejecutada.
 *  STEP genera un solo intervalo habilitado: exactamente una instruccion.
 *  CORE_RESET genera un reset de un ciclo con la CPU previamente detenida.
 *  Las escrituras a estos cuatro registros deben contener el valor 1.
 *
 *  MAINTENANCE_BUSY_I bloquea RUN/STEP/CORE_RESET cuando hay acceso externo
 *  a memoria o actividad del loader. No interrumpe una instruccion en curso.
 *  La logica secuencial de UART, crossbar y loader continua con su reloj
 *  mientras CPU_EN_O = 0. El reloj del core tampoco se corta.
 *
 *  PC/INSTR/WB_DATA describen el estado combinacional actual. LAST_* guarda
 *  los valores anteriores al flanco de cada instruccion habilitada.
 *  LAST_WB_DATA se captura incluso en instrucciones que no escriben rd.
 *  LAST_FAULT informa solo fallos de la LSU, no fallos de direccion del bus.
 *
 *  Las lecturas de observacion requieren HALT. STATUS, REG_INDEX, ID,
 *  capacidades y VERSION pueden leerse sin detener la CPU.
 *  El reset global deja RUN = 0, PC = 0 y LAST_VALID = 0.
 *  CORE_RESET no reinicia UART/crossbar y no borra registros generales ni RAM.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module debug_controller_wbs #(
    // Log2 de palabras IMEM; 9 -> 512 palabras / 2 KiB.
    parameter integer IMEM_WORD_ADDR_WIDTH = 9,
    // Log2 de palabras DMEM; 8 -> 256 palabras / 1 KiB.
    parameter integer DMEM_WORD_ADDR_WIDTH = 8
) (

    // ---------------------------------------------------------
    //  Reloj y reset
    // ---------------------------------------------------------
    input wire CLK_I,  // Reloj comun del bus; flanco ascendente.
    input wire RST_I,  // Reset sincrono activo en alto.

    // ---------------------------------------------------------
    //  Puerto esclavo de registros: S3 del crossbar
    // ---------------------------------------------------------
    input  wire [31:0] ADR_I,  // Direccion absoluta de byte recibida.
    input  wire [31:0] DAT_I,  // Datos que recibe este puerto WB.
    input  wire [3:0]  SEL_I,  // Seleccion de bytes: bit 0 -> DAT[7:0].
    input  wire        WE_I,   // 1 = escritura; 0 = lectura.
    input  wire        CYC_I,  // Ciclo Wishbone activo.
    input  wire        STB_I,  // Solicitud valida dentro del ciclo.
    output reg  [31:0] DAT_O,  // Datos que entrega este puerto WB.
    output wire        ACK_O,  // Confirmacion de transferencia correcta.
    output wire        ERR_O,  // Terminacion del acceso por error.

    // ---------------------------------------------------------
    //  Control directo punto a punto del core
    // ---------------------------------------------------------
    input  wire MAINTENANCE_BUSY_I,  // Bloquea RUN/STEP/RESET por mantenimiento.
    output wire CPU_EN_O,            // Habilita la ejecucion de una instruccion.
    output wire CPU_RST_O,           // Reset sincrono del core, activo en alto.
    output wire CPU_RUNNING_O,       // RUN continuo activo.
    output wire CPU_HALTED_O,        // Core detenido, fuera de STEP y reset.

    // ---------------------------------------------------------
    //  Observacion directa del core
    // ---------------------------------------------------------
    input wire [31:0] CPU_PC_I,      // PC actual recibido del core.
    input wire [31:0] CPU_INSTR_I,   // Instruccion actual recibida del core.
    input wire [31:0] CPU_WB_DATA_I, // Dato actual del multiplexor WB del core.

    // ---------------------------------------------------------
    //  Lectura del banco de registros
    // ---------------------------------------------------------
    output reg  [4:0]  CPU_DBG_REG_ADDR_O,  // Indice de registro solicitado por el host.
    input  wire [31:0] CPU_DBG_REG_DATA_I,  // Valor del registro seleccionado.

    // ---------------------------------------------------------
    //  Observacion de fallos LSU
    // ---------------------------------------------------------
    input wire CPU_MEM_MISALIGNED_I,  // Fallo de alineacion de la LSU actual.
    input wire CPU_MEM_INVALID_I      // Fallo de tipo de acceso de la LSU actual.
);

    // ========================================================================
    //  Mapa de registros del debugger
    // ------------------------------------------------------------------------
    //  Base: 0x10001000. Accesos alineados, SEL = 4'hF.
    //  Offset  Nombre         Acceso  Funcion
    //   0x00   STATUS         R       Bits definidos debajo.
    //   0x04   HALT           W1      Detener despues del flanco de aceptacion.
    //   0x08   RUN            W1      Habilitar ejecucion continua.
    //   0x0C   STEP           W1      Una instruccion; requiere HALT.
    //   0x10   CORE_RESET     W1      Reiniciar PC; requiere HALT.
    //   0x14   PC             R/HALT  PC actual.
    //   0x18   INSTR          R/HALT  Instruccion actual.
    //   0x1C   WB_DATA        R/HALT  Dato combinacional actual del write-back.
    //   0x20   REG_INDEX      R/W     Indice 0..31; escritura requiere HALT.
    //   0x24   REG_DATA       R/HALT  Valor del registro seleccionado.
    //   0x28   LAST_PC        R/HALT  PC de la ultima instruccion ejecutada.
    //   0x2C   LAST_INSTR     R/HALT  Ultima instruccion ejecutada.
    //   0x30   LAST_WB_DATA   R/HALT  Dato WB de esa instruccion.
    //   0x34   ID             R       0x52563332, identificador del dispositivo.
    //   0x38   IMEM_BYTES     R       Capacidad real de IMEM en bytes.
    //   0x3C   DMEM_BYTES     R       Capacidad real de DMEM en bytes.
    //   0x40   VERSION        R       0x00010000, interfaz 1.0.
    //   0x44   LAST_FAULT     R/HALT  bit0 desalineacion, bit1 acceso LSU invalido.
    //
    //  W1 significa escribir exactamente 32'd1, no escribir un bit arbitrario.
    //  STATUS: bit0 RUN; bit1 HALTED; bit2 STEP; bit3 RESET; bit4 MAINTENANCE;
    //          bit5 LAST_VALID. Los bits restantes se leen como cero.
    //  LAST_VALID pasa a uno al ejecutar y vuelve a cero en reset global/local.
    //  Los registros LAST_* no cambian por una lectura del debugger.
    // ========================================================================

    // ---------------------------------------------------------
    //  Estado persistente de RUN y pulsos STEP/RESET.
    // ---------------------------------------------------------
    reg running;
    reg stepping;
    reg resetting;

    // ---------------------------------------------------------
    //  Control de una sola respuesta por request Wishbone mantenido.
    // ---------------------------------------------------------
    reg served;
    reg valid;

    // ---------------------------------------------------------
    //  Snapshot de la ultima instruccion ejecutada.
    // ---------------------------------------------------------
    reg [31:0] last_pc;
    reg [31:0] last_instr;
    reg [31:0] last_wb_data;
    reg [1:0]  last_fault;
    reg        last_valid;

    // ---------------------------------------------------------
    //  Request actual del slave S3.
    // ---------------------------------------------------------
    wire request;

    // ---------------------------------------------------------
    //  Request efectivo del register bank de debug.
    // ---------------------------------------------------------
    assign request = CYC_I && STB_I && !served && !RST_I;

    // ---------------------------------------------------------
    //  Habilitacion directa del core.
    // ---------------------------------------------------------
    assign CPU_EN_O = (running || stepping) && !RST_I && !resetting;

    // ---------------------------------------------------------
    //  Reset local del core; no reinicia UART ni crossbar.
    // ---------------------------------------------------------
    assign CPU_RST_O = RST_I || resetting;

    // ---------------------------------------------------------
    //  Estado observable de ejecucion.
    // ---------------------------------------------------------
    assign CPU_RUNNING_O = running && !RST_I;
    assign CPU_HALTED_O  = !running && !stepping && !resetting && !RST_I;

    // ---------------------------------------------------------
    //  Terminacion del Wishbone Slave S3.
    // ---------------------------------------------------------
    assign ACK_O = request && valid;
    assign ERR_O = request && !valid;

    // ========================================================================
    //  Decodificacion de registros y restricciones de acceso
    // ------------------------------------------------------------------------
    // ========================================================================

    always @* begin
        valid = ADR_I[31:8] == 24'h100010 && ADR_I[1:0] == 0 && SEL_I == 4'hf;
        DAT_O = 0;
        if (WE_I) begin
            case (ADR_I[7:0])
                8'h04: valid = valid && DAT_I == 1;  // HALT, idempotente.
                8'h08: valid = valid && DAT_I == 1 && !stepping && !resetting && !MAINTENANCE_BUSY_I;
                8'h0c: valid = valid && DAT_I == 1 && CPU_HALTED_O && !MAINTENANCE_BUSY_I;
                8'h10: valid = valid && DAT_I == 1 && CPU_HALTED_O && !MAINTENANCE_BUSY_I;
                8'h20: valid = valid && CPU_HALTED_O && DAT_I < 32;
                default: valid = 0;
            endcase
        end else begin
            case (ADR_I[7:0])
                // STATUS: run, halted, step, reset, maintenance, last-valid.
                8'h00:
                DAT_O = {
                    26'd0,
                    last_valid,
                    MAINTENANCE_BUSY_I,
                    resetting,
                    stepping,
                    CPU_HALTED_O,
                    CPU_RUNNING_O
                };
                8'h14: begin
                    DAT_O = CPU_PC_I;
                    valid = valid && CPU_HALTED_O;
                end
                8'h18: begin
                    DAT_O = CPU_INSTR_I;
                    valid = valid && CPU_HALTED_O;
                end
                8'h1c: begin
                    DAT_O = CPU_WB_DATA_I;
                    valid = valid && CPU_HALTED_O;
                end
                8'h20: DAT_O = {27'd0, CPU_DBG_REG_ADDR_O};
                8'h24: begin
                    DAT_O = CPU_DBG_REG_DATA_I;
                    valid = valid && CPU_HALTED_O;
                end
                8'h28: begin
                    DAT_O = last_pc;
                    valid = valid && CPU_HALTED_O;
                end
                8'h2c: begin
                    DAT_O = last_instr;
                    valid = valid && CPU_HALTED_O;
                end
                8'h30: begin
                    DAT_O = last_wb_data;
                    valid = valid && CPU_HALTED_O;
                end
                8'h34: DAT_O = 32'h52563332;  // Identificador RV32.
                8'h38: DAT_O = 32'd4 << IMEM_WORD_ADDR_WIDTH;
                8'h3c: DAT_O = 32'd4 << DMEM_WORD_ADDR_WIDTH;
                8'h40: DAT_O = 32'h00010000;  // Version de la interfaz: 1.0.
                8'h44: begin
                    DAT_O = {30'd0, last_fault};
                    valid = valid && CPU_HALTED_O;
                end
                default: valid = 0;
            endcase
        end
    end

    // ========================================================================
    //  RUN persistente, pulsos STEP/RESET y captura LAST_*
    // ------------------------------------------------------------------------
    //  stepping y resetting se limpian por defecto cada ciclo. Una orden aceptada
    //  los activa para el siguiente flanco; el core ejecuta o reinicia una sola vez.
    //  La captura LAST_* usa los valores anteriores al flanco de actualizacion de PC.
    // ========================================================================

    always @(posedge CLK_I) begin
        if (RST_I) begin
            running          <= 0;
            stepping         <= 0;
            resetting        <= 0;
            served           <= 0;
            CPU_DBG_REG_ADDR_O <= 0;
            last_pc          <= 0;
            last_instr       <= 0;
            last_wb_data     <= 0;
            last_fault       <= 0;
            last_valid       <= 0;
        end else begin
            stepping  <= 0;
            resetting <= 0;
            if (!CYC_I || !STB_I) served <= 0;
            else if (ACK_O || ERR_O) served <= 1;
            // Captura exactamente la instruccion ejecutada en este flanco.
            if (CPU_EN_O) begin
                last_pc      <= CPU_PC_I;
                last_instr   <= CPU_INSTR_I;
                last_wb_data <= CPU_WB_DATA_I;
                last_fault   <= {CPU_MEM_INVALID_I, CPU_MEM_MISALIGNED_I};
                last_valid   <= 1;
            end
            if (ACK_O && WE_I) begin
                case (ADR_I[7:0])
                    8'h04: running <= 0;
                    8'h08: running <= 1;
                    8'h0c: stepping <= 1;
                    8'h10: begin
                        resetting    <= 1;
                        last_pc      <= 0;
                        last_instr   <= 0;
                        last_wb_data <= 0;
                        last_fault   <= 0;
                        last_valid   <= 0;
                    end
                    8'h20: CPU_DBG_REG_ADDR_O <= DAT_I[4:0];
                    default: begin
                    end
                endcase
            end
        end
    end
endmodule
