`timescale 1ns / 1ps

/*
 * ========================================================================
 *  Program Loader Wishbone - Slave S2 / Master M1
 * ------------------------------------------------------------------------
 *  Recibe parametros mediante un puerto WB esclavo y ejecuta una operacion
 *  de memoria a traves de su propio puerto WB maestro. Ambos puertos son
 *  independientes: S_ACK_O al escribir START confirma la aceptacion de la
 *  orden; no significa que la memoria ya haya terminado.
 *
 *  Procedimiento desde el host:
 *      1. Detener la CPU mediante debug_controller_wbs.
 *      2. Escribir TARGET_ADDR, WRITE_DATA si aplica y BYTE_SEL.
 *      3. Escribir 1 en START_WRITE o START_READ.
 *      4. Consultar STATUS hasta BUSY = 0 y DONE = 1.
 *      5. Revisar ERROR; en lectura, obtener READ_DATA.
 *
 *  Al aceptar START se copian los parametros al puerto maestro y BUSY = 1.
 *  Los parametros quedan bloqueados mientras la operacion esta pendiente.
 *  El destino debe pertenecer a IMEM o DMEM; la memoria valida el tamano real.
 *  ACK/ERR del maestro finalizan la operacion y liberan CYC/STB.
 *
 *  DONE y ERROR permanecen hasta el siguiente START aceptado o reset global.
 *  START_PENDING_O anticipa una solicitud de inicio para impedir RUN/STEP
 *  en el mismo flanco de aceptacion. Es una senal local del SoC.
 *  El timeout lo proporciona el crossbar; este modulo guarda su resultado.
 *  No recibe bytes UART, no interpreta instrucciones y no implementa DMA
 *  autonomo de bloques: cada START realiza un acceso SINGLE READ/WRITE.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module program_loader_wb (

    // ---------------------------------------------------------
    //  Reloj y reset
    // ---------------------------------------------------------
    input wire CLK_I,  // Reloj comun del bus; flanco ascendente.
    input wire RST_I,  // Reset sincrono activo en alto.

    // ---------------------------------------------------------
    //  Interbloqueo local con la CPU
    // ---------------------------------------------------------
    input  wire CPU_HALTED_I,    // CPU detenida y fuera de reset/STEP.
    output reg  BUSY_O,          // Hay una transferencia de memoria pendiente.
    output wire START_PENDING_O, // Interbloqueo anticipado ante START.

    // ---------------------------------------------------------
    //  Puerto esclavo de registros: S2 del crossbar
    // ---------------------------------------------------------
    input  wire [31:0] S_ADR_I,  // Direccion absoluta de byte recibida.
    input  wire [31:0] S_DAT_I,  // Datos que recibe este puerto WB.
    input  wire [3:0]  S_SEL_I,  // Seleccion de bytes: bit 0 -> DAT[7:0].
    input  wire        S_WE_I,   // 1 = escritura; 0 = lectura.
    input  wire        S_CYC_I,  // Ciclo Wishbone activo.
    input  wire        S_STB_I,  // Solicitud valida dentro del ciclo.
    output reg  [31:0] S_DAT_O,  // Datos que entrega este puerto WB.
    output wire        S_ACK_O,  // Confirmacion de transferencia correcta.
    output wire        S_ERR_O,  // Terminacion del acceso por error.

    // ---------------------------------------------------------
    //  Puerto maestro de memoria: M1 del crossbar
    // ---------------------------------------------------------
    output reg  [31:0] M_ADR_O,     // Direccion absoluta de byte solicitada.
    output reg  [31:0] M_DAT_O,     // Datos que entrega este puerto WB.
    output reg  [3:0]  M_SEL_O,     // Seleccion de bytes del acceso.
    output reg         M_WE_O,      // 1 = escritura; 0 = lectura.
    output wire        M_CYC_O,     // Mantiene activo el ciclo Wishbone.
    output wire        M_STB_O,     // Solicitud valida del maestro.
    input  wire [31:0] M_DAT_I,     // Datos que recibe este puerto WB.
    input  wire        M_ACK_I,     // Confirmacion de transferencia correcta.
    input  wire        M_ERR_I,     // Terminacion del acceso por error.
    input  wire        M_TIMEOUT_I  // Indicador local de expiracion del watchdog.
);

    // ========================================================================
    //  Registros accesibles desde el host
    // ------------------------------------------------------------------------
    //  Base: 0x10000000. Todos los registros requieren SEL = 4'hF.
    //  Offset  Nombre         Acceso   Significado
    //   0x00   TARGET_ADDR    R/W      Direccion absoluta y alineada de IMEM/DMEM.
    //   0x04   WRITE_DATA     R/W      Palabra de escritura.
    //   0x08   BYTE_SEL       R/W      Bits 3:0; 1..15. Los bits altos deben ser cero.
    //   0x0C   START_WRITE    W        Escribir 1 para iniciar una escritura.
    //   0x10   START_READ     W        Escribir 1 para iniciar una lectura.
    //   0x14   STATUS        R        bit0 BUSY, bit1 DONE, bit2 ERROR.
    //   0x18   READ_DATA     R        Resultado de la ultima lectura terminada bien.
    //   0x1C   ERROR_CODE    R        0 = ninguno, 1 = ERR, 2 = timeout.
    //
    //  DONE tambien se activa si la operacion termina en error. READ_DATA queda
    //  cero al iniciar, al escribir o ante error. Se rechazan otros offsets, las
    //  lecturas de START, las escrituras a registros R y cambios de parametros BUSY.
    // ========================================================================

    // ---------------------------------------------------------
    //  Registros de configuracion y resultado visibles por S2.
    // ---------------------------------------------------------
    reg [31:0] target_addr;
    reg [31:0] write_data;
    reg [31:0] read_data;
    reg [31:0] error_code;
    reg [3:0]  byte_sel;

    // ---------------------------------------------------------
    //  Estado interno del loader y del slave register bank.
    // ---------------------------------------------------------
    reg done;
    reg failed;
    reg served;
    reg valid;

    // ---------------------------------------------------------
    //  Request actual recibido por el puerto slave S2.
    // ---------------------------------------------------------
    wire request;

    // ---------------------------------------------------------
    //  Identificacion de los registros START_WRITE / START_READ.
    // ---------------------------------------------------------
    wire start_reg;

    // ---------------------------------------------------------
    //  Validez del TARGET_ADDR configurado por el host.
    // ---------------------------------------------------------
    wire target_valid;

    // ---------------------------------------------------------
    //  Request efectivo del slave S2.
    // ---------------------------------------------------------
    assign request = S_CYC_I && S_STB_I && !served && !RST_I;

    // ---------------------------------------------------------
    //  Decode de los registros que disparan una transferencia M1.
    // ---------------------------------------------------------
    assign start_reg = (S_ADR_I[7:0] == 8'h0c) || (S_ADR_I[7:0] == 8'h10);

    // ---------------------------------------------------------
    //  El loader solo puede apuntar a las ventanas IMEM/DMEM y a word alignment.
    // ---------------------------------------------------------
    assign target_valid =
        ((target_addr[31:16] == 16'h0000) || (target_addr[31:16] == 16'h0001)) &&
        (target_addr[1:0] == 2'b00);

    // ---------------------------------------------------------
    //  Interlock anticipado para bloquear RUN/STEP en el flanco de START.
    // ---------------------------------------------------------
    assign START_PENDING_O = request && S_WE_I && start_reg;

    // ---------------------------------------------------------
    //  Terminacion del puerto slave S2.
    // ---------------------------------------------------------
    assign S_ACK_O = request && valid;
    assign S_ERR_O = request && !valid;

    // ---------------------------------------------------------
    //  Classic SINGLE generado por el puerto master M1.
    // ---------------------------------------------------------
    assign M_CYC_O = BUSY_O && !RST_I;
    assign M_STB_O = M_CYC_O;

    // ========================================================================
    //  Lectura de registros y validacion de permisos
    // ------------------------------------------------------------------------
    // ========================================================================

    always @* begin
        valid   = S_ADR_I[31:8] == 24'h100000 && S_ADR_I[1:0] == 0 && S_SEL_I == 4'hf;
        S_DAT_O = 0;
        if (S_WE_I) begin
            case (S_ADR_I[7:0])
                8'h00:
                valid = valid && !BUSY_O && S_DAT_I[1:0] == 0 &&
                    (S_DAT_I[31:16] == 0 || S_DAT_I[31:16] == 1);
                8'h04: valid = valid && !BUSY_O;
                8'h08: valid = valid && !BUSY_O && S_DAT_I[31:4] == 0 && S_DAT_I[3:0] != 0;
                8'h0c, 8'h10:
                valid = valid && !BUSY_O && CPU_HALTED_I && target_valid && byte_sel != 0 &&
                    S_DAT_I == 1;
                default: valid = 0;
            endcase
        end else begin
            case (S_ADR_I[7:0])
                8'h00:   S_DAT_O = target_addr;
                8'h04:   S_DAT_O = write_data;
                8'h08:   S_DAT_O = {28'd0, byte_sel};
                8'h14:   S_DAT_O = {29'd0, failed, done, BUSY_O};
                8'h18:   S_DAT_O = read_data;
                8'h1c:   S_DAT_O = error_code;
                default: valid = 0;
            endcase
        end
    end

    // ========================================================================
    //  Aceptacion de ordenes y seguimiento del acceso maestro
    // ------------------------------------------------------------------------
    //  Los parametros M_* se copian al aceptar START y quedan estables hasta terminar.
    //  S_ACK no espera a M_ACK: el host utiliza STATUS para conocer la finalizacion.
    //  La terminacion del maestro limpia BUSY y registra DONE/ERROR/READ_DATA.
    // ========================================================================

    always @(posedge CLK_I) begin
        if (RST_I) begin
            target_addr <= 0;
            write_data  <= 0;
            byte_sel    <= 4'hf;
            read_data   <= 0;
            error_code  <= 0;
            done        <= 0;
            failed      <= 0;
            served      <= 0;
            BUSY_O      <= 0;
            M_ADR_O     <= 0;
            M_DAT_O     <= 0;
            M_SEL_O     <= 0;
            M_WE_O      <= 0;
        end else begin
            if (!S_CYC_I || !S_STB_I) served <= 0;
            else if (S_ACK_O || S_ERR_O) served <= 1;
            if (S_ACK_O && S_WE_I) begin
                case (S_ADR_I[7:0])
                    8'h00: target_addr <= S_DAT_I;
                    8'h04: write_data <= S_DAT_I;
                    8'h08: byte_sel <= S_DAT_I[3:0];
                    8'h0c, 8'h10: begin
                        M_ADR_O    <= target_addr;
                        M_DAT_O    <= write_data;
                        M_SEL_O    <= byte_sel;
                        M_WE_O     <= (S_ADR_I[7:0] == 8'h0c);
                        BUSY_O     <= 1;
                        done       <= 0;
                        failed     <= 0;
                        error_code <= 0;
                        read_data  <= 0;
                    end
                    default: begin
                    end
                endcase
            end
            if (BUSY_O && (M_ACK_I || M_ERR_I)) begin
                BUSY_O     <= 0;
                done       <= 1;
                failed     <= M_ERR_I;
                error_code <= M_ERR_I ? (M_TIMEOUT_I ? 32'd2 : 32'd1) : 32'd0;
                read_data  <= (!M_ERR_I && !M_WE_O) ? M_DAT_I : 32'd0;
            end
        end
    end
endmodule
