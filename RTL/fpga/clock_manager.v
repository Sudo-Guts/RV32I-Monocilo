`timescale 1ns / 1ps

/*
 * ========================================================================
 *  Clock Manager - Reloj Nexys3 / Spartan-6
 * ------------------------------------------------------------------------
 *  Adapta el oscilador fisico de 100 MHz al reloj interno del SoC.
 *  Utiliza primitivas Xilinx IBUFG, BUFG y DCM_SP; este modulo requiere
 *  Spartan-6 o modelos de sus primitivas al simular fuera de ISE.
 *
 *  CLK_DIVIDE     Frecuencia nominal de clk_o
 *       1          100 MHz, bypass del DCM
 *       2           50 MHz
 *       3           33.333... MHz
 *       4           25 MHz
 *       5           20 MHz
 *       8           12.5 MHz
 *      16            6.25 MHz
 *
 *  En modo dividido, CLK0 realimentado por BUFG permite el enganche del DCM;
 *  CLKDV pasa por otro BUFG y se utiliza como reloj global del sistema.
 *  locked_o indica enganche del DCM. clock_stopped_o refleja STATUS[1].
 *  En bypass, locked_o = !rst_i y clock_stopped_o = 0; no hay monitor DCM activo.
 *  Un divisor no admitido deja locked_o = 0 y evita arrancar el sistema.
 *
 *  rst_i es activo en alto y llega a la entrada RST de la primitiva.
 *  La sincronizacion de liberacion del reset del SoC se realiza por separado
 *  dentro de cpu_soc; este bloque solo genera el reloj y su estado.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ========================================================================
 */

module clock_manager #(
    // Divisor de 100 MHz; valores admitidos: 1,2,3,4,5,8,16.
    parameter integer CLK_DIVIDE = 2

) (

    // ---------------------------------------------------------
    //          Reloj y reset
    // ---------------------------------------------------------
    input wire clk_i,  // Reloj fisico de 100 MHz de la Nexys3.
    input wire rst_i,     // Reset activo en alto hacia DCM_SP.

    // ---------------------------------------------------------
    //          Estado
    // ---------------------------------------------------------
    output wire clock_stopped_o,  // Estado DCM STATUS[1]; cero en bypass.

    // ---------------------------------------------------------
    //          Salida de reloj
    // ---------------------------------------------------------
    output wire clk_o,  // Reloj global generado para el sistema.
    output wire locked_o    // Reloj disponible/enganchado segun el modo.

);

    // ---------------------------------------------------------
    //          Divisores admitidos
    // ---------------------------------------------------------

    localparam
        integer DIVIDE_SUPPORTED = (CLK_DIVIDE == 1) || (CLK_DIVIDE == 2) || (CLK_DIVIDE == 3) ||
        (CLK_DIVIDE == 4) || (CLK_DIVIDE == 5) || (CLK_DIVIDE == 8) || (CLK_DIVIDE == 16);

    // =============================================================
    //              Generacion del reloj
    // =============================================================

    generate
        // ---------------------------------------------------------
        //      100 MHz bypass
        // ---------------------------------------------------------

        if (CLK_DIVIDE == 1) begin : gen_clock_bypass

            wire clk_in_buf;

            IBUFG ibufg_inst (
                .I(clk_i),
                .O(clk_in_buf)
            );

            BUFG clkout_bufg_inst (
                .I(clk_in_buf),
                .O(clk_o)
            );

            assign locked_o        = ~rst_i;
            assign clock_stopped_o = 1'b0;

        end  // ---------------------------------------------------------
             //      Division de reloj mediante DCM
             // ---------------------------------------------------------

        else if (DIVIDE_SUPPORTED) begin : gen_clock_dcm

            wire       clk_in_buf;
            wire       clk0_dcm;
            wire       clk0_fb;
            wire       clkdv_dcm;
            wire       dcm_locked;
            wire [7:0] dcm_status;

            // -----------------------------------------------------
            //  Division de reloj mediante DCM
            // -----------------------------------------------------

            IBUFG ibufg_inst (
                .I(clk_i),
                .O(clk_in_buf)
            );

            // -----------------------------------------------------
            //  Buffer de realimentacion del DCM
            // -----------------------------------------------------

            BUFG clkfb_bufg_inst (
                .I(clk0_dcm),
                .O(clk0_fb)
            );

            // -----------------------------------------------------
            //  Buffer global del reloj del sistema
            // -----------------------------------------------------

            BUFG clkout_bufg_inst (
                .I(clkdv_dcm),
                .O(clk_o)
            );

            // -----------------------------------------------------
            //  Salidas de estado
            // -----------------------------------------------------

            assign locked_o        = dcm_locked;

            assign clock_stopped_o = dcm_status[1];

            // =====================================================
            //  Seleccion del divisor DCM
            // =====================================================

            if (CLK_DIVIDE == 2) begin : gen_div2

                DCM_SP #(
                    .CLKDV_DIVIDE         (2.0),
                    .CLKIN_PERIOD         (10.0),
                    .CLK_FEEDBACK         ("1X"),
                    .DESKEW_ADJUST        ("SYSTEM_SYNCHRONOUS"),
                    .DUTY_CYCLE_CORRECTION("TRUE"),
                    .STARTUP_WAIT         ("FALSE")
                ) dcm_sp_inst (
                    .CLKIN(clk_in_buf),
                    .CLKFB(clk0_fb),
                    .RST  (rst_i),

                    .CLK0 (clk0_dcm),
                    .CLKDV(clkdv_dcm),

                    .LOCKED(dcm_locked),

                    .PSCLK   (1'b0),
                    .PSEN    (1'b0),
                    .PSINCDEC(1'b0),
                    .DSSEN   (1'b0),

                    .CLK90   (),
                    .CLK180  (),
                    .CLK270  (),
                    .CLK2X   (),
                    .CLK2X180(),
                    .CLKFX   (),
                    .CLKFX180(),
                    .PSDONE  (),
                    .STATUS  (dcm_status)
                );

            end else if (CLK_DIVIDE == 3) begin : gen_div3

                DCM_SP #(
                    .CLKDV_DIVIDE         (3.0),
                    .CLKIN_PERIOD         (10.0),
                    .CLK_FEEDBACK         ("1X"),
                    .DESKEW_ADJUST        ("SYSTEM_SYNCHRONOUS"),
                    .DUTY_CYCLE_CORRECTION("TRUE"),
                    .STARTUP_WAIT         ("FALSE")
                ) dcm_sp_inst (
                    .CLKIN(clk_in_buf),
                    .CLKFB(clk0_fb),
                    .RST  (rst_i),

                    .CLK0 (clk0_dcm),
                    .CLKDV(clkdv_dcm),

                    .LOCKED(dcm_locked),

                    .PSCLK   (1'b0),
                    .PSEN    (1'b0),
                    .PSINCDEC(1'b0),
                    .DSSEN   (1'b0),

                    .CLK90   (),
                    .CLK180  (),
                    .CLK270  (),
                    .CLK2X   (),
                    .CLK2X180(),
                    .CLKFX   (),
                    .CLKFX180(),
                    .PSDONE  (),
                    .STATUS  (dcm_status)
                );

            end else if (CLK_DIVIDE == 4) begin : gen_div4

                DCM_SP #(
                    .CLKDV_DIVIDE         (4.0),
                    .CLKIN_PERIOD         (10.0),
                    .CLK_FEEDBACK         ("1X"),
                    .DESKEW_ADJUST        ("SYSTEM_SYNCHRONOUS"),
                    .DUTY_CYCLE_CORRECTION("TRUE"),
                    .STARTUP_WAIT         ("FALSE")
                ) dcm_sp_inst (
                    .CLKIN(clk_in_buf),
                    .CLKFB(clk0_fb),
                    .RST  (rst_i),

                    .CLK0 (clk0_dcm),
                    .CLKDV(clkdv_dcm),

                    .LOCKED(dcm_locked),

                    .PSCLK   (1'b0),
                    .PSEN    (1'b0),
                    .PSINCDEC(1'b0),
                    .DSSEN   (1'b0),

                    .CLK90   (),
                    .CLK180  (),
                    .CLK270  (),
                    .CLK2X   (),
                    .CLK2X180(),
                    .CLKFX   (),
                    .CLKFX180(),
                    .PSDONE  (),
                    .STATUS  (dcm_status)
                );

            end else if (CLK_DIVIDE == 5) begin : gen_div5

                DCM_SP #(
                    .CLKDV_DIVIDE         (5.0),
                    .CLKIN_PERIOD         (10.0),
                    .CLK_FEEDBACK         ("1X"),
                    .DESKEW_ADJUST        ("SYSTEM_SYNCHRONOUS"),
                    .DUTY_CYCLE_CORRECTION("TRUE"),
                    .STARTUP_WAIT         ("FALSE")
                ) dcm_sp_inst (
                    .CLKIN(clk_in_buf),
                    .CLKFB(clk0_fb),
                    .RST  (rst_i),

                    .CLK0 (clk0_dcm),
                    .CLKDV(clkdv_dcm),

                    .LOCKED(dcm_locked),

                    .PSCLK   (1'b0),
                    .PSEN    (1'b0),
                    .PSINCDEC(1'b0),
                    .DSSEN   (1'b0),

                    .CLK90   (),
                    .CLK180  (),
                    .CLK270  (),
                    .CLK2X   (),
                    .CLK2X180(),
                    .CLKFX   (),
                    .CLKFX180(),
                    .PSDONE  (),
                    .STATUS  (dcm_status)
                );

            end else if (CLK_DIVIDE == 8) begin : gen_div8

                DCM_SP #(
                    .CLKDV_DIVIDE         (8.0),
                    .CLKIN_PERIOD         (10.0),
                    .CLK_FEEDBACK         ("1X"),
                    .DESKEW_ADJUST        ("SYSTEM_SYNCHRONOUS"),
                    .DUTY_CYCLE_CORRECTION("TRUE"),
                    .STARTUP_WAIT         ("FALSE")
                ) dcm_sp_inst (
                    .CLKIN(clk_in_buf),
                    .CLKFB(clk0_fb),
                    .RST  (rst_i),

                    .CLK0 (clk0_dcm),
                    .CLKDV(clkdv_dcm),

                    .LOCKED(dcm_locked),

                    .PSCLK   (1'b0),
                    .PSEN    (1'b0),
                    .PSINCDEC(1'b0),
                    .DSSEN   (1'b0),

                    .CLK90   (),
                    .CLK180  (),
                    .CLK270  (),
                    .CLK2X   (),
                    .CLK2X180(),
                    .CLKFX   (),
                    .CLKFX180(),
                    .PSDONE  (),
                    .STATUS  (dcm_status)
                );

            end else begin : gen_div16

                DCM_SP #(
                    .CLKDV_DIVIDE         (16.0),
                    .CLKIN_PERIOD         (10.0),
                    .CLK_FEEDBACK         ("1X"),
                    .DESKEW_ADJUST        ("SYSTEM_SYNCHRONOUS"),
                    .DUTY_CYCLE_CORRECTION("TRUE"),
                    .STARTUP_WAIT         ("FALSE")
                ) dcm_sp_inst (
                    .CLKIN(clk_in_buf),
                    .CLKFB(clk0_fb),
                    .RST  (rst_i),

                    .CLK0 (clk0_dcm),
                    .CLKDV(clkdv_dcm),

                    .LOCKED(dcm_locked),

                    .PSCLK   (1'b0),
                    .PSEN    (1'b0),
                    .PSINCDEC(1'b0),
                    .DSSEN   (1'b0),

                    .CLK90   (),
                    .CLK180  (),
                    .CLK270  (),
                    .CLK2X   (),
                    .CLK2X180(),
                    .CLKFX   (),
                    .CLKFX180(),
                    .PSDONE  (),
                    .STATUS  (dcm_status)
                );

            end

        end  // -----------------------------------------------------
             //  Unsupported Divider
             // -----------------------------------------------------

        else begin : gen_clock_invalid

            assign clk_o       = 1'b0;
            assign locked_o        = 1'b0;

            assign clock_stopped_o = 1'b1;

        end

    endgenerate

endmodule
