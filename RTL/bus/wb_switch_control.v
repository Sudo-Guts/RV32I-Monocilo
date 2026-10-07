`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Wishbone Switch Control
 * ----------------------------------------------------------------------------
 *  Controlador fijo:
 *
 *      - 4 Masters
 *      - 4 Slaves
 *      - 2 canales dinamicos
 *
 *  Ningun canal pertenece permanentemente a un Master o a un Slave.
 *  Cada canal registra:
 *
 *      CH_VALID
 *      CH_MASTER_SEL[1:0]
 *      CH_SLAVE_SEL[1:0]
 *
 *  Una conexion permanece estable hasta que el Master conectado activa
 *  M_RELEASE_I. Retirar M_REQ_I, por ejemplo durante una pausa de STB, no
 *  libera el canal.
 *
 *  Arbitraje:
 *
 *      1. Cada Slave elige un Master mediante round-robin propio.
 *      2. Si existen mas Slaves ganadores que canales libres, un round-robin
 *         global entre Slaves elige cuales reciben canal.
 *      3. Un Master ocupa como maximo un canal.
 *      4. Un Slave es destino de como maximo un canal.
 *
 *  El Master que libera una conexion no puede readquirir un canal en el mismo
 *  flanco. El crossbar se encarga por separado del ciclo de rearme del Slave.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ============================================================================
 */

module wb_switch_control (

    input wire CLK_I,
    input wire RST_I,

    // ------------------------------------------------------------------------
    //  Solicitudes de M0..M3 y destino ya decodificado
    // ------------------------------------------------------------------------
    input wire [3:0] M_REQ_I,
    input wire [3:0] M_TARGET_VALID_I,
    input wire [7:0] M_TARGET_I,
    input wire [3:0] M_RELEASE_I,

    // ------------------------------------------------------------------------
    //  Estado registrado de CH0 y CH1
    // ------------------------------------------------------------------------
    output reg [1:0] CH_VALID_O,
    output reg [3:0] CH_MASTER_SEL_O,
    output reg [3:0] CH_SLAVE_SEL_O

);

    // ========================================================================
    //  Destino solicitado por cada Master
    // ========================================================================

    wire [1:0] master0_target = M_TARGET_I[1:0];
    wire [1:0] master1_target = M_TARGET_I[3:2];
    wire [1:0] master2_target = M_TARGET_I[5:4];
    wire [1:0] master3_target = M_TARGET_I[7:6];


    // ========================================================================
    //  Asignacion actualmente registrada en cada canal
    // ========================================================================

    wire [1:0] channel0_master = CH_MASTER_SEL_O[1:0];
    wire [1:0] channel1_master = CH_MASTER_SEL_O[3:2];

    wire [1:0] channel0_slave = CH_SLAVE_SEL_O[1:0];
    wire [1:0] channel1_slave = CH_SLAVE_SEL_O[3:2];


    // ========================================================================
    //  MUX de M_RELEASE_I hacia cada canal
    // ========================================================================

    reg channel0_release;
    reg channel1_release;

    always @* begin

        channel0_release = 1'b0;

        case (channel0_master)
            2'd0: channel0_release = M_RELEASE_I[0];
            2'd1: channel0_release = M_RELEASE_I[1];
            2'd2: channel0_release = M_RELEASE_I[2];
            2'd3: channel0_release = M_RELEASE_I[3];
            default: channel0_release = 1'b0;
        endcase

    end

    always @* begin

        channel1_release = 1'b0;

        case (channel1_master)
            2'd0: channel1_release = M_RELEASE_I[0];
            2'd1: channel1_release = M_RELEASE_I[1];
            2'd2: channel1_release = M_RELEASE_I[2];
            2'd3: channel1_release = M_RELEASE_I[3];
            default: channel1_release = 1'b0;
        endcase

    end


    // ========================================================================
    //  Conexiones que sobreviven al siguiente flanco
    // ========================================================================

    wire keep_channel0 = CH_VALID_O[0] & ~channel0_release;
    wire keep_channel1 = CH_VALID_O[1] & ~channel1_release;

    wire channel0_free = ~keep_channel0;
    wire channel1_free = ~keep_channel1;


    // ========================================================================
    //  Recursos ocupados por conexiones conservadas
    // ------------------------------------------------------------------------
    //  Una conexion liberada deja de reservar Master y Slave en esta decision.
    // ========================================================================

    wire master0_busy =
        (keep_channel0 & (channel0_master == 2'd0)) |
        (keep_channel1 & (channel1_master == 2'd0));

    wire master1_busy =
        (keep_channel0 & (channel0_master == 2'd1)) |
        (keep_channel1 & (channel1_master == 2'd1));

    wire master2_busy =
        (keep_channel0 & (channel0_master == 2'd2)) |
        (keep_channel1 & (channel1_master == 2'd2));

    wire master3_busy =
        (keep_channel0 & (channel0_master == 2'd3)) |
        (keep_channel1 & (channel1_master == 2'd3));


    wire slave0_busy =
        (keep_channel0 & (channel0_slave == 2'd0)) |
        (keep_channel1 & (channel1_slave == 2'd0));

    wire slave1_busy =
        (keep_channel0 & (channel0_slave == 2'd1)) |
        (keep_channel1 & (channel1_slave == 2'd1));

    wire slave2_busy =
        (keep_channel0 & (channel0_slave == 2'd2)) |
        (keep_channel1 & (channel1_slave == 2'd2));

    wire slave3_busy =
        (keep_channel0 & (channel0_slave == 2'd3)) |
        (keep_channel1 & (channel1_slave == 2'd3));


    // ========================================================================
    //  Masters elegibles para una nueva conexion
    // ------------------------------------------------------------------------
    //  Un Master que libera no puede readquirir en el mismo flanco.
    // ========================================================================

    wire master0_can_request =
        M_REQ_I[0] & M_TARGET_VALID_I[0] & ~M_RELEASE_I[0] & ~master0_busy;

    wire master1_can_request =
        M_REQ_I[1] & M_TARGET_VALID_I[1] & ~M_RELEASE_I[1] & ~master1_busy;

    wire master2_can_request =
        M_REQ_I[2] & M_TARGET_VALID_I[2] & ~M_RELEASE_I[2] & ~master2_busy;

    wire master3_can_request =
        M_REQ_I[3] & M_TARGET_VALID_I[3] & ~M_RELEASE_I[3] & ~master3_busy;


    // ========================================================================
    //  Matriz fija de solicitudes Master -> Slave
    // ========================================================================

    wire slave0_request_master0 =
        master0_can_request & ~slave0_busy & (master0_target == 2'd0);
    wire slave0_request_master1 =
        master1_can_request & ~slave0_busy & (master1_target == 2'd0);
    wire slave0_request_master2 =
        master2_can_request & ~slave0_busy & (master2_target == 2'd0);
    wire slave0_request_master3 =
        master3_can_request & ~slave0_busy & (master3_target == 2'd0);

    wire slave1_request_master0 =
        master0_can_request & ~slave1_busy & (master0_target == 2'd1);
    wire slave1_request_master1 =
        master1_can_request & ~slave1_busy & (master1_target == 2'd1);
    wire slave1_request_master2 =
        master2_can_request & ~slave1_busy & (master2_target == 2'd1);
    wire slave1_request_master3 =
        master3_can_request & ~slave1_busy & (master3_target == 2'd1);

    wire slave2_request_master0 =
        master0_can_request & ~slave2_busy & (master0_target == 2'd2);
    wire slave2_request_master1 =
        master1_can_request & ~slave2_busy & (master1_target == 2'd2);
    wire slave2_request_master2 =
        master2_can_request & ~slave2_busy & (master2_target == 2'd2);
    wire slave2_request_master3 =
        master3_can_request & ~slave2_busy & (master3_target == 2'd2);

    wire slave3_request_master0 =
        master0_can_request & ~slave3_busy & (master0_target == 2'd3);
    wire slave3_request_master1 =
        master1_can_request & ~slave3_busy & (master1_target == 2'd3);
    wire slave3_request_master2 =
        master2_can_request & ~slave3_busy & (master2_target == 2'd3);
    wire slave3_request_master3 =
        master3_can_request & ~slave3_busy & (master3_target == 2'd3);


    // ========================================================================
    //  Round-robin independiente de cada Slave
    // ------------------------------------------------------------------------
    //  El registro contiene el primer Master que debe probarse en la siguiente
    //  contencion por ese Slave.
    // ========================================================================

    reg [1:0] slave0_next_master;
    reg [1:0] slave1_next_master;
    reg [1:0] slave2_next_master;
    reg [1:0] slave3_next_master;

    reg       slave0_winner_valid;
    reg [1:0] slave0_winner_master;

    reg       slave1_winner_valid;
    reg [1:0] slave1_winner_master;

    reg       slave2_winner_valid;
    reg [1:0] slave2_winner_master;

    reg       slave3_winner_valid;
    reg [1:0] slave3_winner_master;


    // ------------------------------------------------------------------------
    //  Arbitro de S0
    // ------------------------------------------------------------------------

    always @* begin

        slave0_winner_valid  = 1'b0;
        slave0_winner_master = 2'd0;

        case (slave0_next_master)

            2'd0: begin
                if (slave0_request_master0) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd0;
                end else if (slave0_request_master1) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd1;
                end else if (slave0_request_master2) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd2;
                end else if (slave0_request_master3) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd3;
                end
            end

            2'd1: begin
                if (slave0_request_master1) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd1;
                end else if (slave0_request_master2) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd2;
                end else if (slave0_request_master3) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd3;
                end else if (slave0_request_master0) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd0;
                end
            end

            2'd2: begin
                if (slave0_request_master2) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd2;
                end else if (slave0_request_master3) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd3;
                end else if (slave0_request_master0) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd0;
                end else if (slave0_request_master1) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd1;
                end
            end

            2'd3: begin
                if (slave0_request_master3) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd3;
                end else if (slave0_request_master0) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd0;
                end else if (slave0_request_master1) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd1;
                end else if (slave0_request_master2) begin
                    slave0_winner_valid = 1'b1; slave0_winner_master = 2'd2;
                end
            end

            default: begin
            end

        endcase

    end


    // ------------------------------------------------------------------------
    //  Arbitro de S1
    // ------------------------------------------------------------------------

    always @* begin

        slave1_winner_valid  = 1'b0;
        slave1_winner_master = 2'd0;

        case (slave1_next_master)

            2'd0: begin
                if (slave1_request_master0) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd0;
                end else if (slave1_request_master1) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd1;
                end else if (slave1_request_master2) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd2;
                end else if (slave1_request_master3) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd3;
                end
            end

            2'd1: begin
                if (slave1_request_master1) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd1;
                end else if (slave1_request_master2) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd2;
                end else if (slave1_request_master3) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd3;
                end else if (slave1_request_master0) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd0;
                end
            end

            2'd2: begin
                if (slave1_request_master2) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd2;
                end else if (slave1_request_master3) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd3;
                end else if (slave1_request_master0) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd0;
                end else if (slave1_request_master1) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd1;
                end
            end

            2'd3: begin
                if (slave1_request_master3) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd3;
                end else if (slave1_request_master0) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd0;
                end else if (slave1_request_master1) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd1;
                end else if (slave1_request_master2) begin
                    slave1_winner_valid = 1'b1; slave1_winner_master = 2'd2;
                end
            end

            default: begin
            end

        endcase

    end


    // ------------------------------------------------------------------------
    //  Arbitro de S2
    // ------------------------------------------------------------------------

    always @* begin

        slave2_winner_valid  = 1'b0;
        slave2_winner_master = 2'd0;

        case (slave2_next_master)

            2'd0: begin
                if (slave2_request_master0) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd0;
                end else if (slave2_request_master1) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd1;
                end else if (slave2_request_master2) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd2;
                end else if (slave2_request_master3) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd3;
                end
            end

            2'd1: begin
                if (slave2_request_master1) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd1;
                end else if (slave2_request_master2) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd2;
                end else if (slave2_request_master3) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd3;
                end else if (slave2_request_master0) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd0;
                end
            end

            2'd2: begin
                if (slave2_request_master2) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd2;
                end else if (slave2_request_master3) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd3;
                end else if (slave2_request_master0) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd0;
                end else if (slave2_request_master1) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd1;
                end
            end

            2'd3: begin
                if (slave2_request_master3) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd3;
                end else if (slave2_request_master0) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd0;
                end else if (slave2_request_master1) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd1;
                end else if (slave2_request_master2) begin
                    slave2_winner_valid = 1'b1; slave2_winner_master = 2'd2;
                end
            end

            default: begin
            end

        endcase

    end


    // ------------------------------------------------------------------------
    //  Arbitro de S3
    // ------------------------------------------------------------------------

    always @* begin

        slave3_winner_valid  = 1'b0;
        slave3_winner_master = 2'd0;

        case (slave3_next_master)

            2'd0: begin
                if (slave3_request_master0) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd0;
                end else if (slave3_request_master1) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd1;
                end else if (slave3_request_master2) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd2;
                end else if (slave3_request_master3) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd3;
                end
            end

            2'd1: begin
                if (slave3_request_master1) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd1;
                end else if (slave3_request_master2) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd2;
                end else if (slave3_request_master3) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd3;
                end else if (slave3_request_master0) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd0;
                end
            end

            2'd2: begin
                if (slave3_request_master2) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd2;
                end else if (slave3_request_master3) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd3;
                end else if (slave3_request_master0) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd0;
                end else if (slave3_request_master1) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd1;
                end
            end

            2'd3: begin
                if (slave3_request_master3) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd3;
                end else if (slave3_request_master0) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd0;
                end else if (slave3_request_master1) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd1;
                end else if (slave3_request_master2) begin
                    slave3_winner_valid = 1'b1; slave3_winner_master = 2'd2;
                end
            end

            default: begin
            end

        endcase

    end


    // ========================================================================
    //  Round-robin global entre Slaves ganadores
    // ------------------------------------------------------------------------
    //  Se seleccionan como maximo dos Slaves, porque existen dos canales.
    // ========================================================================

    reg [1:0] next_slave;

    reg       first_winner_valid;
    reg [1:0] first_winner_slave;
    reg [1:0] first_winner_master;

    reg       second_winner_valid;
    reg [1:0] second_winner_slave;
    reg [1:0] second_winner_master;


    always @* begin

        first_winner_valid   = 1'b0;
        first_winner_slave   = 2'd0;
        first_winner_master  = 2'd0;

        second_winner_valid  = 1'b0;
        second_winner_slave  = 2'd0;
        second_winner_master = 2'd0;

        case (next_slave)

            // Orden: S0 -> S1 -> S2 -> S3
            2'd0: begin

                if (slave0_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd0;
                    first_winner_master = slave0_winner_master;
                end else if (slave1_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd1;
                    first_winner_master = slave1_winner_master;
                end else if (slave2_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd2;
                    first_winner_master = slave2_winner_master;
                end else if (slave3_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd3;
                    first_winner_master = slave3_winner_master;
                end

                if (slave0_winner_valid) begin
                    if (slave1_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd1;
                        second_winner_master = slave1_winner_master;
                    end else if (slave2_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd2;
                        second_winner_master = slave2_winner_master;
                    end else if (slave3_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd3;
                        second_winner_master = slave3_winner_master;
                    end
                end else if (slave1_winner_valid) begin
                    if (slave2_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd2;
                        second_winner_master = slave2_winner_master;
                    end else if (slave3_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd3;
                        second_winner_master = slave3_winner_master;
                    end
                end else if (slave2_winner_valid && slave3_winner_valid) begin
                    second_winner_valid  = 1'b1;
                    second_winner_slave  = 2'd3;
                    second_winner_master = slave3_winner_master;
                end

            end


            // Orden: S1 -> S2 -> S3 -> S0
            2'd1: begin

                if (slave1_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd1;
                    first_winner_master = slave1_winner_master;
                end else if (slave2_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd2;
                    first_winner_master = slave2_winner_master;
                end else if (slave3_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd3;
                    first_winner_master = slave3_winner_master;
                end else if (slave0_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd0;
                    first_winner_master = slave0_winner_master;
                end

                if (slave1_winner_valid) begin
                    if (slave2_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd2;
                        second_winner_master = slave2_winner_master;
                    end else if (slave3_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd3;
                        second_winner_master = slave3_winner_master;
                    end else if (slave0_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd0;
                        second_winner_master = slave0_winner_master;
                    end
                end else if (slave2_winner_valid) begin
                    if (slave3_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd3;
                        second_winner_master = slave3_winner_master;
                    end else if (slave0_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd0;
                        second_winner_master = slave0_winner_master;
                    end
                end else if (slave3_winner_valid && slave0_winner_valid) begin
                    second_winner_valid  = 1'b1;
                    second_winner_slave  = 2'd0;
                    second_winner_master = slave0_winner_master;
                end

            end


            // Orden: S2 -> S3 -> S0 -> S1
            2'd2: begin

                if (slave2_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd2;
                    first_winner_master = slave2_winner_master;
                end else if (slave3_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd3;
                    first_winner_master = slave3_winner_master;
                end else if (slave0_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd0;
                    first_winner_master = slave0_winner_master;
                end else if (slave1_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd1;
                    first_winner_master = slave1_winner_master;
                end

                if (slave2_winner_valid) begin
                    if (slave3_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd3;
                        second_winner_master = slave3_winner_master;
                    end else if (slave0_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd0;
                        second_winner_master = slave0_winner_master;
                    end else if (slave1_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd1;
                        second_winner_master = slave1_winner_master;
                    end
                end else if (slave3_winner_valid) begin
                    if (slave0_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd0;
                        second_winner_master = slave0_winner_master;
                    end else if (slave1_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd1;
                        second_winner_master = slave1_winner_master;
                    end
                end else if (slave0_winner_valid && slave1_winner_valid) begin
                    second_winner_valid  = 1'b1;
                    second_winner_slave  = 2'd1;
                    second_winner_master = slave1_winner_master;
                end

            end


            // Orden: S3 -> S0 -> S1 -> S2
            2'd3: begin

                if (slave3_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd3;
                    first_winner_master = slave3_winner_master;
                end else if (slave0_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd0;
                    first_winner_master = slave0_winner_master;
                end else if (slave1_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd1;
                    first_winner_master = slave1_winner_master;
                end else if (slave2_winner_valid) begin
                    first_winner_valid  = 1'b1;
                    first_winner_slave  = 2'd2;
                    first_winner_master = slave2_winner_master;
                end

                if (slave3_winner_valid) begin
                    if (slave0_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd0;
                        second_winner_master = slave0_winner_master;
                    end else if (slave1_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd1;
                        second_winner_master = slave1_winner_master;
                    end else if (slave2_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd2;
                        second_winner_master = slave2_winner_master;
                    end
                end else if (slave0_winner_valid) begin
                    if (slave1_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd1;
                        second_winner_master = slave1_winner_master;
                    end else if (slave2_winner_valid) begin
                        second_winner_valid  = 1'b1;
                        second_winner_slave  = 2'd2;
                        second_winner_master = slave2_winner_master;
                    end
                end else if (slave1_winner_valid && slave2_winner_valid) begin
                    second_winner_valid  = 1'b1;
                    second_winner_slave  = 2'd2;
                    second_winner_master = slave2_winner_master;
                end

            end

            default: begin
            end

        endcase

    end


    // ========================================================================
    //  Asignacion de los ganadores a los canales libres
    // ------------------------------------------------------------------------
    //  CH0 tiene prioridad fisica para recibir al primer ganador cuando ambos
    //  canales estan libres. Esto no afecta el round-robin Master/Slave.
    // ========================================================================

    reg [1:0] channel_valid_next;
    reg [3:0] channel_master_next;
    reg [3:0] channel_slave_next;

    reg grant_first_winner;
    reg grant_second_winner;


    always @* begin

        channel_valid_next  = CH_VALID_O;
        channel_master_next = CH_MASTER_SEL_O;
        channel_slave_next  = CH_SLAVE_SEL_O;

        grant_first_winner  = 1'b0;
        grant_second_winner = 1'b0;


        // Una conexion liberada desaparece del banco de registros.
        if (!keep_channel0) begin
            channel_valid_next[0]    = 1'b0;
            channel_master_next[1:0] = 2'd0;
            channel_slave_next[1:0]  = 2'd0;
        end

        if (!keep_channel1) begin
            channel_valid_next[1]    = 1'b0;
            channel_master_next[3:2] = 2'd0;
            channel_slave_next[3:2]  = 2'd0;
        end


        // Primer ganador.
        if (first_winner_valid) begin

            if (channel0_free) begin

                channel_valid_next[0]    = 1'b1;
                channel_master_next[1:0] = first_winner_master;
                channel_slave_next[1:0]  = first_winner_slave;
                grant_first_winner       = 1'b1;

            end else if (channel1_free) begin

                channel_valid_next[1]    = 1'b1;
                channel_master_next[3:2] = first_winner_master;
                channel_slave_next[3:2]  = first_winner_slave;
                grant_first_winner       = 1'b1;

            end

        end


        // Segundo ganador: solo existe espacio si ambos canales estaban libres.
        if (second_winner_valid && channel0_free && channel1_free) begin

            channel_valid_next[1]    = 1'b1;
            channel_master_next[3:2] = second_winner_master;
            channel_slave_next[3:2]  = second_winner_slave;
            grant_second_winner      = 1'b1;

        end

    end


    // ========================================================================
    //  Banco de registros de conexion
    // ========================================================================

    always @(posedge CLK_I) begin

        if (RST_I) begin

            CH_VALID_O      <= 2'b00;
            CH_MASTER_SEL_O <= 4'b0000;
            CH_SLAVE_SEL_O  <= 4'b0000;

        end else begin

            CH_VALID_O      <= channel_valid_next;
            CH_MASTER_SEL_O <= channel_master_next;
            CH_SLAVE_SEL_O  <= channel_slave_next;

        end

    end


    // ========================================================================
    //  Actualizacion del round-robin
    // ========================================================================

    always @(posedge CLK_I) begin

        if (RST_I) begin

            slave0_next_master <= 2'd0;
            slave1_next_master <= 2'd0;
            slave2_next_master <= 2'd0;
            slave3_next_master <= 2'd0;
            next_slave         <= 2'd0;

        end else begin

            // ---------------------------------------------------------------
            //  Round-robin por Slave: el siguiente turno comienza despues del
            //  Master que realmente obtuvo ese Slave.
            // ---------------------------------------------------------------

            if (grant_first_winner && (first_winner_slave == 2'd0))
                slave0_next_master <= first_winner_master + 2'd1;
            else if (grant_second_winner && (second_winner_slave == 2'd0))
                slave0_next_master <= second_winner_master + 2'd1;

            if (grant_first_winner && (first_winner_slave == 2'd1))
                slave1_next_master <= first_winner_master + 2'd1;
            else if (grant_second_winner && (second_winner_slave == 2'd1))
                slave1_next_master <= second_winner_master + 2'd1;

            if (grant_first_winner && (first_winner_slave == 2'd2))
                slave2_next_master <= first_winner_master + 2'd1;
            else if (grant_second_winner && (second_winner_slave == 2'd2))
                slave2_next_master <= second_winner_master + 2'd1;

            if (grant_first_winner && (first_winner_slave == 2'd3))
                slave3_next_master <= first_winner_master + 2'd1;
            else if (grant_second_winner && (second_winner_slave == 2'd3))
                slave3_next_master <= second_winner_master + 2'd1;


            // ---------------------------------------------------------------
            //  Round-robin global entre Slaves.
            //  Si hubo dos concesiones, continua despues del segundo ganador.
            // ---------------------------------------------------------------

            if (grant_second_winner)
                next_slave <= second_winner_slave + 2'd1;
            else if (grant_first_winner)
                next_slave <= first_winner_slave + 2'd1;

        end

    end

endmodule

`default_nettype wire
