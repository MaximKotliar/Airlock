#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

pid_t airlock_fork(void);

void *airlock_mmap_shared_anon(size_t size);

int airlock_munmap(void *p, size_t size);
