`timescale 1ns / 1ps
`default_nettype none

/*
 * ============================================================================
 *  Wishbone Switch Fabric
 * ----------------------------------------------------------------------------
 *  Fabric combinacional fijo:
 *
 *      - 4 Masters
 *      - 4 Slaves
 *      - 2 canales dinamicos
 *      - 32 bits de direccion y datos
 *      - SEL[3:0] por Master/Slave
 *
 *  Ningun canal pertenece permanentemente a un Master o a un Slave.
 *  wb_switch_control entrega para cada canal:
 *
 *      CH_VALID
 *      CH_MASTER_SEL[1:0]
 *      CH_SLAVE_SEL[1:0]
 *
 *  Camino de solicitud por canal:
 *
 *      Masters -> MUX 4:1 -> CHANNEL -> DEMUX 1:4 -> Slaves
 *
 *  Camino de respuesta por canal:
 *
 *      Slaves  -> MUX 4:1 -> CHANNEL -> DEMUX 1:4 -> Masters
 *
 *  El controlador garantiza las siguientes invariantes:
 *
 *      - Un Master ocupa como maximo un canal.
 *      - Un Slave es destino de como maximo un canal.
 *      - La asignacion de un canal permanece estable hasta su liberacion.
 *
 *  El fabric no arbitra y no contiene estado. ERR tiene prioridad sobre ACK.
 *
 *  Autor del proyecto: Gustavo Ruiz Luis
 * ============================================================================
 */

