`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Testbench - wb_switch_control
 * ----------------------------------------------------------------------------
 *  Control secuencial Wishbone: 4 Masters / 4 Slaves / 2 canales dinamicos.
 *
 *  Scoreboard independiente:
 *      1) conserva rutas que no se liberan;
 *      2) calcula elegibilidad de Masters y Slaves;
 *      3) aplica round-robin por Slave;
 *      4) asigna hasta dos Slaves en orden round-robin global;
 *      5) compara el resultado en cada flanco de subida.
 *
 *  Verifica tambien que nunca se duplique un Master o un Slave entre canales.
 *  No implementa el rearme de Slaves: esa responsabilidad es de wb_crossbar.
 * ============================================================================
 */

module wb_switch_control_tb;

    reg CLK_I;
    reg RST_I;

    reg [3:0] M_REQ_I;
    reg [3:0] M_TARGET_VALID_I;
    reg [7:0] M_TARGET_I;
    reg [3:0] M_RELEASE_I;

    wire [1:0] CH_VALID_O;
    wire [3:0] CH_MASTER_SEL_O;
    wire [3:0] CH_SLAVE_SEL_O;

    reg [1:0] expected_valid;
    reg [3:0] expected_master;
    reg [3:0] expected_slave;

    integer rr_master [0:3];
    integer rr_slave;

    integer used_master [0:3];
    integer used_slave [0:3];
    integer winner [0:3];

    reg [1:0] next_valid;
    reg [3:0] next_master;
    reg [3:0] next_slave;

    integer tests;
    integer errors;
    integer i;
    integer j;
    integer master;
    integer slave;
    integer mask;
    integer target_pattern;
    integer round_index;
    integer selected_master;
    integer selected_slave;
    integer granted;
    integer chosen_channel;
    integer sequence_number;

    reg [31:0] rng;
    reg [3:0] random_req;
    reg [3:0] random_valid;
    reg [7:0] random_target;
    reg [3:0] random_release;

    wb_switch_control dut (

        .CLK_I            (CLK_I),
        .RST_I            (RST_I),

        .M_REQ_I          (M_REQ_I),
        .M_TARGET_VALID_I (M_TARGET_VALID_I),
        .M_TARGET_I       (M_TARGET_I),
        .M_RELEASE_I      (M_RELEASE_I),

        .CH_VALID_O       (CH_VALID_O),
        .CH_MASTER_SEL_O  (CH_MASTER_SEL_O),
        .CH_SLAVE_SEL_O   (CH_SLAVE_SEL_O)

    );


    always #5 CLK_I = ~CLK_I;


    // ========================================================================
    //  MODELO DE REFERENCIA
    // ========================================================================

    task model_step;

        begin

            if (RST_I) begin

                expected_valid  = 2'b00;
                expected_master = 4'b0000;
                expected_slave  = 4'b0000;

                for (i = 0; i < 4; i = i + 1)
                    rr_master[i] = 0;

                rr_slave = 0;

            end else begin

                next_valid  = expected_valid;
                next_master = expected_master;
                next_slave  = expected_slave;

                for (i = 0; i < 4; i = i + 1) begin
                    used_master[i] = 0;
                    used_slave[i]  = 0;
                    winner[i]      = -1;
                end

                // Retener solo conexiones cuyo Master no libera.
                for (i = 0; i < 2; i = i + 1) begin

                    selected_master = expected_master[i*2 +: 2];
                    selected_slave  = expected_slave[i*2 +: 2];

                    if (
                        expected_valid[i] &&
                        !M_RELEASE_I[selected_master]
                    ) begin

                        used_master[selected_master] = 1;
                        used_slave[selected_slave]   = 1;

                    end else begin

                        next_valid[i]             = 1'b0;
                        next_master[i*2 +: 2]    = 2'd0;
                        next_slave[i*2 +: 2]     = 2'd0;

                    end

                end

                // Cada Slave elige un Master elegible, empezando por su
                // puntero independiente de round-robin.
                for (slave = 0; slave < 4; slave = slave + 1) begin

                    if (!used_slave[slave]) begin

                        for (j = 0; j < 4; j = j + 1) begin

                            master = (rr_master[slave] + j) % 4;

                            if (
                                winner[slave] < 0 &&
                                M_REQ_I[master] &&
                                M_TARGET_VALID_I[master] &&
                                !M_RELEASE_I[master] &&
                                !used_master[master] &&
                                (M_TARGET_I[master*2 +: 2] == slave)
                            ) begin

                                winner[slave] = master;

                            end

                        end

                    end

                end

                // Repartir hasta dos concesiones siguiendo el orden
                // global entre Slaves. CH0 es el primero si ambos libres.
                granted = 0;

                for (j = 0; j < 4; j = j + 1) begin

                    selected_slave = (rr_slave + j) % 4;

                    if (winner[selected_slave] >= 0 && granted < 2) begin

                        chosen_channel = -1;

                        if (!next_valid[0])
                            chosen_channel = 0;
                        else if (!next_valid[1])
                            chosen_channel = 1;

                        if (chosen_channel >= 0) begin

                            next_valid[chosen_channel] = 1'b1;

                            next_master[chosen_channel*2 +: 2] =
                                winner[selected_slave];

                            next_slave[chosen_channel*2 +: 2] =
                                selected_slave;

                            rr_master[selected_slave] =
                                (winner[selected_slave] + 1) % 4;

                            // El ultimo Slave concedido determina el
                            // siguiente punto de partida global.
                            rr_slave = (selected_slave + 1) % 4;

                            granted = granted + 1;

                        end

                    end

                end

                expected_valid  = next_valid;
                expected_master = next_master;
                expected_slave  = next_slave;

            end

        end

    endtask


    // ========================================================================
    //  COMPARACION EN EL FLANCO DE RELOJ
    // ========================================================================

    task step;

        input [3:0] request_mask;
        input [3:0] valid_mask;
        input [7:0] target_vector;
        input [3:0] release_mask;
        input       reset_value;

        begin

            @(negedge CLK_I);

            M_REQ_I          = request_mask;
            M_TARGET_VALID_I = valid_mask;
            M_TARGET_I       = target_vector;
            M_RELEASE_I      = release_mask;
            RST_I            = reset_value;

            model_step();

            @(posedge CLK_I);
            #1;

            tests = tests + 1;

            if (
                (CH_VALID_O      !== expected_valid)  ||
                (CH_MASTER_SEL_O !== expected_master) ||
                (CH_SLAVE_SEL_O  !== expected_slave)
            ) begin

                errors = errors + 1;

                $display(
                    "[FAIL] test=%0d req=%b valid=%b target=%h release=%b reset=%b",
                    tests, request_mask, valid_mask, target_vector,
                    release_mask, reset_value
                );
                $display(
                    "  expected valid=%b master=%h slave=%h",
                    expected_valid, expected_master, expected_slave
                );
                $display(
                    "  actual   valid=%b master=%h slave=%h",
                    CH_VALID_O, CH_MASTER_SEL_O, CH_SLAVE_SEL_O
                );

                $fatal(1, "wb_switch_control: arbitraje incorrecto");

            end

            if (CH_VALID_O === 2'b11) begin

                if (
                    (CH_MASTER_SEL_O[1:0] === CH_MASTER_SEL_O[3:2]) ||
                    (CH_SLAVE_SEL_O[1:0]  === CH_SLAVE_SEL_O[3:2])
                ) begin

                    errors = errors + 1;

                    $fatal(
                        1,
                        "wb_switch_control: Master/Slave duplicado entre canales"
                    );

                end

            end

        end

    endtask


    task expect_channel;

        input integer channel_index;
        input integer master_index;
        input integer slave_index;

        begin

            if (
                (CH_VALID_O[channel_index] !== 1'b1) ||
                (CH_MASTER_SEL_O[channel_index*2 +: 2] !== master_index[1:0]) ||
                (CH_SLAVE_SEL_O[channel_index*2 +: 2]  !== slave_index[1:0])
            ) begin

                $fatal(
                    1,
                    "Expected CH%0d = M%0d -> S%0d",
                    channel_index, master_index, slave_index
                );

            end

        end

    endtask


    // ========================================================================
    //  SECUENCIA DE PRUEBAS
    // ========================================================================

    initial begin

        CLK_I            = 1'b0;
        RST_I            = 1'b1;
        M_REQ_I          = 4'b0000;
        M_TARGET_VALID_I = 4'b0000;
        M_TARGET_I       = 8'd0;
        M_RELEASE_I      = 4'b0000;

        tests  = 0;
        errors = 0;
        rng    = 32'h1BAD_F00D;

        $dumpfile("SIM/out/wb_switch_control_tb.vcd");
        $dumpvars(0, wb_switch_control_tb);

        $display("============================================================");
        $display(" wb_switch_control_tb");
        $display("============================================================");


        // --------------------------------------------------------------------
        //  Reset, peticiones invalidas y reposo.
        // --------------------------------------------------------------------

        step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);
        step(4'hF, 4'h0, 8'hE4, 4'h0, 1'b0);

        if (CH_VALID_O !== 2'b00)
            $fatal(1, "Master con TARGET_VALID=0 obtuvo canal");


        // --------------------------------------------------------------------
        //  Barrido de rutas simples (16 combinaciones):
        //  solicitud, pausa de M_REQ, liberacion.
        // --------------------------------------------------------------------

        for (master = 0; master < 4; master = master + 1) begin

            for (slave = 0; slave < 4; slave = slave + 1) begin

                step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);

                step(
                    (4'b0001 << master),
                    4'hF,
                    (8'h01 << (master*2)) * slave,
                    4'h0,
                    1'b0
                );

                expect_channel(0, master, slave);

                // M_REQ=0 no debe liberar la ruta.
                step(4'h0, 4'hF, 8'h00, 4'h0, 1'b0);
                expect_channel(0, master, slave);

                step(4'h0, 4'hF, 8'h00, (4'b0001 << master), 1'b0);

                if (CH_VALID_O !== 2'b00)
                    $fatal(1, "El canal no se libero");

            end

        end


        // --------------------------------------------------------------------
        //  Dos canales concurrentes, conservacion del canal ocupado y
        //  reutilizacion del otro al liberar su Master.
        // --------------------------------------------------------------------

        step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);

        // M1 -> S2.
        step(4'b0010, 4'hF, 8'h08, 4'h0, 1'b0);
        expect_channel(0, 1, 2);

        // M3 -> S0, solo CH1 esta libre.
        step(4'b1000, 4'hF, 8'h00, 4'h0, 1'b0);
        expect_channel(0, 1, 2);
        expect_channel(1, 3, 0);

        // M1 libera. M0 solicita S2. CH1 debe mantenerse.
        step(4'b0001, 4'hF, 8'h02, 4'b0010, 1'b0);
        expect_channel(0, 0, 2);
        expect_channel(1, 3, 0);


        // --------------------------------------------------------------------
        //  Un Master que libera no puede readquirir en el mismo flanco.
        // --------------------------------------------------------------------

        step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);
        step(4'b0001, 4'hF, 8'h00, 4'h0, 1'b0);
        expect_channel(0, 0, 0);

        step(4'b0001, 4'hF, 8'h00, 4'b0001, 1'b0);

        if (CH_VALID_O !== 2'b00)
            $fatal(1, "Master readquirio canal en flanco de liberacion");

        step(4'b0001, 4'hF, 8'h00, 4'h0, 1'b0);
        expect_channel(0, 0, 0);


        // --------------------------------------------------------------------
        //  Round-robin por Slave: 4 Masters compiten por cada uno de S0..S3.
        //  Repetir ocho adjudicaciones en orden M0, M1, M2, M3.
        // --------------------------------------------------------------------

        for (slave = 0; slave < 4; slave = slave + 1) begin

            step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);

            for (sequence_number = 0; sequence_number < 8;
                 sequence_number = sequence_number + 1) begin

                if (sequence_number == 0)
                    random_release = 4'h0;
                else
                    random_release =
                        (4'b0001 << ((sequence_number - 1) % 4));

                // 0x55 codifica S1 para los cuatro Masters.
                // 0xAA codifica S2; 0xFF codifica S3.
                step(
                    4'hF,
                    4'hF,
                    (8'h55 * slave),
                    random_release,
                    1'b0
                );

                expect_channel(0, (sequence_number % 4), slave);

            end

        end


        // --------------------------------------------------------------------
        //  Round-robin global:
        //  M0:S0, M1:S1, M2:S2 y M3:S3 compiten por dos canales.
        // --------------------------------------------------------------------

        step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);
        step(4'hF, 4'hF, 8'hE4, 4'h0, 1'b0);

        expect_channel(0, 0, 0);
        expect_channel(1, 1, 1);

        step(4'hF, 4'hF, 8'hE4, 4'b0011, 1'b0);

        expect_channel(0, 2, 2);
        expect_channel(1, 3, 3);

        step(4'hF, 4'hF, 8'hE4, 4'b1100, 1'b0);

        expect_channel(0, 0, 0);
        expect_channel(1, 1, 1);


        // --------------------------------------------------------------------
        //  Exhaustivo de una concesion desde reset:
        //  16 mascaras de peticion x 256 combinaciones de destinos.
        // --------------------------------------------------------------------

        for (mask = 0; mask < 16; mask = mask + 1) begin

            for (target_pattern = 0; target_pattern < 256;
                 target_pattern = target_pattern + 1) begin

                step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);
                step(mask[3:0], 4'hF, target_pattern[7:0], 4'h0, 1'b0);

            end

        end


        // --------------------------------------------------------------------
        //  Secuencias con estado: destinos, validaciones, solicitudes y
        //  liberaciones pseudoaleatorias reproducibles.
        // --------------------------------------------------------------------

        step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);

        for (round_index = 0; round_index < 2000;
             round_index = round_index + 1) begin

            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);

            random_req     = rng[3:0];
            random_valid   = rng[7:4];
            random_target  = rng[15:8];
            random_release = rng[19:16];

            if ((round_index % 251) == 250) begin
                step(4'h0, 4'h0, 8'h00, 4'h0, 1'b1);
            end else begin
                step(
                    random_req,
                    random_valid,
                    random_target,
                    random_release,
                    1'b0
                );
            end

        end


        $display("============================================================");
        $display(" Tests : %0d", tests);
        $display(" Errors: %0d", errors);

        if (errors == 0)
            $display(" [PASS] wb_switch_control_tb COMPLETO");
        else
            $display(" [FAIL] wb_switch_control_tb: %0d errores", errors);

        $display("============================================================");

        if (errors != 0)
            $fatal(1, "Fallos de controlador");

        $finish;

    end

    initial begin
        #1000000;
        $fatal(1, "Timeout de simulacion del testbench");
    end

endmodule

`default_nettype wire
