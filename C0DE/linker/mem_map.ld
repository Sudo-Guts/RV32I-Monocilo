/* ============================================================
 * RV32I Linker Script
 * ------------------------------------------------------------
 * Arquitectura Harvard:
 *      IMEM : 0x00000000 - 0x000007FF   2 KiB
 *      DMEM : 0x00000000 - 0x000003FF   1 KiB
 *
 * Las direcciones se superponen intencionalmente porque son
 * memorias fisicamente diferentes.
 *
 * PC reset:
 *      0x00000000
 *
 * ============================================================
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

/* ------------------------------------------------------------
 * Memorias fisicas
 * ------------------------------------------------------------
 */

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 2K
    DMEM (rw) : ORIGIN = 0x00000000, LENGTH = 1K
}


/* ------------------------------------------------------------
 * Stack
 *
 * DMEM:
 *
 *      0x000
 *        |
 *        | .bss
 *        |
 *      0x200  <- limite reservado
 *        |
 *        | stack
 *        | crece hacia abajo
 *        |
 *      0x400  <- __stack_top
 *
 * ------------------------------------------------------------
 */

__stack_size = 0x200;

SECTIONS
{
    /* ========================================================
     * Instruction Memory
     * ========================================================
     */
    .text :
    {
        . = ALIGN(4);
        __text_start = .;

        /*
         * start.S debe ser obligatoriamente lo primero que
         * encuentre el CPU en PC = 0.
         */
        KEEP(*(.text.start))

        *(.text)
        *(.text.*)
        . = ALIGN(4);
        __text_end = .;

    } > IMEM


    /* ========================================================
     * Read-only data
     *
     * Actualmente NO soportada.
     *
     * Una instruccion LW siempre accede a DMEM, no a IMEM.
     * Por tanto una cadena o tabla almacenada aqui no podria
     * ser leida como datos por el CPU.
     * ========================================================
     */

    .rodata :
    {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    } > IMEM


    /* ========================================================
     * Data Memory
     * ========================================================
     *
     * La DMEM comienza tambien en direccion 0.
     *
     * Esto es correcto porque se trata de arquitectura Harvard.
     * ========================================================
     */

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM


    /* ========================================================
     * Initialized data
     *
     * Todavia no soportada porque no existe un loader de DMEM.
     *
     * Se mantiene como NOLOAD para poder detectar su uso.
     * ========================================================
     */

    .data (NOLOAD) :
    {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > DMEM


    /* ========================================================
     * Stack
     * ========================================================
     */
    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
    __stack_bottom = __stack_top - __stack_size;


    /* ========================================================
     * Comprobaciones
     * ========================================================
     */


    /*
     * Evitar que codigo exceda IMEM.
     */
    ASSERT(
        SIZEOF(.text) <= LENGTH(IMEM),
        "ERROR: programa excede los 2 KiB de IMEM"
    )

    /*
     * Dejamos 512 bytes superiores para stack.
     */
    ASSERT(
        __bss_end <= __stack_bottom,
        "ERROR: .bss invade el espacio reservado para stack"
    )

    /*
     * Por ahora no permitimos variables globales inicializadas.
     *
     * Ejemplo NO permitido:
     *
     *      int x = 10;
     */
    ASSERT(
        SIZEOF(.data) == 0,
        "ERROR: .data inicializada aun no esta soportada por el hardware"
    )

    /*
     * Tampoco permitimos constantes almacenadas en memoria.
     *
     * Ejemplo NO permitido:
     *
     *      const char text[] = \"Hola\";
     */
    ASSERT(
        SIZEOF(.rodata) == 0,
        "ERROR: .rodata aun no es accesible desde la DMEM"
    )

    /* ========================================================
     * Metadatos innecesarios
     * ========================================================
     */

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
