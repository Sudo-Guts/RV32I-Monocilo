`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  data_memory_wbs_tb - integracion DMEM fisica + adaptador Wishbone
 * ----------------------------------------------------------------------------
 *  RAM 256 palabras, base bus 0x0001_0000, WAIT_CYCLES=2.
 *  Comprueba que CPU y Wishbone observan LOS MISMOS cuatro bancos de bytes,
 *  retencion de datos, SEL, limites, alineacion, autorizacion y handshake.
 *  Los dos modulos son hermanos, como en cpu_soc.v.
 * ============================================================================
 */

module data_memory_wbs_tb;

    localparam [31:0] BASE = 32'h0001_0000;
    localparam [31:0] BYTES = 32'd1024;
    localparam integer WAIT_CYCLES = 2;

    reg CLK_I;
    reg RST_I;

    // Puerto local CPU.
    reg [31:0] CPU_ADDR_I;
    reg [31:0] CPU_WDATA_I;
    reg CPU_WE_I;
    reg [3:0] CPU_BYTE_ENABLE_I;
    wire [31:0] CPU_RDATA_O;

    // Wishbone externo S1.
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

    // Interfaz local entre adaptador y memoria fisica.
    wire [31:0] MEM_ADDR_O;
    wire [31:0] MEM_WDATA_O;
    wire [3:0] MEM_SEL_O;
    wire MEM_WE_O;
    wire [31:0] MEM_RDATA_I;

    integer checks;
    integer k;

    data_memory #(
        .WORD_ADDR_WIDTH(8)
    ) ram_inst (
        .clk_i            (CLK_I),
        .cpu_addr_i       (CPU_ADDR_I),
        .cpu_wdata_i      (CPU_WDATA_I),
        .cpu_we_i         (CPU_WE_I),
        .cpu_byte_enable_i(CPU_BYTE_ENABLE_I),
        .cpu_rdata_o      (CPU_RDATA_O),
        .wb_addr_i        (MEM_ADDR_O),
        .wb_wdata_i       (MEM_WDATA_O),
        .wb_sel_i         (MEM_SEL_O),
        .wb_we_i          (MEM_WE_O),
        .wb_rdata_o       (MEM_RDATA_I)
    );

    data_memory_wbs #(
        .WORD_ADDR_WIDTH(8),
        .WAIT_CYCLES(WAIT_CYCLES)
    ) dut (
        .CLK_I(CLK_I),
        .RST_I(RST_I),
        .ACCESS_OK_I(ACCESS_OK_I),
        .ADR_I(ADR_I),
        .DAT_I(DAT_I),
        .SEL_I(SEL_I),
        .WE_I(WE_I),
        .CYC_I(CYC_I),
        .STB_I(STB_I),
        .DAT_O(DAT_O),
        .ACK_O(ACK_O),
        .ERR_O(ERR_O),
        .MEM_ADDR_O(MEM_ADDR_O),
        .MEM_WDATA_O(MEM_WDATA_O),
        .MEM_SEL_O(MEM_SEL_O),
        .MEM_WE_O(MEM_WE_O),
        .MEM_RDATA_I(MEM_RDATA_I)
    );

    always #5 CLK_I = ~CLK_I;

    task check_true;
        input condition;
        input [8*120-1:0] description;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("[FAIL] DMEM check=%0d: %0s", checks, description);
                $display(
                    "  CPU addr=%h rdata=%h we=%b sel=%h | WB addr=%h data=%h sel=%h we=%b",
                    CPU_ADDR_I, CPU_RDATA_O, CPU_WE_I, CPU_BYTE_ENABLE_I,
                    ADR_I, DAT_I, SEL_I, WE_I
                );
                $display(
                    "  MEM addr=%h rdata=%h we=%b | CYC=%b STB=%b ACK=%b ERR=%b",
                    MEM_ADDR_O, MEM_RDATA_I, MEM_WE_O,
                    CYC_I, STB_I, ACK_O, ERR_O
                );
                $fatal(1, "data_memory_wbs_tb: error funcional");
            end
        end
    endtask

    task reset_control;
        begin
            @(negedge CLK_I);
            RST_I=1'b1;
            CYC_I=1'b0;
            STB_I=1'b0;
            CPU_WE_I=1'b0;
            repeat (2) @(posedge CLK_I);
            #1;
            @(negedge CLK_I);
            RST_I=1'b0;
        end
    endtask

    task cpu_write;
        input [31:0] address;
        input [31:0] data;
        input [3:0] lanes;
        begin
            @(negedge CLK_I);
            CPU_ADDR_I=address;
            CPU_WDATA_I=data;
            CPU_BYTE_ENABLE_I=lanes;
            CPU_WE_I=1'b1;
            @(posedge CLK_I);
            #1;
            CPU_WE_I=1'b0;
        end
    endtask

    task wb_access;
        input [31:0] address;
        input [31:0] data;
        input [3:0] lanes;
        input write_enable;
        input authorized;
        input expect_error;
        input [31:0] read_value;
        integer wait_index;
        begin
            @(negedge CLK_I);
            ADR_I=address;
            DAT_I=data;
            SEL_I=lanes;
            WE_I=write_enable;
            ACCESS_OK_I=authorized;
            CYC_I=1'b1;
            STB_I=1'b1;
            CPU_WE_I=1'b0;
            #1;

            if (expect_error) begin
                check_true(
                    ERR_O===1'b1 && ACK_O===1'b0 && MEM_WE_O===1'b0,
                    "ERR debe rechazar transferencia sin escritura fisica"
                );
            end else begin
                check_true(
                    MEM_ADDR_O === (address - BASE),
                    "Adaptador debe convertir direccion WB absoluta a local"
                );

                for (wait_index=0; wait_index<WAIT_CYCLES;
                     wait_index=wait_index+1) begin
                    check_true(ACK_O===1'b0 && ERR_O===1'b0,
                               "ACK prematuro durante WAIT_CYCLES");
                    @(posedge CLK_I);
                    #1;
                end

                check_true(ACK_O===1'b1 && ERR_O===1'b0,
                           "Falta ACK tras WAIT_CYCLES");
                check_true(MEM_WE_O === write_enable,
                           "MEM_WE solo debe pulsar al confirmar escritura");

                if (!write_enable)
                    check_true(DAT_O === read_value,
                               "Lectura Wishbone incorrecta");
            end

            @(posedge CLK_I);
            #1;
            check_true(ACK_O===1'b0 && ERR_O===1'b0 && MEM_WE_O===1'b0,
                       "Terminacion debe durar una sola transaccion");

            repeat (2) begin
                @(posedge CLK_I);
                #1;
                check_true(ACK_O===1'b0 && ERR_O===1'b0,
                           "ACK/ERR duplicado mientras CYC permanece activo");
            end

            @(negedge CLK_I);
            CYC_I=1'b0;
            STB_I=1'b0;
            @(posedge CLK_I);
            #1;
        end
    endtask

    initial begin
        CLK_I=1'b0;
        RST_I=1'b1;

        CPU_ADDR_I=32'd0;
        CPU_WDATA_I=32'd0;
        CPU_WE_I=1'b0;
        CPU_BYTE_ENABLE_I=4'b0000;

        ACCESS_OK_I=1'b1;
        ADR_I=BASE;
        DAT_I=32'd0;
        SEL_I=4'hF;
        WE_I=1'b0;
        CYC_I=1'b0;
        STB_I=1'b0;

        checks=0;
        $dumpfile("SIM/out/data_memory_wbs_tb.vcd");
        $dumpvars(0,data_memory_wbs_tb);
        $display("============================================================");
        $display(" data_memory_wbs_tb");
        $display("============================================================");

        reset_control();

        // CPU -> RAM -> Wishbone. Word completo.
        cpu_write(32'd0,32'h1234_5678,4'hF);
        CPU_ADDR_I=32'd0;
        #1;
        check_true(CPU_RDATA_O===32'h1234_5678,
                   "CPU write/read completo incorrecto");
        wb_access(BASE,32'd0,4'hF,1'b0,1'b1,1'b0,32'h1234_5678);

        // Wishbone -> RAM -> CPU.
        wb_access(BASE+32'd4,32'h1122_3344,4'hF,1'b1,1'b1,1'b0,32'd0);
        CPU_ADDR_I=32'd4;
        #1;
        check_true(CPU_RDATA_O===32'h1122_3344,
                   "CPU no observa escritura Wishbone");

        // CPU SB/SH emulados con SEL por byte lane.
        cpu_write(32'd4,32'hAABB_0000,4'b1100);
        CPU_ADDR_I=32'd4;
        #1;
        check_true(CPU_RDATA_O===32'hAABB_3344,
                   "CPU byte enables no preservan bytes inferiores");

        // Wishbone actualiza lanes 0 y 2 de la MISMA palabra.
        wb_access(BASE+32'd4,32'h1020_3040,4'b0101,1'b1,1'b1,1'b0,32'd0);
        CPU_ADDR_I=32'd4;
        #1;
        check_true(CPU_RDATA_O===32'hAA20_3340,
                   "Wishbone SEL no preserva bytes ajenos");
        wb_access(BASE+32'd4,32'd0,4'hF,1'b0,1'b1,1'b0,32'hAA20_3340);

        // Ultima palabra implementada y limite superior fuera de capacidad.
        wb_access(BASE+BYTES-32'd4,32'hCAFE_BABE,4'hF,1'b1,1'b1,1'b0,32'd0);
        CPU_ADDR_I=BYTES-32'd4;
        #1;
        check_true(CPU_RDATA_O===32'hCAFE_BABE,
                   "Ultima palabra fisica inaccesible");

        wb_access(BASE+BYTES,32'hFFFF_FFFF,4'hF,1'b1,1'b1,1'b1,32'd0);
        wb_access(BASE-32'd4,32'hFFFF_FFFF,4'hF,1'b1,1'b1,1'b1,32'd0);
        wb_access(BASE+32'd1,32'hFFFF_FFFF,4'hF,1'b1,1'b1,1'b1,32'd0);
        wb_access(BASE+32'd4,32'hFFFF_FFFF,4'h0,1'b1,1'b1,1'b1,32'd0);

        CPU_ADDR_I=BYTES-32'd4;
        #1;
        check_true(CPU_RDATA_O===32'hCAFE_BABE,
                   "Operaciones rechazadas modificaron ultima palabra");

        // CPU running: ACCESS_OK=0; el adaptador debe rechazar mantenimiento.
        wb_access(BASE+32'd4,32'hFFFF_FFFF,4'hF,1'b1,1'b0,1'b1,32'd0);
        wb_access(BASE+32'd4,32'd0,4'hF,1'b0,1'b0,1'b1,32'd0);

        CPU_ADDR_I=32'd4;
        #1;
        check_true(CPU_RDATA_O===32'hAA20_3340,
                   "Escritura denegada corrompio datos");

        // CPU fuera del rango real debe recibir cero sin alias de direccion.
        CPU_ADDR_I=BYTES;
        #1;
        check_true(CPU_RDATA_O===32'd0,
                   "Lectura CPU fuera de rango debe ser cero");
        cpu_write(BYTES,32'hDEAD_BEEF,4'hF);
        CPU_ADDR_I=32'd0;
        #1;
        check_true(CPU_RDATA_O===32'h1234_5678,
                   "Escritura CPU fuera de rango altero memoria");

        // STB pausado mantiene CYC pero no permite aceptar escrituras.
        @(negedge CLK_I);
        ADR_I=BASE+32'd8;
        DAT_I=32'h0123_4567;
        SEL_I=4'hF;
        WE_I=1'b1;
        ACCESS_OK_I=1'b1;
        CYC_I=1'b1;
        STB_I=1'b0;

        repeat (4) begin
            @(posedge CLK_I);
            #1;
            check_true(ACK_O===1'b0 && ERR_O===1'b0 &&
                       MEM_WE_O===1'b0,
                       "Pausa STB no debe completar ni escribir");
        end

        @(negedge CLK_I);
        STB_I=1'b1;
        #1;
        for(k=0;k<WAIT_CYCLES;k=k+1) begin
            check_true(ACK_O===1'b0,
                       "El conteo de espera no debe avanzar con STB=0");
            @(posedge CLK_I);
            #1;
        end
        check_true(ACK_O===1'b1 && MEM_WE_O===1'b1,
                   "Escritura tras reanudacion de STB");
        @(posedge CLK_I);
        #1;
        @(negedge CLK_I);
        CYC_I=1'b0;
        STB_I=1'b0;
        CPU_ADDR_I=32'd8;
        #1;
        check_true(CPU_RDATA_O===32'h0123_4567,
                   "La RAM fisica no recibio escritura tras STB pausado");

        // Reset de control no borra bancos de memoria.
        reset_control();
        CPU_ADDR_I=32'd4;
        #1;
        check_true(CPU_RDATA_O===32'hAA20_3340,
                   "Reset borro datos de RAM fisica");

        $display("============================================================");
        $display(" Checks: %0d",checks);
        $display(" Errors: 0");
        $display(" [PASS] data_memory_wbs_tb COMPLETO");
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1,"Timeout data_memory_wbs_tb");
    end

endmodule
`default_nettype wire
