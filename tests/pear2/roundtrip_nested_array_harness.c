#include <stdint.h>

extern int8_t roundtrip_nested_array(uint8_t *storage);

int main(void)
{
    uint8_t storage[4] = {0};
    return roundtrip_nested_array(storage) == 3 ? 0 : 1;
}
