#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } Vers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } KeyInfo;
typedef struct {
    uint32_t key; Vers vers; PLimit pLimitData; KeyInfo keyInfo;
    char result, status, data8; uint32_t data32; uint8_t bytes[32];
} KeyData;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) { return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3]; }

int smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? 0 : -2;
}

void smc_close(void) { if (conn) IOServiceClose(conn); conn = 0; }

static kern_return_t call(KeyData *in, KeyData *out) {
    size_t outSize = sizeof(KeyData);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(KeyData), out, &outSize);
}

static int info(const char *key, KeyInfo *ki) {
    KeyData in = {0}, out = {0};
    in.key = fourcc(key); in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *ki = out.keyInfo;
    return 0;
}

int smc_read(const char *key, uint8_t *outBytes, uint32_t *size, char type[5]) {
    KeyInfo ki;
    if (info(key, &ki)) return -1;
    KeyData in = {0}, out = {0};
    in.key = fourcc(key); in.keyInfo.dataSize = ki.dataSize; in.data8 = SMC_CMD_READ_BYTES;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -2;
    *size = ki.dataSize > 32 ? 32 : ki.dataSize;
    memcpy(outBytes, out.bytes, *size);
    type[0] = ki.dataType >> 24; type[1] = ki.dataType >> 16; type[2] = ki.dataType >> 8; type[3] = ki.dataType; type[4] = 0;
    return 0;
}

int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    KeyInfo ki;
    if (info(key, &ki)) return -1;
    if (ki.dataSize != size) return -3;
    KeyData in = {0}, out = {0};
    in.key = fourcc(key); in.data8 = SMC_CMD_WRITE_BYTES; in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    kern_return_t r = call(&in, &out);
    if (r != KERN_SUCCESS) return (int)r;
    return out.result;
}
