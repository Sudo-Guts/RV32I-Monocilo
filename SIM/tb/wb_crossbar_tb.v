`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Testbench - wb_crossbar
 * ----------------------------------------------------------------------------
 *  Pruebas de integracion del interconnect:
 *
 *      4 Masters / 4 Slaves / 2 canales dinamicos
 *      Wishbone Classic SINGLE
 *
 *  - Accesos read/write para cada Master/Slave
 *  - ACK, ERR y prioridad ERR sobre ACK
 *  - Errores de direccion no mapeada
 *  - Dos accesos en paralelo; cuatro peticiones para dos canales
 *  - Contencion por el mismo Slave y rearme entre propietarios
 *  - Pausa de STB conservando CYC
 *  - Cancelacion por CYC
 *  - Termino unico mientras CYC permanezca alto
 *  - Timeout exacto en 1024 ciclos; timeout durante pausa de STB
 *
 *  Slaves de prueba: una respuesta por ciclo CYC/STB, con bit served que
 *  se limpia solo al observar CYC=0 en un flanco. De este modo el propio
 *  modelo exige un rearme correcto al cambiar de propietario.
 * ============================================================================
 */

module wb_crossbar_tb;

    reg CLK_I;
    reg RST_I;

    reg  [127:0] M_ADR_I;
    reg  [127:0] M_DAT_I;
    reg  [15:0]  M_SEL_I;
    reg  [3:0]   M_WE_I;
    reg  [3:0]   M_CYC_I;
    reg  [3:0]   M_STB_I;

    wire [127:0] M_DAT_O;
    wire [3:0]   M_ACK_O;
    wire [3:0]   M_ERR_O;
    wire [3:0]   M_TIMEOUT_O;

    wire [127:0] S_ADR_O;
    wire [127:0] S_DAT_O;
    wire [15:0]  S_SEL_O;
    wire [3:0]   S_WE_O;
    wire [3:0]   S_CYC_O;
    wire [3:0]   S_STB_O;

    wire [127:0] S_DAT_I;
    reg  [3:0]   S_ACK_I;
    reg  [3:0]   S_ERR_I;

    // Dos bits por Slave:
    // 00 no responde; 01 ACK; 10 ERR; 11 ACK + ERR.
    reg [7:0] response_mode;
    reg [3:0] slave_served;

    integer checks;
    integer master_index;
    integer slave_index;
    integer pass_index;
    integer cycle_index;

    assign S_DAT_I = {
        32'hDADA_0003, 32'hDADA_0002,
        32'hDADA_0001, 32'hDADA_0000
    };

    wb_crossbar dut (

        .CLK_I      (CLK_I),
        .RST_I      (RST_I),

        .M_ADR_I    (M_ADR_I),
        .M_DAT_I    (M_DAT_I),
        .M_SEL_I    (M_SEL_I),
        .M_WE_I     (M_WE_I),
        .M_CYC_I    (M_CYC_I),
        .M_STB_I    (M_STB_I),

        .M_DAT_O    (M_DAT_O),
        .M_ACK_O    (M_ACK_O),
        .M_ERR_O    (M_ERR_O),
        .M_TIMEOUT_O(M_TIMEOUT_O),

        .S_ADR_O    (S_ADR_O),
        .S_DAT_O    (S_DAT_O),
        .S_SEL_O    (S_SEL_O),
        .S_WE_O     (S_WE_O),
        .S_CYC_O    (S_CYC_O),
        .S_STB_O    (S_STB_O),

        .S_DAT_I    (S_DAT_I),
        .S_ACK_I    (S_ACK_I),
        .S_ERR_I    (S_ERR_I)

    );

    always #5 CLK_I = ~CLK_I;


    // ========================================================================
    //  MODELO DE SLAVES CON RESPUESTA UNICA
    // ========================================================================

    integer response_index;
    integer served_index;

    always @* begin

        S_ACK_I = 4'b0000;
        S_ERR_I = 4'b0000;

        for (response_index = 0; response_index < 4;
             response_index = response_index + 1) begin

            if (
                S_CYC_O[response_index] &&
                S_STB_O[response_index] &&
                !slave_served[response_index]
            ) begin

                S_ACK_I[response_index] =
                    response_mode[response_index*2];

                S_ERR_I[response_index] =
                    response_mode[response_index*2 + 1];

            end

        end

    end

    always @(posedge CLK_I) begin

        if (RST_I) begin

            slave_served <= 4'b0000;

        end else begin

            for (served_index = 0; served_index < 4;
                 served_index = served_index + 1) begin

                if (!S_CYC_O[served_index]) begin

                    slave_served[served_index] <= 1'b0;

                end else if (
                    S_STB_O[served_index] &&
                    (S_ACK_I[served_index] || S_ERR_I[served_index])
                ) begin

                    slave_served[served_index] <= 1'b1;

                end

            end

        end

    end


    // ========================================================================
    //  COMPROBACIONES
    // ========================================================================

    task check_true;

        input condition;
        input [8*100-1:0] description;

        begin

            checks = checks + 1;

            if (condition !== 1'b1) begin

                $display("[FAIL] check=%0d: %0s", checks, description);
                $display(
                    "  M_ACK=%b M_ERR=%b TIMEOUT=%b S_CYC=%b S_STB=%b",
                    M_ACK_O, M_ERR_O, M_TIMEOUT_O, S_CYC_O, S_STB_O
                );

                $fatal(1, "wb_crossbar_tb fallo");

            end

        end

    endtask


    // Los selectores son internos; se observan solo para comprobar
    // invariantes arquitectonicas, no para generar las respuestas esperadas.
    always @(posedge CLK_I) begin

        #2;

        if (!RST_I) begin

            if (dut.channel_valid === 2'b11) begin

                check_true(
                    dut.channel_master[1:0] !== dut.channel_master[3:2],
                    "Dos canales no pueden compartir Master"
                );

                check_true(
                    dut.channel_slave[1:0] !== dut.channel_slave[3:2],
                    "Dos canales no pueden compartir Slave"
                );

            end

            check_true(
                (S_CYC_O[0] + S_CYC_O[1] +
                 S_CYC_O[2] + S_CYC_O[3]) <= 2,
                "No deben activarse mas de dos Slaves"
            );

            check_true(
                (M_ACK_O & M_ERR_O) === 4'b0000,
                "Un Master no debe recibir ACK y ERR a la vez"
            );

            check_true(
                (M_TIMEOUT_O & ~M_ERR_O) === 4'b0000,
                "TIMEOUT debe implicar ERR"
            );

        end

    end


    // ========================================================================
    //  ESTIMULOS Y RESET
    // ========================================================================

    task reset_design;

        begin

            @(negedge CLK_I);

            RST_I       = 1'b1;
            M_ADR_I     = 128'd0;
            M_DAT_I     = 128'd0;
            M_SEL_I     = 16'd0;
            M_WE_I      = 4'd0;
            M_CYC_I     = 4'd0;
            M_STB_I     = 4'd0;
            response_mode = 8'h55;

            repeat (2) @(posedge CLK_I);
            #1;

            @(negedge CLK_I);
            RST_I = 1'b0;

        end

    endtask


    task start_master;

        input integer m;
        input integer s;
        input write_enable;

        reg [31:0] address;

        begin

            case (s)

                0: address = 32'h0000_0040 + m*4;
                1: address = 32'h0001_0040 + m*4;
                2: address = 32'h1000_0040 + m*4;
                3: address = 32'h1000_1040 + m*4;

                default: address = 32'h2000_0000;

            endcase

            M_ADR_I[m*32 +: 32] = address;
            M_DAT_I[m*32 +: 32] = 32'hABCD_0000 + m*32'h101;
            M_SEL_I[m*4 +: 4]   = 4'hF - m;
            M_WE_I[m]           = write_enable;
            M_CYC_I[m]          = 1'b1;
            M_STB_I[m]          = 1'b1;

        end

    endtask


    task end_master;

        input integer m;

        begin

            M_CYC_I[m] = 1'b0;
            M_STB_I[m] = 1'b0;

        end

    endtask


    // ========================================================================
    //  ACCESO UNICO: 4 Masters x 4 Slaves, lectura y escritura
    // ========================================================================

    task run_single;

        input integer m;
        input integer s;
        input write_enable;
        input [1:0] mode;

        begin

            reset_design();
            response_mode[s*2 +: 2] = mode;

            @(negedge CLK_I);
            start_master(m, s, write_enable);

            @(posedge CLK_I);
            #1;

            check_true(
                S_CYC_O === (4'b0001 << s),
                "Solo debe activarse el Slave solicitado"
            );

            check_true(
                S_STB_O === (4'b0001 << s),
                "STB debe alcanzar solamente el Slave solicitado"
            );

            check_true(
                S_ADR_O[s*32 +: 32] === M_ADR_I[m*32 +: 32],
                "ADR no corresponde al Master seleccionado"
            );

            check_true(
                S_DAT_O[s*32 +: 32] === M_DAT_I[m*32 +: 32],
                "DAT de escritura se enruto incorrectamente"
            );

            check_true(
                S_SEL_O[s*4 +: 4] === M_SEL_I[m*4 +: 4] &&
                S_WE_O[s] === write_enable,
                "SEL o WE incorrectos"
            );

            check_true(
                M_DAT_O[m*32 +: 32] === S_DAT_I[s*32 +: 32],
                "DAT de lectura se enruto incorrectamente"
            );

            if (mode[1]) begin

                check_true(
                    M_ERR_O === (4'b0001 << m) &&
                    M_ACK_O === 4'b0000,
                    "ERR del Slave o prioridad ERR sobre ACK incorrecta"
                );

            end else begin

                check_true(
                    M_ACK_O === (4'b0001 << m) &&
                    M_ERR_O === 4'b0000,
                    "ACK no llego exclusivamente al Master solicitado"
                );

            end

            check_true(
                M_TIMEOUT_O === 4'b0000,
                "Una respuesta inmediata no debe generar timeout"
            );

            // La terminacion debe registrarse y no repetirse mientras
            // el Master mantiene CYC=1.
            @(posedge CLK_I);
            #1;

            check_true(
                M_ACK_O === 4'b0000 &&
                M_ERR_O === 4'b0000 &&
                S_CYC_O === 4'b0000,
                "Respuesta duplicada mientras CYC permanece alto"
            );

            repeat (2) begin
                @(posedge CLK_I);
                #1;
                check_true(
                    M_ACK_O === 4'b0000 && M_ERR_O === 4'b0000,
                    "No debe repetirse la terminacion del mismo CYC"
                );
            end

            @(negedge CLK_I);
            end_master(m);

            @(posedge CLK_I);
            #1;

        end

    endtask


    // ========================================================================
    //  PRUEBAS
    // ========================================================================

    initial begin

        CLK_I         = 1'b0;
        RST_I         = 1'b1;
        M_ADR_I       = 128'd0;
        M_DAT_I       = 128'd0;
        M_SEL_I       = 16'd0;
        M_WE_I        = 4'd0;
        M_CYC_I       = 4'd0;
        M_STB_I       = 4'd0;
        response_mode = 8'h55;
        slave_served  = 4'd0;
        checks        = 0;

        $dumpfile("SIM/out/wb_crossbar_tb.vcd");
        $dumpvars(0, wb_crossbar_tb);

        $display("============================================================");
        $display(" wb_crossbar_tb");
        $display("============================================================");


        // --------------------------------------------------------------------
        //  Todos los Masters y Slaves: lectura / escritura.
        // --------------------------------------------------------------------

        for (master_index = 0; master_index < 4;
             master_index = master_index + 1) begin

            for (slave_index = 0; slave_index < 4;
                 slave_index = slave_index + 1) begin

                run_single(master_index, slave_index, 1'b0, 2'b01);
                run_single(master_index, slave_index, 1'b1, 2'b01);

            end

        end

        $display("[PASS] Lecturas/escrituras: 4 Masters x 4 Slaves");


        // --------------------------------------------------------------------
        //  ERR y ACK+ERR de cada Slave, con prioridad a ERR.
        // --------------------------------------------------------------------

        for (slave_index = 0; slave_index < 4;
             slave_index = slave_index + 1) begin

            run_single(slave_index, slave_index, 1'b0, 2'b10);
            run_single(slave_index, slave_index, 1'b1, 2'b11);

        end

        $display("[PASS] Respuestas ERR y ERR sobre ACK");


        // --------------------------------------------------------------------
        //  Unmapped inmediato, para los cuatro Masters simultaneamente.
        // --------------------------------------------------------------------

        reset_design();

        @(negedge CLK_I);
        for (master_index = 0; master_index < 4;
             master_index = master_index + 1) begin

            start_master(master_index, 0, 1'b0);
            M_ADR_I[master_index*32 +: 32] =
                32'h2000_0000 + master_index*4;

        end

        #1;

        check_true(
            M_ERR_O === 4'b1111 &&
            M_ACK_O === 4'b0000 &&
            M_TIMEOUT_O === 4'b0000 &&
            S_CYC_O === 4'b0000,
            "Unmapped debe generar ERR local sin ocupar Slaves"
        );

        @(posedge CLK_I);
        #1;

        check_true(
            M_ERR_O === 4'b0000,
            "ERR unmapped no puede repetirse mientras CYC se mantiene"
        );

        @(negedge CLK_I);
        M_CYC_I = 4'b0000;
        M_STB_I = 4'b0000;

        $display("[PASS] Direcciones no mapeadas");


        // --------------------------------------------------------------------
        //  Cuatro Masters piden Slaves distintos; solo dos canales fisicos.
        // --------------------------------------------------------------------

        reset_design();

        @(negedge CLK_I);
        for (master_index = 0; master_index < 4;
             master_index = master_index + 1) begin
            start_master(master_index, master_index, master_index[0]);
        end

        @(posedge CLK_I);
        #1;

        check_true(
            M_ACK_O === 4'b0011 && S_CYC_O === 4'b0011,
            "Primera tanda debe atender M0:S0 y M1:S1"
        );

        @(posedge CLK_I);
        #1;

        check_true(
            M_ACK_O === 4'b1100 && S_CYC_O === 4'b1100,
            "Segunda tanda debe atender M2:S2 y M3:S3"
        );

        @(posedge CLK_I);
        #1;

        check_true(
            M_ACK_O === 4'b0000 &&
            S_CYC_O === 4'b0000,
            "Las cuatro solicitudes deben finalizar sin repeticion"
        );

        @(negedge CLK_I);
        M_CYC_I = 4'b0000;
        M_STB_I = 4'b0000;

        $display("[PASS] Cuatro Masters, dos canales simultaneos");


        // --------------------------------------------------------------------
        //  Cuatro Masters contienden por S0: round-robin y rearme.
        //  El modelo de Slave no acepta nueva transferencia sin un flanco
        //  intermedio en que observa S_CYC=0.
        // --------------------------------------------------------------------

        reset_design();

        @(negedge CLK_I);
        for (master_index = 0; master_index < 4;
             master_index = master_index + 1) begin
            start_master(master_index, 0, 1'b0);
        end

        for (pass_index = 0; pass_index < 4; pass_index = pass_index + 1) begin

            @(posedge CLK_I);
            #1;

            check_true(
                M_ACK_O === (4'b0001 << pass_index) &&
                S_CYC_O === 4'b0001,
                "Round-robin de M0..M3 sobre S0 incorrecto"
            );

            if (pass_index < 3) begin

                @(posedge CLK_I);
                #1;

                check_true(
                    S_CYC_O[0] === 1'b0 &&
                    S_STB_O[0] === 1'b0 &&
                    M_ACK_O === 4'b0000,
                    "Slave necesita un ciclo de rearme sin CYC/STB"
                );

            end

        end

        @(posedge CLK_I);
        #1;

        check_true(
            M_ACK_O === 4'b0000 && S_CYC_O === 4'b0000,
            "El ultimo Master debe completar y liberar el Slave"
        );

        @(negedge CLK_I);
        M_CYC_I = 4'b0000;
        M_STB_I = 4'b0000;

        $display("[PASS] Contencion, round-robin y rearme");


        // --------------------------------------------------------------------
        //  Pausa de STB: CYC y conexion deben permanecer.
        //  El otro canal puede completar independientemente.
        // --------------------------------------------------------------------

        reset_design();
        response_mode[1:0] = 2'b00;  // S0 no responde inicialmente.

        @(negedge CLK_I);
        start_master(0, 0, 1'b0);
        start_master(1, 1, 1'b1);

        @(posedge CLK_I);
        #1;

        check_true(
            M_ACK_O === 4'b0010 &&
            S_CYC_O === 4'b0011,
            "Dos canales deben progresar independientemente"
        );

        @(negedge CLK_I);
        M_STB_I[0] = 1'b0;
        response_mode[1:0] = 2'b01;

        #1;

        check_true(
            S_CYC_O[0] === 1'b1 &&
            S_STB_O[0] === 1'b0 &&
            M_ACK_O[0] === 1'b0,
            "Pausar STB no debe eliminar CYC ni producir ACK"
        );

        @(posedge CLK_I);
        #1;

        check_true(
            S_CYC_O[0] === 1'b1 &&
            dut.channel_valid !== 2'b00,
            "Se debe conservar la asignacion del Master pausado"
        );

        @(negedge CLK_I);
        M_STB_I[0] = 1'b1;

        #1;

        check_true(
            M_ACK_O[0] === 1'b1,
            "Al reanudar STB, el Slave debe poder responder"
        );

        @(posedge CLK_I);
        #1;

        @(negedge CLK_I);
        M_CYC_I = 4'b0000;
        M_STB_I = 4'b0000;

        $display("[PASS] Pausa STB y progreso en paralelo");


        // --------------------------------------------------------------------
        //  Cancelacion por CYC antes de la respuesta.
        // --------------------------------------------------------------------

        reset_design();
        response_mode[7:6] = 2'b00; // S3 no responde.

        @(negedge CLK_I);
        start_master(2, 3, 1'b1);

        @(posedge CLK_I);
        #1;

        check_true(
            S_CYC_O === 4'b1000 && M_ACK_O === 4'b0000,
            "Transaccion sin respuesta debe mantener el Slave activo"
        );

        @(negedge CLK_I);
        end_master(2);

        @(posedge CLK_I);
        #1;

        check_true(
            S_CYC_O === 4'b0000 && M_ERR_O === 4'b0000,
            "Cancelar CYC debe retirar la conexion sin ERR"
        );

        @(negedge CLK_I);
        response_mode[7:6] = 2'b01;
        start_master(3, 3, 1'b0);

        @(posedge CLK_I);
        #1;

        check_true(
            M_ACK_O[3] === 1'b1,
            "Un nuevo Master debe poder usar el Slave cancelado"
        );

        @(posedge CLK_I);
        #1;
        @(negedge CLK_I);
        end_master(3);

        $display("[PASS] Cancelacion de transacciones");


        // --------------------------------------------------------------------
        //  Timeout exacto en el flanco que acumula 1024 ciclos activos.
        //  Comprobar individualmente M0, M1, M2 y M3.
        // --------------------------------------------------------------------

        for (master_index = 0; master_index < 4;
             master_index = master_index + 1) begin

            reset_design();
            response_mode = 8'h00;

            @(negedge CLK_I);
            start_master(master_index, master_index, 1'b0);

            for (cycle_index = 1; cycle_index <= 1023;
                 cycle_index = cycle_index + 1) begin

                @(posedge CLK_I);
                #1;

                if (cycle_index == 1023) begin

                    check_true(
                        M_TIMEOUT_O === 4'b0000 &&
                        M_ERR_O === 4'b0000,
                        "Timeout prematuro antes del ciclo 1024"
                    );

                end

            end

            @(posedge CLK_I);
            #1;

            check_true(
                M_TIMEOUT_O === (4'b0001 << master_index) &&
                M_ERR_O === (4'b0001 << master_index) &&
                M_ACK_O === 4'b0000 &&
                S_CYC_O === 4'b0000,
                "Timeout debe ocurrir exactamente en ciclo 1024"
            );

            @(posedge CLK_I);
            #1;

            check_true(
                M_TIMEOUT_O === 4'b0000 &&
                M_ERR_O === 4'b0000,
                "Timeout no debe repetirse mientras CYC permanece alto"
            );

            @(negedge CLK_I);
            end_master(master_index);

        end

        $display("[PASS] Timeout exacto para M0..M3");


        // --------------------------------------------------------------------
        //  Timeout cuando STB esta pausado: el contador continua, pero
        //  TIMEOUT/ERR se hacen visibles al volver STB=1.
        // --------------------------------------------------------------------

        reset_design();
        response_mode = 8'h00;

        @(negedge CLK_I);
        start_master(1, 2, 1'b0);

        @(posedge CLK_I);
        #1;

        @(negedge CLK_I);
        M_STB_I[1] = 1'b0;

        for (cycle_index = 2; cycle_index <= 1024;
             cycle_index = cycle_index + 1) begin

            @(posedge CLK_I);
            #1;

        end

        check_true(
            M_TIMEOUT_O === 4'b0000 &&
            M_ERR_O === 4'b0000,
            "Timeout durante STB=0 no debe presentarse al Master"
        );

        @(negedge CLK_I);
        M_STB_I[1] = 1'b1;
        #1;

        check_true(
            M_TIMEOUT_O[1] === 1'b1 &&
            M_ERR_O[1] === 1'b1 &&
            M_ACK_O[1] === 1'b0,
            "Timeout pendiente debe notificarse al reactivar STB"
        );

        @(posedge CLK_I);
        #1;

        check_true(
            M_TIMEOUT_O[1] === 1'b0,
            "Timeout notificado debe terminar una sola vez"
        );

        @(negedge CLK_I);
        end_master(1);

        $display("[PASS] Timeout durante pausa de STB");


        $display("============================================================");
        $display(" Checks: %0d", checks);
        $display(" Errors: 0");
        $display(" [PASS] wb_crossbar_tb COMPLETO");
        $display("============================================================");

        $finish;

    end


    initial begin
        #1000000;
        $fatal(1, "Timeout del testbench");
    end

endmodule

`default_nettype wire
