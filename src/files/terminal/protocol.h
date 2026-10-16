#ifndef REDIWM_FILES_TERMINAL_PROTOCOL_H
#define REDIWM_FILES_TERMINAL_PROTOCOL_H
#include <stdint.h>

/* Private inherited SOCK_SEQPACKET, never a terminal escape sequence. Paths
 * are data. Fixed, bounded packets simplify validation on both ends. */
#define FT_MAGIC 0x46543031u
#define FT_PATH 4096
enum { FT_READY = 1, FT_EDITING = 2, FT_BUSY = 4, FT_ERROR = 8 };
struct ft_request { uint32_t magic; uint32_t reserved; uint64_t serial; char path[FT_PATH]; };
struct ft_status {
    uint32_t magic, flags;
    uint64_t serial;
    int32_t error, jobs;
    char path[FT_PATH];
};
#endif