module wb_switch_fabric (

    // ------------------------------------------------------------------------
    //  Wishbone Masters M0..M3
    // ------------------------------------------------------------------------
    input  wire [127:0] M_ADR_I,
    input  wire [127:0] M_DAT_I,
    input  wire [15:0]  M_SEL_I,
    input  wire [3:0]   M_WE_I,
    input  wire [3:0]   M_CYC_I,
    input  wire [3:0]   M_STB_I,

    output wire [127:0] M_DAT_O,
    output wire [3:0]   M_ACK_O,
    output wire [3:0]   M_ERR_O,

    // ------------------------------------------------------------------------
    //  Wishbone Slaves S0..S3
    // ------------------------------------------------------------------------
    output wire [127:0] S_ADR_O,
    output wire [127:0] S_DAT_O,
    output wire [15:0]  S_SEL_O,
    output wire [3:0]   S_WE_O,
    output wire [3:0]   S_CYC_O,
    output wire [3:0]   S_STB_O,

    input  wire [127:0] S_DAT_I,
    input  wire [3:0]   S_ACK_I,
    input  wire [3:0]   S_ERR_I,

    // ------------------------------------------------------------------------
    //  Asignacion de los dos canales
    // ------------------------------------------------------------------------
    input wire [1:0] CH_VALID_I,
    input wire [3:0] CH_MASTER_SEL_I,
    input wire [3:0] CH_SLAVE_SEL_I

);

    // ========================================================================
    //  Selectores registrados por wb_switch_control
    // ========================================================================

    wire [1:0] channel0_master = CH_MASTER_SEL_I[1:0];
    wire [1:0] channel1_master = CH_MASTER_SEL_I[3:2];

    wire [1:0] channel0_slave = CH_SLAVE_SEL_I[1:0];
    wire [1:0] channel1_slave = CH_SLAVE_SEL_I[3:2];


    // ========================================================================
    //  CHANNEL 0 - MUX 4:1 de solicitudes Master -> Channel
    // ========================================================================

    reg [31:0] channel0_address;
    reg [31:0] channel0_write_data;
    reg [3:0]  channel0_byte_select;
    reg        channel0_write_enable;
    reg        channel0_cyc;
    reg        channel0_stb;

    always @* begin

        channel0_address      = 32'd0;
        channel0_write_data   = 32'd0;
        channel0_byte_select  = 4'd0;
        channel0_write_enable = 1'b0;
        channel0_cyc          = 1'b0;
        channel0_stb          = 1'b0;

        case (channel0_master)

            2'd0: begin
                channel0_address      = M_ADR_I[31:0];
                channel0_write_data   = M_DAT_I[31:0];
                channel0_byte_select  = M_SEL_I[3:0];
                channel0_write_enable = M_WE_I[0];
                channel0_cyc          = M_CYC_I[0];
                channel0_stb          = M_STB_I[0];
            end

            2'd1: begin
                channel0_address      = M_ADR_I[63:32];
                channel0_write_data   = M_DAT_I[63:32];
                channel0_byte_select  = M_SEL_I[7:4];
                channel0_write_enable = M_WE_I[1];
                channel0_cyc          = M_CYC_I[1];
                channel0_stb          = M_STB_I[1];
            end

            2'd2: begin
                channel0_address      = M_ADR_I[95:64];
                channel0_write_data   = M_DAT_I[95:64];
                channel0_byte_select  = M_SEL_I[11:8];
                channel0_write_enable = M_WE_I[2];
                channel0_cyc          = M_CYC_I[2];
                channel0_stb          = M_STB_I[2];
            end

            2'd3: begin
                channel0_address      = M_ADR_I[127:96];
                channel0_write_data   = M_DAT_I[127:96];
                channel0_byte_select  = M_SEL_I[15:12];
                channel0_write_enable = M_WE_I[3];
                channel0_cyc          = M_CYC_I[3];
                channel0_stb          = M_STB_I[3];
            end

            default: begin
            end

        endcase

    end


    // ========================================================================
    //  CHANNEL 1 - MUX 4:1 de solicitudes Master -> Channel
    // ========================================================================

    reg [31:0] channel1_address;
    reg [31:0] channel1_write_data;
    reg [3:0]  channel1_byte_select;
    reg        channel1_write_enable;
    reg        channel1_cyc;
    reg        channel1_stb;

    always @* begin

        channel1_address      = 32'd0;
        channel1_write_data   = 32'd0;
        channel1_byte_select  = 4'd0;
        channel1_write_enable = 1'b0;
        channel1_cyc          = 1'b0;
        channel1_stb          = 1'b0;

        case (channel1_master)

            2'd0: begin
                channel1_address      = M_ADR_I[31:0];
                channel1_write_data   = M_DAT_I[31:0];
                channel1_byte_select  = M_SEL_I[3:0];
                channel1_write_enable = M_WE_I[0];
                channel1_cyc          = M_CYC_I[0];
                channel1_stb          = M_STB_I[0];
            end

            2'd1: begin
                channel1_address      = M_ADR_I[63:32];
                channel1_write_data   = M_DAT_I[63:32];
                channel1_byte_select  = M_SEL_I[7:4];
                channel1_write_enable = M_WE_I[1];
                channel1_cyc          = M_CYC_I[1];
                channel1_stb          = M_STB_I[1];
            end

            2'd2: begin
                channel1_address      = M_ADR_I[95:64];
                channel1_write_data   = M_DAT_I[95:64];
                channel1_byte_select  = M_SEL_I[11:8];
                channel1_write_enable = M_WE_I[2];
                channel1_cyc          = M_CYC_I[2];
                channel1_stb          = M_STB_I[2];
            end

            2'd3: begin
                channel1_address      = M_ADR_I[127:96];
                channel1_write_data   = M_DAT_I[127:96];
                channel1_byte_select  = M_SEL_I[15:12];
                channel1_write_enable = M_WE_I[3];
                channel1_cyc          = M_CYC_I[3];
                channel1_stb          = M_STB_I[3];
            end

            default: begin
            end

        endcase

    end


    // ========================================================================
    //  DEMUX de solicitudes Channel -> Slaves
    // ------------------------------------------------------------------------
    //  CYC puede permanecer alto mientras STB esta pausado. Por eso la ruta
    //  permanece activa con CH_VALID y CYC, mientras STB viaja por separado.
    // ========================================================================

    wire channel0_active = CH_VALID_I[0] & channel0_cyc;
    wire channel1_active = CH_VALID_I[1] & channel1_cyc;

    wire channel0_to_slave0 = channel0_active & (channel0_slave == 2'd0);
    wire channel0_to_slave1 = channel0_active & (channel0_slave == 2'd1);
    wire channel0_to_slave2 = channel0_active & (channel0_slave == 2'd2);
    wire channel0_to_slave3 = channel0_active & (channel0_slave == 2'd3);

    wire channel1_to_slave0 = channel1_active & (channel1_slave == 2'd0);
    wire channel1_to_slave1 = channel1_active & (channel1_slave == 2'd1);
    wire channel1_to_slave2 = channel1_active & (channel1_slave == 2'd2);
    wire channel1_to_slave3 = channel1_active & (channel1_slave == 2'd3);


    // ------------------------------------------------------------------------
    //  S0
    // ------------------------------------------------------------------------

    assign S_ADR_O[31:0] =
        channel0_to_slave0 ? channel0_address :
        channel1_to_slave0 ? channel1_address :
        32'd0;

    assign S_DAT_O[31:0] =
        channel0_to_slave0 ? channel0_write_data :
        channel1_to_slave0 ? channel1_write_data :
        32'd0;

    assign S_SEL_O[3:0] =
        channel0_to_slave0 ? channel0_byte_select :
        channel1_to_slave0 ? channel1_byte_select :
        4'd0;

    assign S_WE_O[0] =
        channel0_to_slave0 ? channel0_write_enable :
        channel1_to_slave0 ? channel1_write_enable :
        1'b0;

    assign S_CYC_O[0] = channel0_to_slave0 | channel1_to_slave0;

    assign S_STB_O[0] =
        channel0_to_slave0 ? channel0_stb :
        channel1_to_slave0 ? channel1_stb :
        1'b0;


    // ------------------------------------------------------------------------
    //  S1
    // ------------------------------------------------------------------------

    assign S_ADR_O[63:32] =
        channel0_to_slave1 ? channel0_address :
        channel1_to_slave1 ? channel1_address :
        32'd0;

    assign S_DAT_O[63:32] =
        channel0_to_slave1 ? channel0_write_data :
        channel1_to_slave1 ? channel1_write_data :
        32'd0;

    assign S_SEL_O[7:4] =
        channel0_to_slave1 ? channel0_byte_select :
        channel1_to_slave1 ? channel1_byte_select :
        4'd0;

    assign S_WE_O[1] =
        channel0_to_slave1 ? channel0_write_enable :
        channel1_to_slave1 ? channel1_write_enable :
        1'b0;

    assign S_CYC_O[1] = channel0_to_slave1 | channel1_to_slave1;

    assign S_STB_O[1] =
        channel0_to_slave1 ? channel0_stb :
        channel1_to_slave1 ? channel1_stb :
        1'b0;


    // ------------------------------------------------------------------------
    //  S2
    // ------------------------------------------------------------------------

    assign S_ADR_O[95:64] =
        channel0_to_slave2 ? channel0_address :
        channel1_to_slave2 ? channel1_address :
        32'd0;

    assign S_DAT_O[95:64] =
        channel0_to_slave2 ? channel0_write_data :
        channel1_to_slave2 ? channel1_write_data :
        32'd0;

    assign S_SEL_O[11:8] =
        channel0_to_slave2 ? channel0_byte_select :
        channel1_to_slave2 ? channel1_byte_select :
        4'd0;

    assign S_WE_O[2] =
        channel0_to_slave2 ? channel0_write_enable :
        channel1_to_slave2 ? channel1_write_enable :
        1'b0;

    assign S_CYC_O[2] = channel0_to_slave2 | channel1_to_slave2;

    assign S_STB_O[2] =
        channel0_to_slave2 ? channel0_stb :
        channel1_to_slave2 ? channel1_stb :
        1'b0;


    // ------------------------------------------------------------------------
    //  S3
    // ------------------------------------------------------------------------

    assign S_ADR_O[127:96] =
        channel0_to_slave3 ? channel0_address :
        channel1_to_slave3 ? channel1_address :
        32'd0;

    assign S_DAT_O[127:96] =
        channel0_to_slave3 ? channel0_write_data :
        channel1_to_slave3 ? channel1_write_data :
        32'd0;

    assign S_SEL_O[15:12] =
        channel0_to_slave3 ? channel0_byte_select :
        channel1_to_slave3 ? channel1_byte_select :
        4'd0;

    assign S_WE_O[3] =
        channel0_to_slave3 ? channel0_write_enable :
        channel1_to_slave3 ? channel1_write_enable :
        1'b0;

    assign S_CYC_O[3] = channel0_to_slave3 | channel1_to_slave3;

    assign S_STB_O[3] =
        channel0_to_slave3 ? channel0_stb :
        channel1_to_slave3 ? channel1_stb :
        1'b0;


    // ========================================================================
    //  CHANNEL 0 - MUX 4:1 de respuestas Slave -> Channel
    // ========================================================================

    reg [31:0] channel0_read_data;
    reg        channel0_ack;
    reg        channel0_err;

    always @* begin

        channel0_read_data = 32'd0;
        channel0_ack       = 1'b0;
        channel0_err       = 1'b0;

        case (channel0_slave)

            2'd0: begin
                channel0_read_data = S_DAT_I[31:0];
                channel0_ack       = S_ACK_I[0];
                channel0_err       = S_ERR_I[0];
            end

            2'd1: begin
                channel0_read_data = S_DAT_I[63:32];
                channel0_ack       = S_ACK_I[1];
                channel0_err       = S_ERR_I[1];
            end

            2'd2: begin
                channel0_read_data = S_DAT_I[95:64];
                channel0_ack       = S_ACK_I[2];
                channel0_err       = S_ERR_I[2];
            end

            2'd3: begin
                channel0_read_data = S_DAT_I[127:96];
                channel0_ack       = S_ACK_I[3];
                channel0_err       = S_ERR_I[3];
            end

            default: begin
            end

        endcase

    end


    // ========================================================================
    //  CHANNEL 1 - MUX 4:1 de respuestas Slave -> Channel
    // ========================================================================

    reg [31:0] channel1_read_data;
    reg        channel1_ack;
    reg        channel1_err;

    always @* begin

        channel1_read_data = 32'd0;
        channel1_ack       = 1'b0;
        channel1_err       = 1'b0;

        case (channel1_slave)

            2'd0: begin
                channel1_read_data = S_DAT_I[31:0];
                channel1_ack       = S_ACK_I[0];
                channel1_err       = S_ERR_I[0];
            end

            2'd1: begin
                channel1_read_data = S_DAT_I[63:32];
                channel1_ack       = S_ACK_I[1];
                channel1_err       = S_ERR_I[1];
            end

            2'd2: begin
                channel1_read_data = S_DAT_I[95:64];
                channel1_ack       = S_ACK_I[2];
                channel1_err       = S_ERR_I[2];
            end

            2'd3: begin
                channel1_read_data = S_DAT_I[127:96];
                channel1_ack       = S_ACK_I[3];
                channel1_err       = S_ERR_I[3];
            end

            default: begin
            end

        endcase

    end


    // ========================================================================
    //  DEMUX de respuestas Channel -> Masters
    // ------------------------------------------------------------------------
    //  Una respuesta solo es visible durante una transferencia activa.
    //  El controlador garantiza que un Master no ocupa ambos canales.
    // ========================================================================

    wire channel0_response_enable =
        CH_VALID_I[0] & channel0_cyc & channel0_stb;

    wire channel1_response_enable =
        CH_VALID_I[1] & channel1_cyc & channel1_stb;

    wire channel0_to_master0 = channel0_response_enable & (channel0_master == 2'd0);
    wire channel0_to_master1 = channel0_response_enable & (channel0_master == 2'd1);
    wire channel0_to_master2 = channel0_response_enable & (channel0_master == 2'd2);
    wire channel0_to_master3 = channel0_response_enable & (channel0_master == 2'd3);

    wire channel1_to_master0 = channel1_response_enable & (channel1_master == 2'd0);
    wire channel1_to_master1 = channel1_response_enable & (channel1_master == 2'd1);
    wire channel1_to_master2 = channel1_response_enable & (channel1_master == 2'd2);
    wire channel1_to_master3 = channel1_response_enable & (channel1_master == 2'd3);


    // ------------------------------------------------------------------------
    //  M0
    // ------------------------------------------------------------------------

    assign M_DAT_O[31:0] =
        channel0_to_master0 ? channel0_read_data :
        channel1_to_master0 ? channel1_read_data :
        32'd0;

    assign M_ERR_O[0] =
        (channel0_to_master0 & channel0_err) |
        (channel1_to_master0 & channel1_err);

    assign M_ACK_O[0] =
        (channel0_to_master0 & channel0_ack & ~channel0_err) |
        (channel1_to_master0 & channel1_ack & ~channel1_err);


    // ------------------------------------------------------------------------
    //  M1
    // ------------------------------------------------------------------------

    assign M_DAT_O[63:32] =
        channel0_to_master1 ? channel0_read_data :
        channel1_to_master1 ? channel1_read_data :
        32'd0;

    assign M_ERR_O[1] =
        (channel0_to_master1 & channel0_err) |
        (channel1_to_master1 & channel1_err);

    assign M_ACK_O[1] =
        (channel0_to_master1 & channel0_ack & ~channel0_err) |
        (channel1_to_master1 & channel1_ack & ~channel1_err);


    // ------------------------------------------------------------------------
    //  M2
    // ------------------------------------------------------------------------

    assign M_DAT_O[95:64] =
        channel0_to_master2 ? channel0_read_data :
        channel1_to_master2 ? channel1_read_data :
        32'd0;

    assign M_ERR_O[2] =
        (channel0_to_master2 & channel0_err) |
        (channel1_to_master2 & channel1_err);

    assign M_ACK_O[2] =
        (channel0_to_master2 & channel0_ack & ~channel0_err) |
        (channel1_to_master2 & channel1_ack & ~channel1_err);


    // ------------------------------------------------------------------------
    //  M3
    // ------------------------------------------------------------------------

    assign M_DAT_O[127:96] =
        channel0_to_master3 ? channel0_read_data :
        channel1_to_master3 ? channel1_read_data :
        32'd0;

    assign M_ERR_O[3] =
        (channel0_to_master3 & channel0_err) |
        (channel1_to_master3 & channel1_err);

    assign M_ACK_O[3] =
        (channel0_to_master3 & channel0_ack & ~channel0_err) |
        (channel1_to_master3 & channel1_ack & ~channel1_err);

endmodule

`default_nettype wire
