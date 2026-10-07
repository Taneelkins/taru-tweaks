#ifndef FUEL_SMC_H
#define FUEL_SMC_H
#include <stdint.h>
int smc_open(void);
void smc_close(void);
int smc_read(const char *key, uint8_t *out, uint32_t *size, char type[5]);
int smc_write(const char *key, const uint8_t *bytes, uint32_t size);
#endif
