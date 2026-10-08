`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Testbench: wb_memory_tb
 * ----------------------------------------------------------------------------
 *  Verificacion de wb_memory sin modificar RTL.
 *
 *  Dos configuraciones identicas salvo WAIT_CYCLES = 0 y 3.
 *  Cada caso dispone de su propia RAM, CPU port y Wishbone port.
 *
 *  Comprueba:
 *    - Escritura CPU y lectura WB; escritura WB y lectura CPU
 *    - Word writes, byte lanes (SEL), little-endian y retencion
 *    - Ultima palabra de memoria; rango inferior/superior invalido
 *    - Alineamiento, SEL=0 y autorizacion de mantenimiento
 *    - Pulso unico ACK/ERR mientras CYC/STB permanecen activos
 *    - Pausa de STB sin perder CYC y wait states exactos
 *    - Direccion local fuera de rango y reset sin borrar RAM
 *
 *  No prueba escrituras CPU/WB concurrentes: en el SoC esas escrituras
 *  deben ser mutuamente excluyentes por el interlock de mantenimiento.
 * ============================================================================
 */

module wb_memory_case #(
    parameter integer WAIT_CYCLES = 0
) (
    input wire clk,
    output reg done,
    output integer checks
);

    localparam [31:0] BASE = 32'h0001_0000;
    localparam [31:0] LOCAL_INVALID = 32'hDEAD_BEEF;

    reg rst;

    reg [31:0] cpu_addr;
    reg [31:0] cpu_wdata;
    reg cpu_we;
    reg [3:0] cpu_sel;
    wire [31:0] cpu_rdata;

    reg access_ok;

    reg [31:0] wb_adr;
    reg [31:0] wb_dat_i;
    reg [3:0] wb_sel;
    reg wb_we;
    reg wb_cyc;
    reg wb_stb;

    wire [31:0] wb_dat_o;
    wire wb_ack;
    wire wb_err;

    integer lane;
    integer step_index;
    reg [31:0] expected_word;
    reg [31:0] byte_mask;

    wb_memory #(
        .WORD_ADDR_WIDTH(4),
        .BASE_ADDR(BASE),
        .CPU_INVALID_DATA(LOCAL_INVALID),
        .WAIT_CYCLES(WAIT_CYCLES)
    ) dut (
        .clk_i(clk),
        .rst_i(rst),

        .cpu_addr_i(cpu_addr),
        .cpu_wdata_i(cpu_wdata),
        .cpu_we_i(cpu_we),
        .cpu_sel_i(cpu_sel),
        .cpu_rdata_o(cpu_rdata),

        .access_ok_i(access_ok),

        .adr_i(wb_adr),
        .dat_i(wb_dat_i),
        .sel_i(wb_sel),
        .we_i(wb_we),
        .cyc_i(wb_cyc),
        .stb_i(wb_stb),

        .dat_o(wb_dat_o),
        .ack_o(wb_ack),
        .err_o(wb_err)
    );


    task check_true;
        input condition;
        input [8*100-1:0] description;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display(
                    "[FAIL] WAIT_CYCLES=%0d check=%0d: %0s",
                    WAIT_CYCLES, checks, description
                );
                $display(
                    "  WB adr=%h dat=%h sel=%h we=%b cyc=%b stb=%b ack=%b err=%b",
                    wb_adr, wb_dat_i, wb_sel, wb_we, wb_cyc, wb_stb,
                    wb_ack, wb_err
                );
                $display(
                    "  CPU addr=%h wdata=%h we=%b sel=%h rdata=%h WB rdata=%h",
                    cpu_addr, cpu_wdata, cpu_we, cpu_sel, cpu_rdata, wb_dat_o
                );
                $fatal(1, "wb_memory_tb: error funcional");
            end
        end
    endtask


    task reset_dut;
        begin
            @(negedge clk);
            rst       = 1'b1;
            wb_cyc    = 1'b0;
            wb_stb    = 1'b0;
            wb_we     = 1'b0;
            cpu_we    = 1'b0;
            access_ok = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);
            rst = 1'b0;
        end
    endtask


    task cpu_store;
        input [31:0] address;
        input [31:0] data;
        input [3:0] select_bytes;
        begin
            @(negedge clk);
            cpu_addr  = address;
            cpu_wdata = data;
            cpu_sel   = select_bytes;
            cpu_we    = 1'b1;

            @(posedge clk);
            #1;
            cpu_we = 1'b0;
            #1;
        end
    endtask


    task wb_access;
        input [31:0] address;
        input [31:0] data;
        input [3:0] select_bytes;
        input write_enable;
        input authorized;
        input expected_error;
        input [31:0] expected_read;

        integer wait_index;

        begin
            @(negedge clk);

            wb_adr    = address;
            wb_dat_i  = data;
            wb_sel    = select_bytes;
            wb_we     = write_enable;
            wb_cyc    = 1'b1;
            wb_stb    = 1'b1;
            access_ok = authorized;
            cpu_we    = 1'b0;
            #1;

            if (expected_error) begin

                check_true(wb_err === 1'b1,
                    "Acceso invalido/no autorizado debe devolver ERR");
                check_true(wb_ack === 1'b0,
                    "ERR no debe ocurrir junto con ACK");

            end else begin

                // Un WAIT_CYCLES=N genera N flancos de espera
                // antes de hacer visible ACK.
                for (wait_index = 0; wait_index < WAIT_CYCLES;
                     wait_index = wait_index + 1) begin

                    check_true(
                        wb_ack === 1'b0 && wb_err === 1'b0,
                        "ACK prematuro durante estados de espera"
                    );

                    @(posedge clk);
                    #1;

                end

                check_true(
                    wb_ack === 1'b1 && wb_err === 1'b0,
                    "Falta ACK al completar los estados de espera"
                );

                if (!write_enable)
                    check_true(
                        wb_dat_o === expected_read,
                        "Dato leido por Wishbone incorrecto"
                    );

            end

            // El flanco siguiente consume ACK/ERR y, para WE=1,
            // realiza la escritura fisica en RAM.
            @(posedge clk);
            #1;

            check_true(
                wb_ack === 1'b0 && wb_err === 1'b0,
                "ACK/ERR no se debe repetir tras ser aceptado"
            );

            repeat (2) begin
                @(posedge clk);
                #1;
                check_true(
                    wb_ack === 1'b0 && wb_err === 1'b0,
                    "Respuesta duplicada con CYC/STB sostenidos"
                );
            end

            @(negedge clk);
            wb_cyc = 1'b0;
            wb_stb = 1'b0;

            @(posedge clk);
            #1;

        end
    endtask


    task paused_stb_write;
        integer k;
        begin
            @(negedge clk);

            wb_adr    = BASE + 32'd8;
            wb_dat_i  = 32'hABC0_1234;
            wb_sel    = 4'hF;
            wb_we     = 1'b1;
            wb_cyc    = 1'b1;
            wb_stb    = 1'b0;
            access_ok = 1'b1;

            for (k = 0; k < WAIT_CYCLES + 3; k = k + 1) begin

                @(posedge clk);
                #1;

                check_true(
                    wb_ack === 1'b0 && wb_err === 1'b0,
                    "STB=0 no debe provocar ACK/ERR"
                );

            end

            @(negedge clk);
            wb_stb = 1'b1;
            #1;

            for (k = 0; k < WAIT_CYCLES; k = k + 1) begin

                check_true(
                    wb_ack === 1'b0 && wb_err === 1'b0,
                    "Wait counter no debe avanzar mientras STB=0"
                );

                @(posedge clk);
                #1;

            end

            check_true(
                wb_ack === 1'b1 && wb_err === 1'b0,
                "Reanudar STB debe completar acceso con latencia correcta"
            );

            @(posedge clk);
            #1;

            check_true(
                wb_ack === 1'b0,
                "Tras ACK no debe repetirse respuesta con CYC sostenido"
            );

            @(negedge clk);
            wb_cyc = 1'b0;
            wb_stb = 1'b0;

            @(posedge clk);
            #1;

            cpu_addr = 32'd8;
            #1;

            check_true(
                cpu_rdata === 32'hABC0_1234,
                "Escritura tras pausa STB incorrecta"
            );

        end
    endtask


    initial begin

        done       = 1'b0;
        checks     = 0;

        rst        = 1'b1;

        cpu_addr   = 32'd0;
        cpu_wdata  = 32'd0;
        cpu_sel    = 4'd0;
        cpu_we     = 1'b0;

        access_ok  = 1'b1;

        wb_adr     = BASE;
        wb_dat_i   = 32'd0;
        wb_sel     = 4'hF;
        wb_we      = 1'b0;
        wb_cyc     = 1'b0;
        wb_stb     = 1'b0;

        reset_dut();

        // CPU escribe; Wishbone lee.
        cpu_store(32'd0, 32'h1234_5678, 4'hF);

        cpu_addr = 32'd0;
        #1;
        check_true(cpu_rdata === 32'h1234_5678,
            "Read-after-write por CPU incorrecto");

        wb_access(BASE, 32'd0, 4'hF, 1'b0, 1'b1, 1'b0,
            32'h1234_5678);


        // Wishbone escribe; CPU lee.
        wb_access(BASE + 32'd4, 32'h1122_3344,
            4'hF, 1'b1, 1'b1, 1'b0, 32'd0);

        cpu_addr = 32'd4;
        #1;
        check_true(cpu_rdata === 32'h1122_3344,
            "CPU debe observar escritura Wishbone");


        // SEL parcial: cada bit afecta solo su byte lane.
        expected_word = 32'h1122_3344;

        for (lane = 0; lane < 4; lane = lane + 1) begin

            wb_access(
                BASE + 32'd4, 32'hAABB_CCDD, (4'b0001 << lane),
                1'b1, 1'b1, 1'b0, 32'd0
            );

            byte_mask = 32'h0000_00FF << (lane * 8);

            expected_word = (expected_word & ~byte_mask) |
                            (32'hAABB_CCDD & byte_mask);

            cpu_addr = 32'd4;
            #1;

            check_true(
                cpu_rdata === expected_word,
                "SEL debe modificar solo el byte seleccionado"
            );

        end

        wb_access(BASE + 32'd4, 32'd0, 4'hF,
            1'b0, 1'b1, 1'b0, expected_word);


        // La CPU tambien puede escribir bytes individuales.
        cpu_store(32'd0, 32'h00EE_00AA, 4'b0101);

        cpu_addr = 32'd0;
        #1;
        check_true(
            cpu_rdata === 32'h12EE_56AA,
            "SEL local de CPU incorrecto"
        );

        wb_access(BASE, 32'd0, 4'hF, 1'b0, 1'b1, 1'b0,
            32'h12EE_56AA);


        // Borde superior: ultima palabra fisica en 64 bytes.
        wb_access(BASE + 32'd60, 32'hCAF0_BABE, 4'hF,
            1'b1, 1'b1, 1'b0, 32'd0);

        cpu_addr = 32'd60;
        #1;
        check_true(
            cpu_rdata === 32'hCAF0_BABE,
            "Ultima palabra valida inaccesible"
        );


        // Direcciones invalidas y SEL=0: ERR y sin escrituras.
        wb_access(BASE + 32'd64, 32'hFFFF_FFFF, 4'hF,
            1'b1, 1'b1, 1'b1, 32'd0);

        wb_access(BASE - 32'd4, 32'hFFFF_FFFF, 4'hF,
            1'b1, 1'b1, 1'b1, 32'd0);

        wb_access(BASE + 32'd1, 32'hFFFF_FFFF, 4'hF,
            1'b1, 1'b1, 1'b1, 32'd0);

        wb_access(BASE + 32'd4, 32'hFFFF_FFFF, 4'h0,
            1'b1, 1'b1, 1'b1, 32'd0);

        cpu_addr = 32'd60;
        #1;
        check_true(
            cpu_rdata === 32'hCAF0_BABE,
            "Acceso fuera de rango corrompio ultima palabra"
        );


        // Mantenimiento denegado: tanto lectura como escritura generan ERR.
        wb_access(BASE + 32'd4, 32'd0, 4'hF,
            1'b0, 1'b0, 1'b1, 32'd0);

        wb_access(BASE + 32'd4, 32'h0000_0000, 4'hF,
            1'b1, 1'b0, 1'b1, 32'd0);

        wb_access(BASE + 32'd4, 32'd0, 4'hF,
            1'b0, 1'b1, 1'b0, expected_word);


        // Lectura local fuera de capacidad.
        cpu_addr = 32'd64;
        #1;
        check_true(
            cpu_rdata === LOCAL_INVALID,
            "Lectura local fuera de rango incorrecta"
        );

        // Escritura fuera de capacidad no debe corromper palabra valida.
        cpu_store(32'd64, 32'h9876_5432, 4'hF);
        cpu_addr = 32'd0;
        #1;
        check_true(
            cpu_rdata === 32'h12EE_56AA,
            "Escritura local fuera de rango modifico memoria valida"
        );


        // Pausa con CYC alto y STB bajo.
        paused_stb_write();


        // Reset limpia la FSM Wishbone pero conserva contenido de RAM.
        reset_dut();

        cpu_addr = 32'd4;
        #1;
        check_true(
            cpu_rdata === expected_word,
            "Reset no debe borrar contenido de RAM"
        );

        wb_access(BASE + 32'd8, 32'd0, 4'hF,
            1'b0, 1'b1, 1'b0, 32'hABC0_1234);

        $display(
            "[PASS] wb_memory WAIT_CYCLES=%0d Checks=%0d",
            WAIT_CYCLES, checks
        );

        done = 1'b1;

    end

endmodule


module wb_memory_tb;

    reg clk;

    wire done_zero;
    wire done_three;

    wire [31:0] checks_zero;
    wire [31:0] checks_three;

    wb_memory_case #(
        .WAIT_CYCLES(0)
    ) instant_memory (
        .clk(clk),
        .done(done_zero),
        .checks(checks_zero)
    );

    wb_memory_case #(
        .WAIT_CYCLES(3)
    ) delayed_memory (
        .clk(clk),
        .done(done_three),
        .checks(checks_three)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin

        $dumpfile("SIM/out/wb_memory_tb.vcd");
        $dumpvars(0, wb_memory_tb);

        $display("============================================================");
        $display(" wb_memory_tb");
        $display("============================================================");

        wait (done_zero && done_three);

        $display("============================================================");
        $display(" Checks: %0d", checks_zero + checks_three);
        $display(" Errors: 0");
        $display(" [PASS] wb_memory_tb COMPLETO");
        $display("============================================================");

        $finish;

    end

    initial begin
        #200000;
        $fatal(1, "Timeout del testbench wb_memory_tb");
    end

endmodule

`default_nettype wire
