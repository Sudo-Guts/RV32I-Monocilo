#include <stdint.h>


/*
 * Variable global sin inicializar.
 * Se almacena en .bss, por lo que es compatible con
 * nuestro entorno actual.
 */
volatile uint32_t fibonacci_result;


/*
 * Calcula Fibonacci de forma iterativa.
 *
 * F(0) = 0
 * F(1) = 1
 *
 * noinline obliga a generar una llamada real a la función,
 * permitiendo probar JAL/JALR.
 */
__attribute__((noinline))
uint32_t fibonacci(uint32_t n)
{
    if (n == 0)
        return 0;

    if (n == 1)
        return 1;


    uint32_t a = 0;
    uint32_t b = 1;
    uint32_t next;


    for (uint32_t i = 2; i <= n; i++)
    {
        next = a + b;

        a = b;
        b = next;
    }


    return b;
}


int main(void)
{
    /*
     * volatile obliga a realizar realmente el acceso,
     * evitando que GCC sustituya todo por una constante.
     */
    volatile uint32_t n = 10;


    fibonacci_result = fibonacci(n);


    /*
     * F(10) = 55
     *
     * El valor de retorno queda en:
     *
     * a0 = x10
     */
    return (int)fibonacci_result;
}