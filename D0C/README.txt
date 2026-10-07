RV32I-Monociclo_v3_wb_style
===========================

Top Entity
----------
cpu_soc.v

Objetivo de esta revision
-------------------------
Esta revision aplica una convencion uniforme de nombres y documentacion al
proyecto RV32I monociclo con Wishbone B4, manteniendo el mapa externo y el
protocolo de debugger.py.

Convencion de archivos Wishbone
-------------------------------
*_wbm.v   Top Wishbone Master
*_wbs.v   Top Wishbone Slave
*_wb.v    Modulo con rol Master+Slave o infraestructura Wishbone

Aplicacion actual:
  uart0_wbm.v                 M0
  program_loader_wb.v         S2 + M1
  instruction_memory_wbs.v    S0
  data_memory_wbs.v           S1
  debug_controller_wbs.v      S3
  wb_crossbar.v               interconnect 4M / 4S / 2CH

wb_memory.v es un helper interno de las memorias. No es un slave top visible
por wb_crossbar, por lo que usa la convencion normal de puertos en minusculas.

Convencion de puertos
---------------------
Top Wishbone:
  CLK_I, RST_I, ADR_I, DAT_I, DAT_O, SEL_I, WE_I, CYC_I, STB_I, ACK_O, ERR_O...

Modulos no-Wishbone:
  clk_i, rst_i, data_i, data_o, valid_o, ready_i...

Senales internas entre instancias:
  clk_sys, rx_data, tx_busy, m_adr, cpu_pc...

Las senales internas no llevan sufijos _i / _o.

UART0
-----
uart.v ahora es una UART pura:
  uart_baudrate + uart_rx + uart_tx

La RX FIFO fue movida a uart0_wbm.v. uart0_wbm integra:
  - uart.v
  - RX FIFO
  - parser de tramas
  - CRC-16/CCITT-FALSE
  - Wishbone Master M0
  - recovery por timeout/overflow

La profundidad default de FIFO sigue siendo 64 bytes:
  FIFO_ADDR_WIDTH = 6

Wishbone
--------
Perfil del proyecto:
  Wishbone B4 Classic SINGLE
  Data width: 32 bits
  Granularity: 8 bits mediante SEL[3:0]
  Byte addressing
  Little-endian
  ACK / ERR
  Timeout local en wb_crossbar
  Sin STALL, RTY o burst transfers

Mapa del crossbar
-----------------
S0  0x00000000 .. 0x0000FFFF   instruction_memory_wbs
S1  0x00010000 .. 0x0001FFFF   data_memory_wbs
S2  0x10000000 .. 0x100000FF   program_loader_wb
S3  0x10001000 .. 0x100010FF   debug_controller_wbs

Las capacidades reales por default son:
  IMEM = 2 KiB
  DMEM = 1 KiB

Los huecos dentro de una ventana terminan en ERR desde el slave correspondiente.

Cambio de puertos fisicos de cpu_soc
------------------------------------
La Top Entity no es Wishbone y ahora sigue la convencion _i / _o:

  anterior    actual
  --------    ------
  clk         clk_i
  rst         rst_i
  rx          rx_i
  tx          tx_o
  seg         seg_o
  an          an_o
  dp          dp_o

IMPORTANTE: actualizar el UCF para usar estos nombres de puerto.
El reloj fisico sigue siendo 100 MHz y su constraint de entrada sigue siendo 10 ns.

Archivos legacy eliminados/renombrados
--------------------------------------
crossbar_wb.v          -> eliminado; cpu_soc instancia wb_crossbar directamente
instruction_memory.v   -> instruction_memory_wbs.v
data_memory.v          -> data_memory_wbs.v
debug_controller.v     -> debug_controller_wbs.v
program_loader.v       -> program_loader_wb.v
uart_wb_master.v       -> reemplazado por uart0_wbm.v
cpu.v                  -> no forma parte de esta version

Estado de validacion
--------------------
El refactor actual deja Wishbone fijo en 4 Masters, 4 Slaves y 2 canales
dinamicos. M0 y M1 estan activos en el SoC monociclo; M2 y M3 quedan reservados
para la futura integracion del CPU multiciclo.

La verificacion funcional de decoder, control, fabric y crossbar se realizara
con testbenches dedicados antes de ejecutar XST/Translate/Map/PAR y Timing
Analyzer en ISE 14.7.
