`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Testbench - wb_switch_fabric
 * ----------------------------------------------------------------------------
 *  Verificacion self-checking del fabric combinacional:
 *
 *      4 Masters, 4 Slaves, 2 canales dinamicos
 *
 *  Prueba rutas individuales por ambos canales, dos rutas simultaneas,
 *  CYC/STB independientes, byte selects, lectura, escritura, ACK y ERR.
 *
 *  IMPORTANTE:
 *      El controlador, no el fabric, garantiza la exclusividad Master/Slave.
 *      El TB usa solamente asignaciones validas de canales.
 * ============================================================================
 */

module wb_switch_fabric_tb;

    reg  [127:0] M_ADR_I;
    reg  [127:0] M_DAT_I;
    reg  [15:0]  M_SEL_I;
    reg  [3:0]   M_WE_I;
    reg  [3:0]   M_CYC_I;
    reg  [3:0]   M_STB_I;

    wire [127:0] M_DAT_O;
    wire [3:0]   M_ACK_O;
    wire [3:0]   M_ERR_O;

    wire [127:0] S_ADR_O;
    wire [127:0] S_DAT_O;
    wire [15:0]  S_SEL_O;
    wire [3:0]   S_WE_O;
    wire [3:0]   S_CYC_O;
    wire [3:0]   S_STB_O;

    reg  [127:0] S_DAT_I;
    reg  [3:0]   S_ACK_I;
    reg  [3:0]   S_ERR_I;

    reg  [1:0]   CH_VALID_I;
    reg  [3:0]   CH_MASTER_SEL_I;
    reg  [3:0]   CH_SLAVE_SEL_I;

    reg  [127:0] expected_s_adr;
    reg  [127:0] expected_s_dat;
    reg  [15:0]  expected_s_sel;
    reg  [3:0]   expected_s_we;
    reg  [3:0]   expected_s_cyc;
    reg  [3:0]   expected_s_stb;

    reg  [127:0] expected_m_dat;
    reg  [3:0]   expected_m_ack;
    reg  [3:0]   expected_m_err;

    integer tests;
    integer errors;
    integer channel;
    integer master0;
    integer master1;
    integer slave0;
    integer slave1;

    wb_switch_fabric dut (

        .M_ADR_I       (M_ADR_I),
        .M_DAT_I       (M_DAT_I),
        .M_SEL_I       (M_SEL_I),
        .M_WE_I        (M_WE_I),
        .M_CYC_I       (M_CYC_I),
        .M_STB_I       (M_STB_I),

        .M_DAT_O       (M_DAT_O),
        .M_ACK_O       (M_ACK_O),
        .M_ERR_O       (M_ERR_O),

        .S_ADR_O       (S_ADR_O),
        .S_DAT_O       (S_DAT_O),
        .S_SEL_O       (S_SEL_O),
        .S_WE_O        (S_WE_O),
        .S_CYC_O       (S_CYC_O),
        .S_STB_O       (S_STB_O),

        .S_DAT_I       (S_DAT_I),
        .S_ACK_I       (S_ACK_I),
        .S_ERR_I       (S_ERR_I),

        .CH_VALID_I     (CH_VALID_I),
        .CH_MASTER_SEL_I(CH_MASTER_SEL_I),
        .CH_SLAVE_SEL_I (CH_SLAVE_SEL_I)

    );


    // ========================================================================
    //  STIMULUS
    // ========================================================================

    task initialize_stimulus;

        integer i;

        begin

            M_ADR_I         = 128'd0;
            M_DAT_I         = 128'd0;
            M_SEL_I         = 16'd0;
            M_WE_I          = 4'd0;
            M_CYC_I         = 4'd0;
            M_STB_I         = 4'd0;

            S_DAT_I         = 128'd0;
            S_ACK_I         = 4'd0;
            S_ERR_I         = 4'd0;

            CH_VALID_I      = 2'd0;
            CH_MASTER_SEL_I = 4'd0;
            CH_SLAVE_SEL_I  = 4'd0;

            // Diferenciar cada entrada para detectar cruces de buses.
            for (i = 0; i < 4; i = i + 1) begin

                M_ADR_I[i*32 +: 32] = 32'h1000_1100 + (i * 32'h0000_1234);
                M_DAT_I[i*32 +: 32] = 32'hA5C3_0000 + (i * 32'h0000_1111);
                M_SEL_I[i*4 +: 4]   = i + 1;
                M_WE_I[i]           = i[0];
                M_CYC_I[i]          = 1'b1;
                M_STB_I[i]          = 1'b1;

                S_DAT_I[i*32 +: 32] = 32'hBCDE_0100 + (i * 32'h0000_0101);

            end

        end

    endtask


    task set_channel;

        input integer channel_index;
        input integer master_index;
        input integer slave_index;

        begin

            CH_VALID_I[channel_index] = 1'b1;
            CH_MASTER_SEL_I[channel_index*2 +: 2] = master_index;
            CH_SLAVE_SEL_I[channel_index*2 +: 2]  = slave_index;

        end

    endtask


    // ========================================================================
    //  SCOREBOARD INDEPENDIENTE DE LA ESTRUCTURA MUX/DEMUX DEL RTL
    // ========================================================================

    task check_fabric;

        input [255:0] description;

        integer c;
        integer m;
        integer s;

        begin

            expected_s_adr = 128'd0;
            expected_s_dat = 128'd0;
            expected_s_sel = 16'd0;
            expected_s_we  = 4'd0;
            expected_s_cyc = 4'd0;
            expected_s_stb = 4'd0;

            expected_m_dat = 128'd0;
            expected_m_ack = 4'd0;
            expected_m_err = 4'd0;

            // Detectar asignaciones invalidas en los propios estimulos.
            if (
                (CH_VALID_I === 2'b11) &&
                (
                    (CH_MASTER_SEL_I[1:0] == CH_MASTER_SEL_I[3:2]) ||
                    (CH_SLAVE_SEL_I[1:0]  == CH_SLAVE_SEL_I[3:2])
                )
            ) begin

                $display("[TB ERROR] Dos canales asignados al mismo Master/Slave");
                $fatal(1);

            end

            for (c = 0; c < 2; c = c + 1) begin

                if (CH_VALID_I[c]) begin

                    m = CH_MASTER_SEL_I[c*2 +: 2];
                    s = CH_SLAVE_SEL_I[c*2 +: 2];

                    if (M_CYC_I[m]) begin

                        expected_s_adr[s*32 +: 32] = M_ADR_I[m*32 +: 32];
                        expected_s_dat[s*32 +: 32] = M_DAT_I[m*32 +: 32];
                        expected_s_sel[s*4 +: 4]   = M_SEL_I[m*4 +: 4];
                        expected_s_we[s]           = M_WE_I[m];
                        expected_s_cyc[s]          = 1'b1;
                        expected_s_stb[s]          = M_STB_I[m];

                        if (M_STB_I[m]) begin

                            expected_m_dat[m*32 +: 32] = S_DAT_I[s*32 +: 32];
                            expected_m_err[m]          = S_ERR_I[s];
                            expected_m_ack[m]          = S_ACK_I[s] & ~S_ERR_I[s];

                        end

                    end

                end

            end

            #1;
            tests = tests + 1;

            if (
                (S_ADR_O !== expected_s_adr) ||
                (S_DAT_O !== expected_s_dat) ||
                (S_SEL_O !== expected_s_sel) ||
                (S_WE_O  !== expected_s_we)  ||
                (S_CYC_O !== expected_s_cyc) ||
                (S_STB_O !== expected_s_stb) ||
                (M_DAT_O !== expected_m_dat) ||
                (M_ACK_O !== expected_m_ack) ||
                (M_ERR_O !== expected_m_err)
            ) begin

                errors = errors + 1;

                $display("[FAIL] %0s | CH_VALID=%b MASTER=%h SLAVE=%h",
                    description, CH_VALID_I, CH_MASTER_SEL_I, CH_SLAVE_SEL_I);

                if (S_ADR_O !== expected_s_adr)
                    $display("  S_ADR  expected=%h actual=%h", expected_s_adr, S_ADR_O);
                if (S_DAT_O !== expected_s_dat)
                    $display("  S_DAT  expected=%h actual=%h", expected_s_dat, S_DAT_O);
                if (S_SEL_O !== expected_s_sel)
                    $display("  S_SEL  expected=%h actual=%h", expected_s_sel, S_SEL_O);
                if (S_WE_O !== expected_s_we)
                    $display("  S_WE   expected=%h actual=%h", expected_s_we, S_WE_O);
                if (S_CYC_O !== expected_s_cyc)
                    $display("  S_CYC  expected=%h actual=%h", expected_s_cyc, S_CYC_O);
                if (S_STB_O !== expected_s_stb)
                    $display("  S_STB  expected=%h actual=%h", expected_s_stb, S_STB_O);
                if (M_DAT_O !== expected_m_dat)
                    $display("  M_DAT  expected=%h actual=%h", expected_m_dat, M_DAT_O);
                if (M_ACK_O !== expected_m_ack)
                    $display("  M_ACK  expected=%h actual=%h", expected_m_ack, M_ACK_O);
                if (M_ERR_O !== expected_m_err)
                    $display("  M_ERR  expected=%h actual=%h", expected_m_err, M_ERR_O);

            end

        end

    endtask


    // ========================================================================
    //  TEST SEQUENCE
    // ========================================================================

    initial begin

        $dumpfile("SIM/out/wb_switch_fabric_tb.vcd");
        $dumpvars(0, wb_switch_fabric_tb);

        tests  = 0;
        errors = 0;

        $display("============================================================");
        $display(" wb_switch_fabric_tb");
        $display("============================================================");


        // --------------------------------------------------------------------
        //  Ninguna conexion valida: ninguna solicitud ni respuesta visible.
        // --------------------------------------------------------------------

        initialize_stimulus();
        S_ACK_I = 4'hF;
        S_ERR_I = 4'hF;
        check_fabric("sin canales validos");


        // --------------------------------------------------------------------
        //  Barrido exhaustivo de rutas simples:
        //      2 canales x 4 Masters x 4 Slaves
        //  Cinco escenarios de respuesta/control por ruta.
        // --------------------------------------------------------------------

        for (channel = 0; channel < 2; channel = channel + 1) begin

            for (master0 = 0; master0 < 4; master0 = master0 + 1) begin

                for (slave0 = 0; slave0 < 4; slave0 = slave0 + 1) begin

                    initialize_stimulus();
                    set_channel(channel, master0, slave0);

                    S_ACK_I = 4'hF;
                    check_fabric("ruta simple ACK");

                    S_ERR_I[slave0] = 1'b1;
                    check_fabric("ERR domina ACK");

                    S_ACK_I[slave0] = 1'b0;
                    check_fabric("ERR sin ACK");

                    S_ERR_I[slave0] = 1'b0;
                    S_ACK_I[slave0] = 1'b1;
                    M_STB_I[master0] = 1'b0;
                    check_fabric("STB pausado con CYC activo");

                    M_STB_I[master0] = 1'b1;
                    M_CYC_I[master0] = 1'b0;
                    check_fabric("CYC inactivo con STB activo");

                end

            end

        end


        // --------------------------------------------------------------------
        //  Dos rutas simultaneas, sin Master ni Slave compartidos.
        //      4 x 3 posibles Masters para CH0/CH1
        //      4 x 3 posibles Slaves para CH0/CH1
        //  Respuesta: ACK para CH0, ERR para CH1.
        // --------------------------------------------------------------------

        for (master0 = 0; master0 < 4; master0 = master0 + 1) begin

            for (master1 = 0; master1 < 4; master1 = master1 + 1) begin

                if (master0 != master1) begin

                    for (slave0 = 0; slave0 < 4; slave0 = slave0 + 1) begin

                        for (slave1 = 0; slave1 < 4; slave1 = slave1 + 1) begin

                            if (slave0 != slave1) begin

                                initialize_stimulus();

                                set_channel(0, master0, slave0);
                                set_channel(1, master1, slave1);

                                S_ACK_I[slave0] = 1'b1;
                                S_ERR_I[slave1] = 1'b1;

                                check_fabric("dos rutas simultaneas ACK/ERR");

                            end

                        end

                    end

                end

            end

        end


        // --------------------------------------------------------------------
        //  Dos rutas activas, STB pausado solo en un canal.
        //  La otra transaccion debe continuar sin interferencia.
        // --------------------------------------------------------------------

        initialize_stimulus();

        set_channel(0, 3, 0);
        set_channel(1, 1, 2);

        S_ACK_I = 4'hF;
        M_STB_I[3] = 1'b0;

        check_fabric("dos canales, STB pausado en CH0");

        M_STB_I[3] = 1'b1;
        M_STB_I[1] = 1'b0;

        check_fabric("dos canales, STB pausado en CH1");


        // --------------------------------------------------------------------
        //  Solo el Slave realmente seleccionado puede responder.
        // --------------------------------------------------------------------

        initialize_stimulus();

        set_channel(1, 2, 3);
        S_ACK_I[0] = 1'b1;
        S_ERR_I[1] = 1'b1;

        check_fabric("respuesta de Slaves no seleccionados");


        $display("============================================================");
        $display(" Tests : %0d", tests);
        $display(" Errors: %0d", errors);

        if (errors == 0) begin
            $display(" [PASS] wb_switch_fabric_tb COMPLETO");
        end else begin
            $display(" [FAIL] wb_switch_fabric_tb: %0d errores", errors);
        end

        $display("============================================================");

        if (errors != 0)
            $fatal(1, "wb_switch_fabric_tb fallo");

        $finish;

    end

endmodule

`default_nettype wire
