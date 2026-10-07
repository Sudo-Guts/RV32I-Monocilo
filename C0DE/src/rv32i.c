#include "rv32i.h"

/*
 * noinline fuerza a GCC a generar una llamada real.
 *
 * Esto permite probar:
 *
 *      JAL / JALR
 *      stack
 *      paso de argumentos
 *      LOAD
 *      branches
 *      ADD
 */

__attribute__((noinline))
uint32_t rv32i_sum( volatile const uint32_t *data , uint32_t count ){
    uint32_t sum = 0;
    for (uint32_t i = 0; i < count; ++i){
        sum += data[i];
    }
    return sum;
}
