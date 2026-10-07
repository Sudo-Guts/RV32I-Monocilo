/* ============================================================
 * RV32I Startup
 * ============================================================
 */
    .section .text.start, "ax", @progbits
    .align 2
    .global _start
    .type _start, @function

_start:
    /* --------------------------------------------------------
     * Inicializar stack
     * DMEM = 1 KiB
     * __stack_top = 0x00000400
     * --------------------------------------------------------
     */

    la      sp, __stack_top

    /* --------------------------------------------------------
     * Limpiar .bss
     * DMEM no se limpia por RESET en el hardware, por lo que
     * debemos hacerlo nosotros.
     * --------------------------------------------------------
     */

    la      t0, __bss_start
    la      t1, __bss_end

.Lclear_bss:
    bgeu    t0, t1, .Lcall_main
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       .Lclear_bss
    /* --------------------------------------------------------
     * Entrar al programa C
     * --------------------------------------------------------
     */

.Lcall_main:
    call    main
    /* --------------------------------------------------------
     * Si main retorna:
     * a0 conserva su valor de retorno.
     * Esto es bastante util porque podremos leer x10/a0 desde
     * debugger.
     * --------------------------------------------------------
     */

.Lhang:
    j       .Lhang
    .size _start, . - _start
