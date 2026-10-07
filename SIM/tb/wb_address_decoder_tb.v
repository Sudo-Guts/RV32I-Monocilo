`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Testbench - wb_address_decoder
 * ----------------------------------------------------------------------------
 *  Verificacion combinacional y self-checking del decoder Wishbone fijo.
 *
 *  Arquitectura:
 *
 *      - 4 Masters
 *      - 4 Slaves
 *
 *  Mapa:
 *
 *      S0 IMEM     0x0000_0000 - 0x0000_FFFF
 *      S1 DMEM     0x0001_0000 - 0x0001_FFFF
 *      S2 Loader   0x1000_0000 - 0x1000_00FF
 *      S3 Debug    0x1000_1000 - 0x1000_10FF
 *
 *  Comprueba:
 *
 *      - base y limite superior de cada ventana para los cuatro Masters
 *      - direcciones no mapeadas
 *      - decodificacion simultanea de los cuatro Masters
 *      - cuatro Masters apuntando al mismo Slave
 *
 *  El mapa actual es disjunto, por lo que M_OVERLAP_O debe permanecer en cero.
 * ============================================================================
 */

module wb_address_decoder_tb;

    reg [127:0] M_ADR_I;

    wire [7:0] M_TARGET_O;
    wire [3:0] M_TARGET_VALID_O;
    wire [3:0] M_UNMAPPED_O;
    wire [3:0] M_OVERLAP_O;

    integer tests;
    integer errors;


    wb_address_decoder dut (

        .M_ADR_I         (M_ADR_I),
        .M_TARGET_O      (M_TARGET_O),
        .M_TARGET_VALID_O(M_TARGET_VALID_O),
        .M_UNMAPPED_O    (M_UNMAPPED_O),
        .M_OVERLAP_O     (M_OVERLAP_O)

    );


    // ========================================================================
    //  CHECK ONE MASTER
    // ========================================================================

    task check_master;

        input integer master;
        input [31:0] address;
        input expected_valid;
        input [1:0] expected_target;
        input expected_unmapped;

        reg [1:0] actual_target;

        begin

            // Mantener los otros Masters en una direccion no mapeada.
            M_ADR_I = {
                32'hDEAD_BEEF,
                32'hDEAD_BEEF,
                32'hDEAD_BEEF,
                32'hDEAD_BEEF
            };

            M_ADR_I[master*32 +: 32] = address;

            #1;

            actual_target = M_TARGET_O[master*2 +: 2];

            tests = tests + 1;

            if (
                (M_TARGET_VALID_O[master] !== expected_valid)   ||
                (actual_target             !== expected_target) ||
                (M_UNMAPPED_O[master]      !== expected_unmapped) ||
                (M_OVERLAP_O[master]       !== 1'b0)
            ) begin

                errors = errors + 1;

                $display(
                    "[FAIL] M%0d ADR=%08h | VALID=%b TARGET=%0d UNMAPPED=%b OVERLAP=%b | esperado VALID=%b TARGET=%0d UNMAPPED=%b",
                    master,
                    address,
                    M_TARGET_VALID_O[master],
                    actual_target,
                    M_UNMAPPED_O[master],
                    M_OVERLAP_O[master],
                    expected_valid,
                    expected_target,
                    expected_unmapped
                );

            end else begin

                $display(
                    "[PASS] M%0d ADR=%08h -> VALID=%b TARGET=%0d UNMAPPED=%b OVERLAP=%b",
                    master,
                    address,
                    M_TARGET_VALID_O[master],
                    actual_target,
                    M_UNMAPPED_O[master],
                    M_OVERLAP_O[master]
                );

            end

        end

    endtask


    // ========================================================================
    //  CHECK FOUR MASTERS IN PARALLEL
    // ========================================================================

    task check_parallel;

        input [31:0] address_m0;
        input [1:0]  target_m0;

        input [31:0] address_m1;
        input [1:0]  target_m1;

        input [31:0] address_m2;
        input [1:0]  target_m2;

        input [31:0] address_m3;
        input [1:0]  target_m3;

        reg [1:0] actual_m0;
        reg [1:0] actual_m1;
        reg [1:0] actual_m2;
        reg [1:0] actual_m3;

        begin

            M_ADR_I[31:0]   = address_m0;
            M_ADR_I[63:32]  = address_m1;
            M_ADR_I[95:64]  = address_m2;
            M_ADR_I[127:96] = address_m3;

            #1;

            actual_m0 = M_TARGET_O[1:0];
            actual_m1 = M_TARGET_O[3:2];
            actual_m2 = M_TARGET_O[5:4];
            actual_m3 = M_TARGET_O[7:6];

            tests = tests + 1;

            if (
                (M_TARGET_VALID_O !== 4'b1111) ||
                (M_UNMAPPED_O     !== 4'b0000) ||
                (M_OVERLAP_O      !== 4'b0000) ||
                (actual_m0        !== target_m0) ||
                (actual_m1        !== target_m1) ||
                (actual_m2        !== target_m2) ||
                (actual_m3        !== target_m3)
            ) begin

                errors = errors + 1;

                $display(
                    "[FAIL] paralelo | M0:S%0d M1:S%0d M2:S%0d M3:S%0d",
                    actual_m0,
                    actual_m1,
                    actual_m2,
                    actual_m3
                );

            end else begin

                $display(
                    "[PASS] paralelo | M0:S%0d M1:S%0d M2:S%0d M3:S%0d",
                    actual_m0,
                    actual_m1,
                    actual_m2,
                    actual_m3
                );

            end

        end

    endtask


    // ========================================================================
    //  TEST SEQUENCE
    // ========================================================================

    initial begin

        $dumpfile("SIM/out/wb_address_decoder_tb.vcd");
        $dumpvars(0, wb_address_decoder_tb);

        M_ADR_I = 128'd0;
        tests   = 0;
        errors  = 0;

        #1;

        $display("============================================================");
        $display(" wb_address_decoder_tb");
        $display("============================================================");


        // --------------------------------------------------------------------
        //  Master 0
        // --------------------------------------------------------------------

        check_master(0, 32'h0000_0000, 1'b1, 2'd0, 1'b0);
        check_master(0, 32'h0000_FFFF, 1'b1, 2'd0, 1'b0);

        check_master(0, 32'h0001_0000, 1'b1, 2'd1, 1'b0);
        check_master(0, 32'h0001_FFFF, 1'b1, 2'd1, 1'b0);

        check_master(0, 32'h1000_0000, 1'b1, 2'd2, 1'b0);
        check_master(0, 32'h1000_00FF, 1'b1, 2'd2, 1'b0);

        check_master(0, 32'h1000_1000, 1'b1, 2'd3, 1'b0);
        check_master(0, 32'h1000_10FF, 1'b1, 2'd3, 1'b0);

        check_master(0, 32'h0002_0000, 1'b0, 2'd0, 1'b1);
        check_master(0, 32'h1000_0100, 1'b0, 2'd0, 1'b1);
        check_master(0, 32'h1000_1100, 1'b0, 2'd0, 1'b1);
        check_master(0, 32'h2000_0000, 1'b0, 2'd0, 1'b1);


        // --------------------------------------------------------------------
        //  Master 1
        // --------------------------------------------------------------------

        check_master(1, 32'h0000_0000, 1'b1, 2'd0, 1'b0);
        check_master(1, 32'h0000_FFFF, 1'b1, 2'd0, 1'b0);

        check_master(1, 32'h0001_0000, 1'b1, 2'd1, 1'b0);
        check_master(1, 32'h0001_FFFF, 1'b1, 2'd1, 1'b0);

        check_master(1, 32'h1000_0000, 1'b1, 2'd2, 1'b0);
        check_master(1, 32'h1000_00FF, 1'b1, 2'd2, 1'b0);

        check_master(1, 32'h1000_1000, 1'b1, 2'd3, 1'b0);
        check_master(1, 32'h1000_10FF, 1'b1, 2'd3, 1'b0);

        check_master(1, 32'h0002_0000, 1'b0, 2'd0, 1'b1);
        check_master(1, 32'h1000_0100, 1'b0, 2'd0, 1'b1);
        check_master(1, 32'h1000_1100, 1'b0, 2'd0, 1'b1);
        check_master(1, 32'h2000_0000, 1'b0, 2'd0, 1'b1);


        // --------------------------------------------------------------------
        //  Master 2
        // --------------------------------------------------------------------

        check_master(2, 32'h0000_0000, 1'b1, 2'd0, 1'b0);
        check_master(2, 32'h0000_FFFF, 1'b1, 2'd0, 1'b0);

        check_master(2, 32'h0001_0000, 1'b1, 2'd1, 1'b0);
        check_master(2, 32'h0001_FFFF, 1'b1, 2'd1, 1'b0);

        check_master(2, 32'h1000_0000, 1'b1, 2'd2, 1'b0);
        check_master(2, 32'h1000_00FF, 1'b1, 2'd2, 1'b0);

        check_master(2, 32'h1000_1000, 1'b1, 2'd3, 1'b0);
        check_master(2, 32'h1000_10FF, 1'b1, 2'd3, 1'b0);

        check_master(2, 32'h0002_0000, 1'b0, 2'd0, 1'b1);
        check_master(2, 32'h1000_0100, 1'b0, 2'd0, 1'b1);
        check_master(2, 32'h1000_1100, 1'b0, 2'd0, 1'b1);
        check_master(2, 32'h2000_0000, 1'b0, 2'd0, 1'b1);


        // --------------------------------------------------------------------
        //  Master 3
        // --------------------------------------------------------------------

        check_master(3, 32'h0000_0000, 1'b1, 2'd0, 1'b0);
        check_master(3, 32'h0000_FFFF, 1'b1, 2'd0, 1'b0);

        check_master(3, 32'h0001_0000, 1'b1, 2'd1, 1'b0);
        check_master(3, 32'h0001_FFFF, 1'b1, 2'd1, 1'b0);

        check_master(3, 32'h1000_0000, 1'b1, 2'd2, 1'b0);
        check_master(3, 32'h1000_00FF, 1'b1, 2'd2, 1'b0);

        check_master(3, 32'h1000_1000, 1'b1, 2'd3, 1'b0);
        check_master(3, 32'h1000_10FF, 1'b1, 2'd3, 1'b0);

        check_master(3, 32'h0002_0000, 1'b0, 2'd0, 1'b1);
        check_master(3, 32'h1000_0100, 1'b0, 2'd0, 1'b1);
        check_master(3, 32'h1000_1100, 1'b0, 2'd0, 1'b1);
        check_master(3, 32'h2000_0000, 1'b0, 2'd0, 1'b1);


        // --------------------------------------------------------------------
        //  Los cuatro Masters acceden simultaneamente a Slaves distintos.
        // --------------------------------------------------------------------

        check_parallel(
            32'h0000_0040, 2'd0,
            32'h0001_0040, 2'd1,
            32'h1000_0040, 2'd2,
            32'h1000_1040, 2'd3
        );


        // --------------------------------------------------------------------
        //  Los cuatro Masters pueden decodificar simultaneamente el mismo
        //  Slave. La exclusividad se resuelve despues en wb_switch_control.
        // --------------------------------------------------------------------

        check_parallel(
            32'h0001_0010, 2'd1,
            32'h0001_0020, 2'd1,
            32'h0001_0030, 2'd1,
            32'h0001_0040, 2'd1
        );


        $display("============================================================");
        $display(" Tests : %0d", tests);
        $display(" Errors: %0d", errors);

        if (errors == 0)
            $display(" [PASS] wb_address_decoder_tb COMPLETO");
        else
            $display(" [FAIL] wb_address_decoder_tb: %0d errores", errors);

        $display("============================================================");

        #1;
        $finish;

    end

endmodule

`default_nettype wire
