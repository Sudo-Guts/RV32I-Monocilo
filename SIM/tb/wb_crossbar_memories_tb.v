`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  wb_crossbar_memories_tb - integracion real del interconnect y las memorias
 * ----------------------------------------------------------------------------
 *  4 Wishbone Masters sinteticos -> wb_crossbar -> S0 IMEM, S1 DMEM
 *  Las RAM fisicas y sus adaptadores WBS son instancias hermanas, como
 *  en cpu_soc.v. No hay mocks en S0 ni S1.
 *
 *  Verificacion:
 *   - Direccion absoluta WB -> direccion local de RAM
 *   - Lectura/escritura a las RAM reales desde diferentes Masters
 *   - Seleccion SEL y puerto directo CPU
 *   - Error fisico fuera de rango y error de decode
 *   - Permisos ACCESS_OK_I durante ejecucion CPU
 *   - Dos Slaves activos simultaneamente (dos canales)
 *   - Contencion de dos Masters por una sola DMEM y rearme
 *   - Reset del control sin borrar memoria fisica
 *
 *  S2 y S3 no se verifican aqui: sus interfaces se evaluaran
 *  en la prueba de integracion Loader/Debugger.
 * ============================================================================
 */

module wb_crossbar_memories_tb;

    localparam [31:0] IMEM_BASE = 32'h0000_0000;
    localparam [31:0] DMEM_BASE = 32'h0001_0000;

    reg CLK_I;
    reg RST_I;

    // Masters Wishbone empaquetados M0..M3.
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

    // Slaves Wishbone S0..S3.
    wire [127:0] S_ADR_O;
    wire [127:0] S_DAT_O;
    wire [15:0]  S_SEL_O;
    wire [3:0]   S_WE_O;
    wire [3:0]   S_CYC_O;
    wire [3:0]   S_STB_O;

    wire [127:0] S_DAT_I;
    wire [3:0]   S_ACK_I;
    wire [3:0]   S_ERR_I;

    // CPU local (simulado) y permisos de mantenimiento.
    reg [31:0] imem_cpu_addr;
    wire [31:0] imem_cpu_rdata;
    reg imem_access_ok;

    reg [31:0] dmem_cpu_addr;
    reg [31:0] dmem_cpu_wdata;
    reg dmem_cpu_we;
    reg [3:0] dmem_cpu_sel;
    wire [31:0] dmem_cpu_rdata;
    reg dmem_access_ok;

    // Puerto MEM IMEM hacia su RAM fisica.
    wire [31:0] imem_mem_addr;
    wire [31:0] imem_mem_wdata;
    wire [31:0] imem_mem_rdata;
    wire [3:0] imem_mem_sel;
    wire imem_mem_we;

    // Puerto MEM DMEM hacia su RAM fisica.
    wire [31:0] dmem_mem_addr;
    wire [31:0] dmem_mem_wdata;
    wire [31:0] dmem_mem_rdata;
    wire [3:0] dmem_mem_sel;
    wire dmem_mem_we;

    integer checks;
    reg simultaneous_slaves_seen;

    wb_crossbar dut (
        .CLK_I(CLK_I),
        .RST_I(RST_I),

        .M_ADR_I(M_ADR_I),
        .M_DAT_I(M_DAT_I),
        .M_SEL_I(M_SEL_I),
        .M_WE_I(M_WE_I),
        .M_CYC_I(M_CYC_I),
        .M_STB_I(M_STB_I),
        .M_DAT_O(M_DAT_O),
        .M_ACK_O(M_ACK_O),
        .M_ERR_O(M_ERR_O),
        .M_TIMEOUT_O(M_TIMEOUT_O),

        .S_ADR_O(S_ADR_O),
        .S_DAT_O(S_DAT_O),
        .S_SEL_O(S_SEL_O),
        .S_WE_O(S_WE_O),
        .S_CYC_O(S_CYC_O),
        .S_STB_O(S_STB_O),
        .S_DAT_I(S_DAT_I),
        .S_ACK_I(S_ACK_I),
        .S_ERR_I(S_ERR_I)
    );

    // S0: Wishbone -> IMEM real.
    instruction_memory_wbs #(
        .WORD_ADDR_WIDTH(9),
        .WAIT_CYCLES(2)
    ) imem_wbs_inst (
        .CLK_I(CLK_I),
        .RST_I(RST_I),
        .ACCESS_OK_I(imem_access_ok),
        .ADR_I(S_ADR_O[31:0]),
        .DAT_I(S_DAT_O[31:0]),
        .SEL_I(S_SEL_O[3:0]),
        .WE_I(S_WE_O[0]),
        .CYC_I(S_CYC_O[0]),
        .STB_I(S_STB_O[0]),
        .DAT_O(S_DAT_I[31:0]),
        .ACK_O(S_ACK_I[0]),
        .ERR_O(S_ERR_I[0]),
        .MEM_ADDR_O(imem_mem_addr),
        .MEM_WDATA_O(imem_mem_wdata),
        .MEM_SEL_O(imem_mem_sel),
        .MEM_WE_O(imem_mem_we),
        .MEM_RDATA_I(imem_mem_rdata)
    );

    instruction_memory #(
        .WORD_ADDR_WIDTH(9)
    ) imem_inst (
        .clk_i(CLK_I),
        .cpu_addr_i(imem_cpu_addr),
        .cpu_rdata_o(imem_cpu_rdata),
        .wb_addr_i(imem_mem_addr),
        .wb_wdata_i(imem_mem_wdata),
        .wb_sel_i(imem_mem_sel),
        .wb_we_i(imem_mem_we),
        .wb_rdata_o(imem_mem_rdata)
    );

    // S1: Wishbone -> DMEM real.
    data_memory_wbs #(
        .WORD_ADDR_WIDTH(8),
        .WAIT_CYCLES(2)
    ) dmem_wbs_inst (
        .CLK_I(CLK_I),
        .RST_I(RST_I),
        .ACCESS_OK_I(dmem_access_ok),
        .ADR_I(S_ADR_O[63:32]),
        .DAT_I(S_DAT_O[63:32]),
        .SEL_I(S_SEL_O[7:4]),
        .WE_I(S_WE_O[1]),
        .CYC_I(S_CYC_O[1]),
        .STB_I(S_STB_O[1]),
        .DAT_O(S_DAT_I[63:32]),
        .ACK_O(S_ACK_I[1]),
        .ERR_O(S_ERR_I[1]),
        .MEM_ADDR_O(dmem_mem_addr),
        .MEM_WDATA_O(dmem_mem_wdata),
        .MEM_SEL_O(dmem_mem_sel),
        .MEM_WE_O(dmem_mem_we),
        .MEM_RDATA_I(dmem_mem_rdata)
    );

    data_memory #(
        .WORD_ADDR_WIDTH(8)
    ) dmem_inst (
        .clk_i(CLK_I),
        .cpu_addr_i(dmem_cpu_addr),
        .cpu_wdata_i(dmem_cpu_wdata),
        .cpu_we_i(dmem_cpu_we),
        .cpu_byte_enable_i(dmem_cpu_sel),
        .cpu_rdata_o(dmem_cpu_rdata),
        .wb_addr_i(dmem_mem_addr),
        .wb_wdata_i(dmem_mem_wdata),
        .wb_sel_i(dmem_mem_sel),
        .wb_we_i(dmem_mem_we),
        .wb_rdata_o(dmem_mem_rdata)
    );

    // S2/S3 fuera del alcance de este testbench. ERR defensivo si se acceden.
    assign S_DAT_I[95:64]  = 32'd0;
    assign S_DAT_I[127:96] = 32'd0;
    assign S_ACK_I[3:2] = 2'b00;
    assign S_ERR_I[2] = S_CYC_O[2] && S_STB_O[2];
    assign S_ERR_I[3] = S_CYC_O[3] && S_STB_O[3];

    always #5 CLK_I = ~CLK_I;

    task check_true;
        input condition;
        input [8*120-1:0] description;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("[FAIL] check=%0d: %0s", checks, description);
                $display(
                    " M_ACK=%b M_ERR=%b M_TIMEOUT=%b M_CYC=%b M_STB=%b",
                    M_ACK_O, M_ERR_O, M_TIMEOUT_O, M_CYC_I, M_STB_I
                );
                $display(
                    " S_ACK=%b S_ERR=%b S_CYC=%b S_STB=%b",
                    S_ACK_I, S_ERR_I, S_CYC_O, S_STB_O
                );
                $fatal(1, "wb_crossbar_memories_tb fallo");
            end
        end
    endtask

    // Invariantes globales y registro de concurrencia real.
    always @(posedge CLK_I) begin
        #2;
        if (!RST_I) begin
            check_true(
                (M_ACK_O & M_ERR_O) === 4'b0000,
                "Ningun Master puede tener ACK y ERR simultaneos"
            );
            check_true(
                (M_TIMEOUT_O & ~M_ERR_O) === 4'b0000,
                "TIMEOUT debe implicar ERR"
            );
            check_true(
                !(S_CYC_O[0] && S_CYC_O[1] && S_CYC_O[2]) &&
                !(S_CYC_O[0] && S_CYC_O[1] && S_CYC_O[3]) &&
                !(S_CYC_O[0] && S_CYC_O[2] && S_CYC_O[3]) &&
                !(S_CYC_O[1] && S_CYC_O[2] && S_CYC_O[3]),
                "No deben activarse mas de dos Slaves"
            );
            if (S_CYC_O[0] && S_CYC_O[1])
                simultaneous_slaves_seen = 1'b1;
        end
    end

    task reset_design;
        begin
            @(negedge CLK_I);
            RST_I = 1'b1;
            M_ADR_I = 128'd0;
            M_DAT_I = 128'd0;
            M_SEL_I = 16'd0;
            M_WE_I = 4'd0;
            M_CYC_I = 4'd0;
            M_STB_I = 4'd0;
            dmem_cpu_we = 1'b0;
            imem_access_ok = 1'b1;
            dmem_access_ok = 1'b1;
            repeat (2) @(posedge CLK_I);
            #1;
            @(negedge CLK_I);
            RST_I = 1'b0;
        end
    endtask

    // Una peticion Classic SINGLE completa y validada desde un Master.
    // Uso exclusivo del indice m por tarea (admite fork con Masters distintos).
    task wb_single;
        input integer m;
        input [31:0] address;
        input [31:0] write_data;
        input [3:0] byte_select;
        input write_enable;
        input expected_error;
        input [31:0] expected_read;

        integer count;
        reg completed;
        begin
            @(negedge CLK_I);
            M_ADR_I[m*32 +: 32] = address;
            M_DAT_I[m*32 +: 32] = write_data;
            M_SEL_I[m*4 +: 4] = byte_select;
            M_WE_I[m] = write_enable;
            M_CYC_I[m] = 1'b1;
            M_STB_I[m] = 1'b1;

            completed = 1'b0;

            for (count=0; count<40 && !completed; count=count+1) begin
                @(posedge CLK_I);
                #1;
                if (M_ACK_O[m] || M_ERR_O[m]) begin
                    completed = 1'b1;
                    check_true(
                        M_TIMEOUT_O[m] === 1'b0,
                        "Transaccion normal no puede finalizar por timeout"
                    );
                    if (expected_error) begin
                        check_true(M_ERR_O[m]===1'b1 && M_ACK_O[m]===1'b0,
                                   "Se esperaba ERR sin ACK");
                    end else begin
                        check_true(M_ACK_O[m]===1'b1 && M_ERR_O[m]===1'b0,
                                   "Se esperaba ACK sin ERR");
                        if (!write_enable)
                            check_true(
                                M_DAT_O[m*32 +: 32] === expected_read,
                                "Dato de lectura desde la RAM equivocada"
                            );
                    end
                end
            end

            check_true(completed, "Transaccion no termino en 40 ciclos");

            // El ACK se consume al siguiente flanco: la RAM escribe alli.
            @(posedge CLK_I);
            #1;
            check_true(
                M_ACK_O[m]===1'b0 && M_ERR_O[m]===1'b0,
                "ACK/ERR no debe duplicarse con CYC alto"
            );

            @(negedge CLK_I);
            M_CYC_I[m] = 1'b0;
            M_STB_I[m] = 1'b0;

            // Liberacion y rearme interno del Slave.
            repeat (2) @(posedge CLK_I);
            #1;
        end
    endtask

    initial begin
        CLK_I = 1'b0;
        RST_I = 1'b1;
        M_ADR_I = 128'd0;
        M_DAT_I = 128'd0;
        M_SEL_I = 16'd0;
        M_WE_I = 4'd0;
        M_CYC_I = 4'd0;
        M_STB_I = 4'd0;

        imem_cpu_addr = 32'd0;
        imem_access_ok = 1'b1;

        dmem_cpu_addr = 32'd0;
        dmem_cpu_wdata = 32'd0;
        dmem_cpu_we = 1'b0;
        dmem_cpu_sel = 4'hF;
        dmem_access_ok = 1'b1;

        simultaneous_slaves_seen = 1'b0;
        checks = 0;

        $dumpfile("SIM/out/wb_crossbar_memories_tb.vcd");
        $dumpvars(0, wb_crossbar_memories_tb);

        $display("============================================================");
        $display(" wb_crossbar_memories_tb");
        $display("============================================================");

        reset_design();

        // 1) M0 escribe instrucciones reales. CPU observa los mismos bancos.
        wb_single(0,IMEM_BASE,32'h0000_0013,4'hF,1'b1,1'b0,32'd0);
        imem_cpu_addr=32'd0;
        #1;
        check_true(imem_cpu_rdata===32'h0000_0013,
                   "CPU no observa instruccion programada via crossbar");

        // 2) M1 escribe RAM de datos y CPU lee el resultado.
        wb_single(1,DMEM_BASE+32'd4,32'h1122_3344,4'hF,1'b1,1'b0,32'd0);
        dmem_cpu_addr=32'd4;
        #1;
        check_true(dmem_cpu_rdata===32'h1122_3344,
                   "CPU no observa datos programados via crossbar");

        // 3) Masters de reserva tambien pueden acceder a ambas memorias.
        wb_single(2,IMEM_BASE,32'd0,4'hF,1'b0,1'b0,32'h0000_0013);
        wb_single(3,DMEM_BASE+32'd4,32'd0,4'hF,1'b0,1'b0,32'h1122_3344);

        $display("[PASS] M0..M3 alcanzan las memorias fisicas S0 y S1");

        // 4) Escritura directa CPU, observable por Wishbone.
        @(negedge CLK_I);
        dmem_cpu_addr=32'd0;
        dmem_cpu_wdata=32'hA1B2_C3D4;
        dmem_cpu_sel=4'hF;
        dmem_cpu_we=1'b1;
        @(posedge CLK_I);
        #1;
        dmem_cpu_we=1'b0;
        wb_single(0,DMEM_BASE,32'd0,4'hF,1'b0,1'b0,32'hA1B2_C3D4);

        // 5) Solo modificar byte lanes 0 y 2.
        wb_single(2,DMEM_BASE+32'd4,32'hAABB_CCDD,4'b0101,
                  1'b1,1'b0,32'd0);
        dmem_cpu_addr=32'd4;
        #1;
        check_true(dmem_cpu_rdata===32'h11BB_33DD,
                   "SEL selectivo fallo a traves del crossbar");

        $display("[PASS] CPU y Wishbone comparten los mismos bancos de bytes");

        // 6) Fuera de rango fisico aunque dentro de ventana del decoder.
        wb_single(0,IMEM_BASE+32'd2048,32'hFFFF_FFFF,4'hF,
                  1'b1,1'b1,32'd0);
        wb_single(1,DMEM_BASE+32'd1024,32'hFFFF_FFFF,4'hF,
                  1'b1,1'b1,32'd0);

        // Fuera del mapa global del crossbar.
        wb_single(3,32'h2000_0000,32'd0,4'hF,1'b0,1'b1,32'd0);

        // 7) ACCESS_OK desactivado: rechazar escrituras sin tocar RAM.
        @(negedge CLK_I);
        imem_access_ok=1'b0;
        dmem_access_ok=1'b0;
        wb_single(2,IMEM_BASE,32'hFFFF_FFFF,4'hF,1'b1,1'b1,32'd0);
        wb_single(3,DMEM_BASE+32'd4,32'hFFFF_FFFF,4'hF,1'b1,1'b1,32'd0);
        imem_cpu_addr=32'd0;
        dmem_cpu_addr=32'd4;
        #1;
        check_true(imem_cpu_rdata===32'h0000_0013,
                   "Acceso denegado corrompio IMEM");
        check_true(dmem_cpu_rdata===32'h11BB_33DD,
                   "Acceso denegado corrompio DMEM");
        @(negedge CLK_I);
        imem_access_ok=1'b1;
        dmem_access_ok=1'b1;

        $display("[PASS] Decode, limites fisicos y permisos de mantenimiento");

        // 8) Dos Masters y dos Slaves reales simultaneamente.
        simultaneous_slaves_seen=1'b0;
        fork
            wb_single(0,IMEM_BASE+32'd4,32'h1234_5678,4'hF,1'b1,1'b0,32'd0);
            wb_single(1,DMEM_BASE+32'd8,32'h8765_4321,4'hF,1'b1,1'b0,32'd0);
        join
        check_true(simultaneous_slaves_seen,
                   "Nunca hubo dos Slaves fisicos activos simultaneamente");
        imem_cpu_addr=32'd4;
        dmem_cpu_addr=32'd8;
        #1;
        check_true(imem_cpu_rdata===32'h1234_5678,
                   "IMEM simultanea no se escribio");
        check_true(dmem_cpu_rdata===32'h8765_4321,
                   "DMEM simultanea no se escribio");

        $display("[PASS] Dos canales concurrentes hacia IMEM y DMEM reales");

        // 9) Dos Masters compiten por DMEM: arbitraje y rearme sin perdida.
        fork
            wb_single(0,DMEM_BASE+32'd16,32'h0BAD_CAFE,4'hF,
                      1'b1,1'b0,32'd0);
            wb_single(1,DMEM_BASE+32'd20,32'h1357_9BDF,4'hF,
                      1'b1,1'b0,32'd0);
        join

        wb_single(2,DMEM_BASE+32'd16,32'd0,4'hF,
                  1'b0,1'b0,32'h0BAD_CAFE);
        wb_single(3,DMEM_BASE+32'd20,32'd0,4'hF,
                  1'b0,1'b0,32'h1357_9BDF);

        $display("[PASS] Contencion y rearme del mismo Slave real");

        // 10) Reset de interconnect no borra memorias fisicas.
        reset_design();
        imem_cpu_addr=32'd4;
        dmem_cpu_addr=32'd8;
        #1;
        check_true(imem_cpu_rdata===32'h1234_5678 &&
                   dmem_cpu_rdata===32'h8765_4321,
                   "Reset global de control borro contenido RAM");

        $display("============================================================");
        $display(" Checks: %0d",checks);
        $display(" Errors: 0");
        $display(" [PASS] wb_crossbar_memories_tb COMPLETO");
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1,"Timeout de wb_crossbar_memories_tb");
    end

endmodule
`default_nettype wire
