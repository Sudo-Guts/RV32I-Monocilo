`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Wishbone Address Decoder
 * ----------------------------------------------------------------------------
 *  Decoder combinacional fijo:
 *
 *      - 4 Masters
 *      - 4 Slaves
 *      - 32 bits de direccion por Master
 *
 *  Mapa fijo:
 *
 *      S0 IMEM     0x0000_0000 - 0x0000_FFFF
 *      S1 DMEM     0x0001_0000 - 0x0001_FFFF
 *      S2 Loader   0x1000_0000 - 0x1000_00FF
 *      S3 Debug    0x1000_1000 - 0x1000_10FF
 *
 *  Cada Master tiene cuatro comparadores de direccion y un codificador 4:2.
 *  La capacidad fisica, el alineamiento y los permisos se validan dentro de
 *  cada Slave; este bloque solamente selecciona la ventana de direccion.
 *
 *  Distribucion de buses:
 *
 *      M_ADR_I[31:0]    = M0
 *      M_ADR_I[63:32]   = M1
 *      M_ADR_I[95:64]   = M2
 *      M_ADR_I[127:96]  = M3
 *
 *      M_TARGET_O[1:0]  = target M0
 *      M_TARGET_O[3:2]  = target M1
 *      M_TARGET_O[5:4]  = target M2
 *      M_TARGET_O[7:6]  = target M3
 *
 *  TARGET solo es significativo cuando TARGET_VALID vale uno.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ============================================================================
 */

module wb_address_decoder (

    input  wire [127:0] M_ADR_I,

    output reg  [7:0]   M_TARGET_O,
    output wire [3:0]   M_TARGET_VALID_O,
    output wire [3:0]   M_UNMAPPED_O,
    output wire [3:0]   M_OVERLAP_O

);

    // ========================================================================
    //  Comparadores de direccion - Master 0
    // ========================================================================

    wire [3:0] master0_slave_match;

    assign master0_slave_match[0] = (M_ADR_I[31:16] == 16'h0000);
    assign master0_slave_match[1] = (M_ADR_I[31:16] == 16'h0001);
    assign master0_slave_match[2] = (M_ADR_I[31:8]  == 24'h100000);
    assign master0_slave_match[3] = (M_ADR_I[31:8]  == 24'h100010);


    // ========================================================================
    //  Comparadores de direccion - Master 1
    // ========================================================================

    wire [3:0] master1_slave_match;

    assign master1_slave_match[0] = (M_ADR_I[63:48] == 16'h0000);
    assign master1_slave_match[1] = (M_ADR_I[63:48] == 16'h0001);
    assign master1_slave_match[2] = (M_ADR_I[63:40] == 24'h100000);
    assign master1_slave_match[3] = (M_ADR_I[63:40] == 24'h100010);


    // ========================================================================
    //  Comparadores de direccion - Master 2
    // ========================================================================

    wire [3:0] master2_slave_match;

    assign master2_slave_match[0] = (M_ADR_I[95:80] == 16'h0000);
    assign master2_slave_match[1] = (M_ADR_I[95:80] == 16'h0001);
    assign master2_slave_match[2] = (M_ADR_I[95:72] == 24'h100000);
    assign master2_slave_match[3] = (M_ADR_I[95:72] == 24'h100010);


    // ========================================================================
    //  Comparadores de direccion - Master 3
    // ========================================================================

    wire [3:0] master3_slave_match;

    assign master3_slave_match[0] = (M_ADR_I[127:112] == 16'h0000);
    assign master3_slave_match[1] = (M_ADR_I[127:112] == 16'h0001);
    assign master3_slave_match[2] = (M_ADR_I[127:104] == 24'h100000);
    assign master3_slave_match[3] = (M_ADR_I[127:104] == 24'h100010);


    // ========================================================================
    //  Direcciones no mapeadas
    // ========================================================================

    assign M_UNMAPPED_O[0] = ~(|master0_slave_match);
    assign M_UNMAPPED_O[1] = ~(|master1_slave_match);
    assign M_UNMAPPED_O[2] = ~(|master2_slave_match);
    assign M_UNMAPPED_O[3] = ~(|master3_slave_match);


    // ========================================================================
    //  Deteccion de overlap
    // ------------------------------------------------------------------------
    //  El mapa fijo actual es disjunto. Esta logica mantiene explicita la
    //  condicion invalida de dos o mas coincidencias para cada Master.
    // ========================================================================

    assign M_OVERLAP_O[0] =
        (master0_slave_match[0] & (|master0_slave_match[3:1])) |
        (master0_slave_match[1] & (|master0_slave_match[3:2])) |
        (master0_slave_match[2] & master0_slave_match[3]);

    assign M_OVERLAP_O[1] =
        (master1_slave_match[0] & (|master1_slave_match[3:1])) |
        (master1_slave_match[1] & (|master1_slave_match[3:2])) |
        (master1_slave_match[2] & master1_slave_match[3]);

    assign M_OVERLAP_O[2] =
        (master2_slave_match[0] & (|master2_slave_match[3:1])) |
        (master2_slave_match[1] & (|master2_slave_match[3:2])) |
        (master2_slave_match[2] & master2_slave_match[3]);

    assign M_OVERLAP_O[3] =
        (master3_slave_match[0] & (|master3_slave_match[3:1])) |
        (master3_slave_match[1] & (|master3_slave_match[3:2])) |
        (master3_slave_match[2] & master3_slave_match[3]);


    // ========================================================================
    //  Validez del target
    // ========================================================================

    assign M_TARGET_VALID_O = ~(M_UNMAPPED_O | M_OVERLAP_O);


    // ========================================================================
    //  Codificador 4:2 - Master 0
    // ========================================================================

    always @* begin

        case (master0_slave_match)
            4'b0001: M_TARGET_O[1:0] = 2'd0;
            4'b0010: M_TARGET_O[1:0] = 2'd1;
            4'b0100: M_TARGET_O[1:0] = 2'd2;
            4'b1000: M_TARGET_O[1:0] = 2'd3;
            default: M_TARGET_O[1:0] = 2'd0;
        endcase

    end


    // ========================================================================
    //  Codificador 4:2 - Master 1
    // ========================================================================

    always @* begin

        case (master1_slave_match)
            4'b0001: M_TARGET_O[3:2] = 2'd0;
            4'b0010: M_TARGET_O[3:2] = 2'd1;
            4'b0100: M_TARGET_O[3:2] = 2'd2;
            4'b1000: M_TARGET_O[3:2] = 2'd3;
            default: M_TARGET_O[3:2] = 2'd0;
        endcase

    end


    // ========================================================================
    //  Codificador 4:2 - Master 2
    // ========================================================================

    always @* begin

        case (master2_slave_match)
            4'b0001: M_TARGET_O[5:4] = 2'd0;
            4'b0010: M_TARGET_O[5:4] = 2'd1;
            4'b0100: M_TARGET_O[5:4] = 2'd2;
            4'b1000: M_TARGET_O[5:4] = 2'd3;
            default: M_TARGET_O[5:4] = 2'd0;
        endcase

    end


    // ========================================================================
    //  Codificador 4:2 - Master 3
    // ========================================================================

    always @* begin

        case (master3_slave_match)
            4'b0001: M_TARGET_O[7:6] = 2'd0;
            4'b0010: M_TARGET_O[7:6] = 2'd1;
            4'b0100: M_TARGET_O[7:6] = 2'd2;
            4'b1000: M_TARGET_O[7:6] = 2'd3;
            default: M_TARGET_O[7:6] = 2'd0;
        endcase

    end

endmodule

`default_nettype wire
