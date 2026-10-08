`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Testbench - instruction_memory_wbs
 * ----------------------------------------------------------------------------
 *  IMEM real: 512 palabras x 32 bits = 2048 bytes.
 *  WAIT_CYCLES=2 para comprobar la latencia del puerto Wishbone.
 *
 *  Casos:
 *    - Escritura Wishbone y lectura local combinacional de instrucciones
 *    - Lectura Wishbone, SEL parcial y preservacion de byte lanes
 *    - Primer y ultimo word de memoria
 *    - Error por direccion fisica fuera de rango, desalineamiento o SEL=0
 *    - Autorizacion ACCESS_OK_I
 *    - ACK/ERR unico por ciclo; STB pausado; reset sin borrar RAM
 *    - Lectura local fuera de rango devuelve NOP RV32I
 *
 *  Este TB verifica el wrapper, no el interlock del cpu_soc completo.
 * ============================================================================
 */

module instruction_memory_wbs_tb;

    localparam integer WAIT_CYCLES = 2;
    localparam [31:0] IMEM_BYTES  = 32'd2048;
    localparam [31:0] INVALID_INSTR = 32'h0000_0013;

    reg CLK_I;
    reg RST_I;

    reg [31:0] CPU_ADDR_I;
    wire [31:0] CPU_RDATA_O;
    reg ACCESS_OK_I;

    reg [31:0] ADR_I;
    reg [31:0] DAT_I;
    reg [3:0] SEL_I;
    reg WE_I;
    reg CYC_I;
    reg STB_I;

    wire [31:0] DAT_O;
    wire ACK_O;
    wire ERR_O;

    integer checks;
    integer k;

    instruction_memory_wbs #(
        .WAIT_CYCLES(WAIT_CYCLES)
    ) dut (
        .CLK_I(CLK_I),
        .RST_I(RST_I),
        .CPU_ADDR_I(CPU_ADDR_I),
        .CPU_RDATA_O(CPU_RDATA_O),
        .ACCESS_OK_I(ACCESS_OK_I),
        .ADR_I(ADR_I),
        .DAT_I(DAT_I),
        .SEL_I(SEL_I),
        .WE_I(WE_I),
        .CYC_I(CYC_I),
        .STB_I(STB_I),
        .DAT_O(DAT_O),
        .ACK_O(ACK_O),
        .ERR_O(ERR_O)
    );

    always #5 CLK_I = ~CLK_I;

    task check_true;
        input condition;
        input [8*100-1:0] description;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("[FAIL] IMEM check=%0d: %0s", checks, description);
                $display(
                    "  CPU ADR=%h RDATA=%h | WB ADR=%h DAT=%h SEL=%h WE=%b CYC=%b STB=%b",
                    CPU_ADDR_I, CPU_RDATA_O, ADR_I, DAT_I, SEL_I, WE_I,
                    CYC_I, STB_I
                );
                $display(
                    "  WB RDATA=%h ACK=%b ERR=%b ACCESS_OK=%b",
                    DAT_O, ACK_O, ERR_O, ACCESS_OK_I
                );
                $fatal(1, "instruction_memory_wbs_tb fallo");
            end
        end
    endtask

    task reset_design;
        begin
            @(negedge CLK_I);
            RST_I = 1'b1;
            CYC_I = 1'b0;
            STB_I = 1'b0;
            repeat (2) @(posedge CLK_I);
            #1;
            @(negedge CLK_I);
            RST_I = 1'b0;
        end
    endtask

    task wb_operation;
        input [31:0] address;
        input [31:0] write_data;
        input [3:0] byte_select;
        input write_enable;
        input access_allowed;
        input expect_error;
        input [31:0] expect_read_data;

        integer wait_index;

        begin
            @(negedge CLK_I);
            ADR_I = address;
            DAT_I = write_data;
            SEL_I = byte_select;
            WE_I = write_enable;
            ACCESS_OK_I = access_allowed;
            CYC_I = 1'b1;
            STB_I = 1'b1;
            #1;

            if (expect_error) begin
                check_true(
                    ERR_O === 1'b1 && ACK_O === 1'b0,
                    "Acceso rechazado debe terminar con ERR sin ACK"
                );
            end else begin
                for (wait_index = 0; wait_index < WAIT_CYCLES;
                     wait_index = wait_index + 1) begin
                    check_true(
                        ACK_O === 1'b0 && ERR_O === 1'b0,
                        "ACK prematuro durante WAIT_CYCLES"
                    );
                    @(posedge CLK_I);
                    #1;
                end

                check_true(
                    ACK_O === 1'b1 && ERR_O === 1'b0,
                    "ACK ausente tras WAIT_CYCLES"
                );

                if (!write_enable) begin
                    check_true(
                        DAT_O === expect_read_data,
                        "Dato Wishbone incorrecto"
                    );
                end
            end

            @(posedge CLK_I);
            #1;

            check_true(
                ACK_O === 1'b0 && ERR_O === 1'b0,
                "ACK/ERR debe desactivarse tras terminar transferencia"
            );

            repeat (2) begin
                @(posedge CLK_I);
                #1;
                check_true(
                    ACK_O === 1'b0 && ERR_O === 1'b0,
                    "ACK/ERR repetido con CYC/STB sostenidos"
                );
            end

            @(negedge CLK_I);
            CYC_I = 1'b0;
            STB_I = 1'b0;
            @(posedge CLK_I);
            #1;
        end
    endtask

    initial begin
        CLK_I = 1'b0;
        RST_I = 1'b1;

        CPU_ADDR_I = 32'd0;
        ACCESS_OK_I = 1'b1;

        ADR_I = 32'd0;
        DAT_I = 32'd0;
        SEL_I = 4'hF;
        WE_I = 1'b0;
        CYC_I = 1'b0;
        STB_I = 1'b0;

        checks = 0;

        $dumpfile("SIM/out/instruction_memory_wbs_tb.vcd");
        $dumpvars(0, instruction_memory_wbs_tb);

        $display("============================================================");
        $display(" instruction_memory_wbs_tb");
        $display("============================================================");

        reset_design();

        // En IMEM el puerto local de la CPU es exclusivamente de lectura.
        wb_operation(32'h0000_0000, 32'h0000_0013, 4'hF,
                     1'b1, 1'b1, 1'b0, 32'd0);

        CPU_ADDR_I = 32'd0;
        #1;
        check_true(CPU_RDATA_O === 32'h0000_0013,
                   "El puerto local debe observar la instruccion programada");

        wb_operation(32'h0000_0004, 32'h1122_3344, 4'hF,
                     1'b1, 1'b1, 1'b0, 32'd0);
        wb_operation(32'h0000_0004, 32'd0, 4'hF,
                     1'b0, 1'b1, 1'b0, 32'h1122_3344);

        // Solo deben escribirse las lanes 0 y 2.
        wb_operation(32'h0000_0004, 32'hAABB_CCDD, 4'b0101,
                     1'b1, 1'b1, 1'b0, 32'd0);

        CPU_ADDR_I = 32'd4;
        #1;
        check_true(CPU_RDATA_O === 32'h11BB_33DD,
                   "SEL debe conservar los bytes no seleccionados");
        wb_operation(32'h0000_0004, 32'd0, 4'hF,
                     1'b0, 1'b1, 1'b0, 32'h11BB_33DD);

        // Comprobar la ultima palabra de los 2 KiB fisicos.
        wb_operation(IMEM_BYTES - 32'd4, 32'hCAFE_BABE, 4'hF,
                     1'b1, 1'b1, 1'b0, 32'd0);
        CPU_ADDR_I = IMEM_BYTES - 32'd4;
        #1;
        check_true(CPU_RDATA_O === 32'hCAFE_BABE,
                   "Ultima palabra fisica no programable");

        wb_operation(IMEM_BYTES, 32'hFFFF_FFFF, 4'hF,
                     1'b1, 1'b1, 1'b1, 32'd0);
        wb_operation(32'h0000_0001, 32'hFFFF_FFFF, 4'hF,
                     1'b1, 1'b1, 1'b1, 32'd0);
        wb_operation(32'h0000_0004, 32'hFFFF_FFFF, 4'h0,
                     1'b1, 1'b1, 1'b1, 32'd0);

        CPU_ADDR_I = IMEM_BYTES - 32'd4;
        #1;
        check_true(CPU_RDATA_O === 32'hCAFE_BABE,
                   "Error Wishbone no debe corromper ultimo word");

        // ACCESS_OK_I=0: ninguna lectura/escritura Wishbone permitida.
        wb_operation(32'h0000_0004, 32'hFFFF_FFFF, 4'hF,
                     1'b1, 1'b0, 1'b1, 32'd0);
        wb_operation(32'h0000_0004, 32'd0, 4'hF,
                     1'b0, 1'b0, 1'b1, 32'd0);

        CPU_ADDR_I = 32'd4;
        #1;
        check_true(CPU_RDATA_O === 32'h11BB_33DD,
                   "Acceso no autorizado no debe alterar memoria");

        wb_operation(32'h0000_0004, 32'd0, 4'hF,
                     1'b0, 1'b1, 1'b0, 32'h11BB_33DD);

        CPU_ADDR_I = IMEM_BYTES;
        #1;
        check_true(CPU_RDATA_O === INVALID_INSTR,
                   "Lectura local fuera de rango debe devolver NOP");

        // CYC mantenido con STB=0 no puede producir ACK.
        @(negedge CLK_I);
        ADR_I = 32'h0000_0008;
        DAT_I = 32'h1234_5678;
        SEL_I = 4'hF;
        WE_I  = 1'b1;
        ACCESS_OK_I = 1'b1;
        CYC_I = 1'b1;
        STB_I = 1'b0;

        repeat (WAIT_CYCLES + 3) begin
            @(posedge CLK_I);
            #1;
            check_true(ACK_O === 1'b0 && ERR_O === 1'b0,
                       "STB bajo no debe crear una respuesta");
        end

        @(negedge CLK_I);
        STB_I = 1'b1;
        #1;

        for (k = 0; k < WAIT_CYCLES; k = k + 1) begin
            check_true(ACK_O === 1'b0 && ERR_O === 1'b0,
                       "Reactivar STB debe respetar WAIT_CYCLES");
            @(posedge CLK_I);
            #1;
        end

        check_true(ACK_O === 1'b1 && ERR_O === 1'b0,
                   "Reanudar STB debe conducir a ACK");

        @(posedge CLK_I);
        #1;

        @(negedge CLK_I);
        CYC_I = 1'b0;
        STB_I = 1'b0;

        CPU_ADDR_I = 32'd8;
        #1;
        check_true(CPU_RDATA_O === 32'h1234_5678,
                   "Programacion tras pausa STB incorrecta");

        // El reset del control no debe borrar instrucciones programadas.
        reset_design();

        CPU_ADDR_I = 32'd4;
        #1;
        check_true(CPU_RDATA_O === 32'h11BB_33DD,
                   "Reset no debe borrar instrucciones");

        $display("============================================================");
        $display(" Checks: %0d", checks);
        $display(" Errors: 0");
        $display(" [PASS] instruction_memory_wbs_tb COMPLETO");
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Timeout de instruction_memory_wbs_tb");
    end

endmodule

`default_nettype wire
