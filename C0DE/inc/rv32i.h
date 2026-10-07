#ifndef RV32I_H
#define RV32I_H

#include <stdint.h>

/*
 * Suma un arreglo de uint32_t.
 *
 * volatile evita que GCC sustituya las lecturas por constantes,
 * permitiendo probar realmente LOAD desde DMEM.
 */
uint32_t rv32i_sum( volatile const uint32_t *data , uint32_t count );

/*
 * NOP RV32I.
 */
static inline void rv32i_nop(void)
{
    __asm__ volatile ("nop");
}

#endif
