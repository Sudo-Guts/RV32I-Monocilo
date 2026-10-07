`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Wishbone Crossbar
 * ----------------------------------------------------------------------------
 *  Interconexion fija:
 *
 *      - 4 Masters
 *      - 4 Slaves
 *      - 2 canales dinamicos
 *      - 32 bits de direccion y datos
 *      - SEL[3:0]
 *
 *  Los canales no pertenecen permanentemente a ningun Master ni Slave.
 *  wb_switch_control registra para cada canal el Master y Slave conectados.
 *
 *  Camino de solicitud:
 *
 *      Masters -> decoder/control -> MUX -> CHANNEL -> DEMUX -> Slaves
 *
 *  Camino de respuesta:
 *
 *      Slaves -> MUX -> CHANNEL -> DEMUX -> Masters
 *
 *  Perfil Wishbone utilizado:
 *
 *      Classic SINGLE
 *      una transferencia por CYC
 *      sin STALL, RTY, BLOCK ni RMW
 *
 *  El Master conserva ADR/DAT/SEL/WE hasta ACK/ERR. Para iniciar un nuevo
 *  acceso debe observarse CYC=0. Una pausa de STB conserva la conexion.
 *
 *  Timeout:
 *
 *      - fijo a 1024 ciclos por Master
 *      - contador saturado de 11 bits
 *      - comienza con el primer ciclo CYC/STB activo
 *      - despues cuenta tambien arbitraje, rearme y pausas de STB
 *      - TIMEOUT se entrega junto con ERR
 *
 *  Rearme:
 *
 *      Cada Slave liberado recibe un ciclo completo con CYC/STB=0 antes de
 *      poder ser utilizado por un nuevo propietario. Esto permite limpiar
 *      correctamente el estado interno served/done de los Slaves actuales.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ============================================================================
 */

module wb_crossbar (

    input wire CLK_I,
    input wire RST_I,

    // ------------------------------------------------------------------------
    //  Wishbone Masters M0..M3
    // ------------------------------------------------------------------------
    input  wire [127:0] M_ADR_I,
    input  wire [127:0] M_DAT_I,
    input  wire [15:0]  M_SEL_I,
    input  wire [3:0]   M_WE_I,
    input  wire [3:0]   M_CYC_I,
    input  wire [3:0]   M_STB_I,

    output wire [127:0] M_DAT_O,
    output wire [3:0]   M_ACK_O,
    output wire [3:0]   M_ERR_O,
    output wire [3:0]   M_TIMEOUT_O,

    // ------------------------------------------------------------------------
    //  Wishbone Slaves S0..S3
    // ------------------------------------------------------------------------
    output wire [127:0] S_ADR_O,
    output wire [127:0] S_DAT_O,
    output wire [15:0]  S_SEL_O,
    output wire [3:0]   S_WE_O,
    output wire [3:0]   S_CYC_O,
    output wire [3:0]   S_STB_O,

    input  wire [127:0] S_DAT_I,
    input  wire [3:0]   S_ACK_I,
    input  wire [3:0]   S_ERR_I

);

    // ========================================================================
    //  Address decoder
    // ========================================================================

    wire [7:0] master_target;
    wire [3:0] master_target_valid;
    wire [3:0] master_unmapped;
    wire [3:0] master_overlap;

    wb_address_decoder decoder_inst (

        .M_ADR_I         (M_ADR_I),
        .M_TARGET_O      (master_target),
        .M_TARGET_VALID_O(master_target_valid),
        .M_UNMAPPED_O    (master_unmapped),
        .M_OVERLAP_O     (master_overlap)

    );


    // ========================================================================
    //  Estado de transaccion por Master
    // ========================================================================

    reg master0_finished;
    reg master1_finished;
    reg master2_finished;
    reg master3_finished;

    reg master0_started;
    reg master1_started;
    reg master2_started;
    reg master3_started;

    reg [10:0] master0_age;
    reg [10:0] master1_age;
    reg [10:0] master2_age;
    reg [10:0] master3_age;


    // ------------------------------------------------------------------------
    //  Transferencia actualmente visible por cada Master
    // ------------------------------------------------------------------------

    wire master0_pending =
        M_CYC_I[0] & M_STB_I[0] & ~master0_finished & ~RST_I;

    wire master1_pending =
        M_CYC_I[1] & M_STB_I[1] & ~master1_finished & ~RST_I;

    wire master2_pending =
        M_CYC_I[2] & M_STB_I[2] & ~master2_finished & ~RST_I;

    wire master3_pending =
        M_CYC_I[3] & M_STB_I[3] & ~master3_finished & ~RST_I;


    // ------------------------------------------------------------------------
    //  Error local de decodificacion
    // ------------------------------------------------------------------------

    wire master0_decode_error = master_unmapped[0] | master_overlap[0];
    wire master1_decode_error = master_unmapped[1] | master_overlap[1];
    wire master2_decode_error = master_unmapped[2] | master_overlap[2];
    wire master3_decode_error = master_unmapped[3] | master_overlap[3];


    // ------------------------------------------------------------------------
    //  Timeout fijo de 1024 ciclos
    // ------------------------------------------------------------------------
    //  El bit 10 se activa al alcanzar 1024. El contador se satura ahi.
    // ------------------------------------------------------------------------

    wire master0_expired =
        M_CYC_I[0] & master0_started & master0_age[10] &
        ~master0_finished & ~RST_I;

    wire master1_expired =
        M_CYC_I[1] & master1_started & master1_age[10] &
        ~master1_finished & ~RST_I;

    wire master2_expired =
        M_CYC_I[2] & master2_started & master2_age[10] &
        ~master2_finished & ~RST_I;

    wire master3_expired =
        M_CYC_I[3] & master3_started & master3_age[10] &
        ~master3_finished & ~RST_I;


    // ========================================================================
    //  Solicitudes y liberaciones hacia wb_switch_control
    // ========================================================================

    wire [3:0] master_request;
    wire [3:0] master_release;

    assign master_request[0] =
        master0_pending & master_target_valid[0] & ~master0_expired;

    assign master_request[1] =
        master1_pending & master_target_valid[1] & ~master1_expired;

    assign master_request[2] =
        master2_pending & master_target_valid[2] & ~master2_expired;

    assign master_request[3] =
        master3_pending & master_target_valid[3] & ~master3_expired;


    assign master_release[0] =
        ~M_CYC_I[0] | M_ACK_O[0] | M_ERR_O[0] | master0_expired;

    assign master_release[1] =
        ~M_CYC_I[1] | M_ACK_O[1] | M_ERR_O[1] | master1_expired;

    assign master_release[2] =
        ~M_CYC_I[2] | M_ACK_O[2] | M_ERR_O[2] | master2_expired;

    assign master_release[3] =
        ~M_CYC_I[3] | M_ACK_O[3] | M_ERR_O[3] | master3_expired;


    // ========================================================================
    //  Switch control
    // ========================================================================

    wire [1:0] channel_valid;
    wire [3:0] channel_master;
    wire [3:0] channel_slave;

    wire [1:0] channel0_master = channel_master[1:0];
    wire [1:0] channel1_master = channel_master[3:2];

    wire [1:0] channel0_slave = channel_slave[1:0];
    wire [1:0] channel1_slave = channel_slave[3:2];

    wb_switch_control switch_control_inst (

        .CLK_I          (CLK_I),
        .RST_I          (RST_I),

        .M_REQ_I         (master_request),
        .M_TARGET_VALID_I(master_target_valid),
        .M_TARGET_I      (master_target),
        .M_RELEASE_I     (master_release),

        .CH_VALID_O      (channel_valid),
        .CH_MASTER_SEL_O (channel_master),
        .CH_SLAVE_SEL_O  (channel_slave)

    );


    // ========================================================================
    //  MUX de liberacion Master -> Channel
    // ========================================================================

    reg channel0_master_release;
    reg channel1_master_release;

    always @* begin

        channel0_master_release = 1'b0;

        case (channel0_master)
            2'd0: channel0_master_release = master_release[0];
            2'd1: channel0_master_release = master_release[1];
            2'd2: channel0_master_release = master_release[2];
            2'd3: channel0_master_release = master_release[3];
            default: channel0_master_release = 1'b0;
        endcase

    end

    always @* begin

        channel1_master_release = 1'b0;

        case (channel1_master)
            2'd0: channel1_master_release = master_release[0];
            2'd1: channel1_master_release = master_release[1];
            2'd2: channel1_master_release = master_release[2];
            2'd3: channel1_master_release = master_release[3];
            default: channel1_master_release = 1'b0;
        endcase

    end

    wire release_channel0 = channel_valid[0] & channel0_master_release;
    wire release_channel1 = channel_valid[1] & channel1_master_release;


    // ========================================================================
    //  Deteccion del Slave liberado
    // ========================================================================

    wire [3:0] slave_released;

    assign slave_released[0] =
        (release_channel0 & (channel0_slave == 2'd0)) |
        (release_channel1 & (channel1_slave == 2'd0));

    assign slave_released[1] =
        (release_channel0 & (channel0_slave == 2'd1)) |
        (release_channel1 & (channel1_slave == 2'd1));

    assign slave_released[2] =
        (release_channel0 & (channel0_slave == 2'd2)) |
        (release_channel1 & (channel1_slave == 2'd2));

    assign slave_released[3] =
        (release_channel0 & (channel0_slave == 2'd3)) |
        (release_channel1 & (channel1_slave == 2'd3));


    // ========================================================================
    //  Registro de rearme por Slave
    // ========================================================================

    reg [3:0] slave_rearm;

    always @(posedge CLK_I) begin

        if (RST_I)
            slave_rearm <= 4'b0000;
        else
            slave_rearm <= slave_released;

    end


    // ========================================================================
    //  MUX de rearme Slave -> Channel
    // ========================================================================

    reg channel0_rearm;
    reg channel1_rearm;

    always @* begin

        channel0_rearm = 1'b0;

        case (channel0_slave)
            2'd0: channel0_rearm = slave_rearm[0];
            2'd1: channel0_rearm = slave_rearm[1];
            2'd2: channel0_rearm = slave_rearm[2];
            2'd3: channel0_rearm = slave_rearm[3];
            default: channel0_rearm = 1'b0;
        endcase

    end

    always @* begin

        channel1_rearm = 1'b0;

        case (channel1_slave)
            2'd0: channel1_rearm = slave_rearm[0];
            2'd1: channel1_rearm = slave_rearm[1];
            2'd2: channel1_rearm = slave_rearm[2];
            2'd3: channel1_rearm = slave_rearm[3];
            default: channel1_rearm = 1'b0;
        endcase

    end


    // ========================================================================
    //  Bloqueo de ruta durante el rearme del Slave
    // ------------------------------------------------------------------------
    //  Como los canales son dinamicos, el bloqueo se devuelve al Master que
    //  actualmente posee el canal apuntando al Slave en rearme.
    // ========================================================================

    wire master0_route_blocked =
        (channel_valid[0] & channel0_rearm & (channel0_master == 2'd0)) |
        (channel_valid[1] & channel1_rearm & (channel1_master == 2'd0));

    wire master1_route_blocked =
        (channel_valid[0] & channel0_rearm & (channel0_master == 2'd1)) |
        (channel_valid[1] & channel1_rearm & (channel1_master == 2'd1));

    wire master2_route_blocked =
        (channel_valid[0] & channel0_rearm & (channel0_master == 2'd2)) |
        (channel_valid[1] & channel1_rearm & (channel1_master == 2'd2));

    wire master3_route_blocked =
        (channel_valid[0] & channel0_rearm & (channel0_master == 2'd3)) |
        (channel_valid[1] & channel1_rearm & (channel1_master == 2'd3));


    // ========================================================================
    //  Habilitacion hacia wb_switch_fabric
    // ========================================================================

    wire [3:0] fabric_cyc;
    wire [3:0] fabric_stb;

    wire [127:0] fabric_read_data;
    wire [3:0]   fabric_ack;
    wire [3:0]   fabric_err;


    assign fabric_cyc[0] =
        M_CYC_I[0] &
        ~master0_finished &
        ~master0_expired &
        ~master0_decode_error &
        ~master0_route_blocked &
        ~RST_I;

    assign fabric_cyc[1] =
        M_CYC_I[1] &
        ~master1_finished &
        ~master1_expired &
        ~master1_decode_error &
        ~master1_route_blocked &
        ~RST_I;

    assign fabric_cyc[2] =
        M_CYC_I[2] &
        ~master2_finished &
        ~master2_expired &
        ~master2_decode_error &
        ~master2_route_blocked &
        ~RST_I;

    assign fabric_cyc[3] =
        M_CYC_I[3] &
        ~master3_finished &
        ~master3_expired &
        ~master3_decode_error &
        ~master3_route_blocked &
        ~RST_I;


    assign fabric_stb[0] = M_STB_I[0] & fabric_cyc[0];
    assign fabric_stb[1] = M_STB_I[1] & fabric_cyc[1];
    assign fabric_stb[2] = M_STB_I[2] & fabric_cyc[2];
    assign fabric_stb[3] = M_STB_I[3] & fabric_cyc[3];


    // ========================================================================
    //  Switch fabric
    // ========================================================================

    wb_switch_fabric switch_fabric_inst (

        .M_ADR_I         (M_ADR_I),
        .M_DAT_I         (M_DAT_I),
        .M_SEL_I         (M_SEL_I),
        .M_WE_I          (M_WE_I),
        .M_CYC_I         (fabric_cyc),
        .M_STB_I         (fabric_stb),

        .M_DAT_O         (fabric_read_data),
        .M_ACK_O         (fabric_ack),
        .M_ERR_O         (fabric_err),

        .S_ADR_O         (S_ADR_O),
        .S_DAT_O         (S_DAT_O),
        .S_SEL_O         (S_SEL_O),
        .S_WE_O          (S_WE_O),
        .S_CYC_O         (S_CYC_O),
        .S_STB_O         (S_STB_O),

        .S_DAT_I         (S_DAT_I),
        .S_ACK_I         (S_ACK_I),
        .S_ERR_I         (S_ERR_I),

        .CH_VALID_I      (channel_valid),
        .CH_MASTER_SEL_I (channel_master),
        .CH_SLAVE_SEL_I  (channel_slave)

    );


    // ========================================================================
    //  Respuesta final hacia los Masters
    // ------------------------------------------------------------------------
    //  Prioridad:
    //
    //      1. Timeout
    //      2. Error de decoder
    //      3. ERR del Slave
    //      4. ACK del Slave
    // ========================================================================

    assign M_TIMEOUT_O[0] = master0_pending & master0_expired;
    assign M_TIMEOUT_O[1] = master1_pending & master1_expired;
    assign M_TIMEOUT_O[2] = master2_pending & master2_expired;
    assign M_TIMEOUT_O[3] = master3_pending & master3_expired;


    assign M_ERR_O[0] =
        master0_pending &
        (master0_expired | master0_decode_error | fabric_err[0]);

    assign M_ERR_O[1] =
        master1_pending &
        (master1_expired | master1_decode_error | fabric_err[1]);

    assign M_ERR_O[2] =
        master2_pending &
        (master2_expired | master2_decode_error | fabric_err[2]);

    assign M_ERR_O[3] =
        master3_pending &
        (master3_expired | master3_decode_error | fabric_err[3]);


    assign M_ACK_O[0] =
        master0_pending &
        ~master0_expired &
        ~master0_decode_error &
        fabric_ack[0] &
        ~fabric_err[0];

    assign M_ACK_O[1] =
        master1_pending &
        ~master1_expired &
        ~master1_decode_error &
        fabric_ack[1] &
        ~fabric_err[1];

    assign M_ACK_O[2] =
        master2_pending &
        ~master2_expired &
        ~master2_decode_error &
        fabric_ack[2] &
        ~fabric_err[2];

    assign M_ACK_O[3] =
        master3_pending &
        ~master3_expired &
        ~master3_decode_error &
        fabric_ack[3] &
        ~fabric_err[3];


    assign M_DAT_O[31:0] =
        (master0_pending & ~master0_expired & ~master0_decode_error) ?
        fabric_read_data[31:0] :
        32'd0;

    assign M_DAT_O[63:32] =
        (master1_pending & ~master1_expired & ~master1_decode_error) ?
        fabric_read_data[63:32] :
        32'd0;

    assign M_DAT_O[95:64] =
        (master2_pending & ~master2_expired & ~master2_decode_error) ?
        fabric_read_data[95:64] :
        32'd0;

    assign M_DAT_O[127:96] =
        (master3_pending & ~master3_expired & ~master3_decode_error) ?
        fabric_read_data[127:96] :
        32'd0;


    // ========================================================================
    //  Estado de transaccion - Master 0
    // ========================================================================

    always @(posedge CLK_I) begin

        if (RST_I) begin

            master0_finished <= 1'b0;
            master0_started  <= 1'b0;
            master0_age      <= 11'd0;

        end else if (!M_CYC_I[0]) begin

            master0_finished <= 1'b0;
            master0_started  <= 1'b0;
            master0_age      <= 11'd0;

        end else if (!master0_finished) begin

            if (M_ACK_O[0] || M_ERR_O[0]) begin

                master0_finished <= 1'b1;
                master0_started  <= 1'b0;

            end else if (master0_started || M_STB_I[0]) begin

                master0_started <= 1'b1;

                if (!master0_age[10])
                    master0_age <= master0_age + 11'd1;

            end

        end

    end


    // ========================================================================
    //  Estado de transaccion - Master 1
    // ========================================================================

    always @(posedge CLK_I) begin

        if (RST_I) begin

            master1_finished <= 1'b0;
            master1_started  <= 1'b0;
            master1_age      <= 11'd0;

        end else if (!M_CYC_I[1]) begin

            master1_finished <= 1'b0;
            master1_started  <= 1'b0;
            master1_age      <= 11'd0;

        end else if (!master1_finished) begin

            if (M_ACK_O[1] || M_ERR_O[1]) begin

                master1_finished <= 1'b1;
                master1_started  <= 1'b0;

            end else if (master1_started || M_STB_I[1]) begin

                master1_started <= 1'b1;

                if (!master1_age[10])
                    master1_age <= master1_age + 11'd1;

            end

        end

    end


    // ========================================================================
    //  Estado de transaccion - Master 2
    // ========================================================================

    always @(posedge CLK_I) begin

        if (RST_I) begin

            master2_finished <= 1'b0;
            master2_started  <= 1'b0;
            master2_age      <= 11'd0;

        end else if (!M_CYC_I[2]) begin

            master2_finished <= 1'b0;
            master2_started  <= 1'b0;
            master2_age      <= 11'd0;

        end else if (!master2_finished) begin

            if (M_ACK_O[2] || M_ERR_O[2]) begin

                master2_finished <= 1'b1;
                master2_started  <= 1'b0;

            end else if (master2_started || M_STB_I[2]) begin

                master2_started <= 1'b1;

                if (!master2_age[10])
                    master2_age <= master2_age + 11'd1;

            end

        end

    end


    // ========================================================================
    //  Estado de transaccion - Master 3
    // ========================================================================

    always @(posedge CLK_I) begin

        if (RST_I) begin

            master3_finished <= 1'b0;
            master3_started  <= 1'b0;
            master3_age      <= 11'd0;

        end else if (!M_CYC_I[3]) begin

            master3_finished <= 1'b0;
            master3_started  <= 1'b0;
            master3_age      <= 11'd0;

        end else if (!master3_finished) begin

            if (M_ACK_O[3] || M_ERR_O[3]) begin

                master3_finished <= 1'b1;
                master3_started  <= 1'b0;

            end else if (master3_started || M_STB_I[3]) begin

                master3_started <= 1'b1;

                if (!master3_age[10])
                    master3_age <= master3_age + 11'd1;

            end

        end

    end

endmodule

`default_nettype wire
