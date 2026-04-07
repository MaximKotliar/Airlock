#include <sys/mman.h>
#include <unistd.h>

pid_t airlock_fork(void) {
    return fork();
}

/// Anonymous read/write mapping shared across `fork` (`MAP_ANON` | `MAP_SHARED`). Returns `NULL` if `mmap` failed.
void *airlock_mmap_shared_anon(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    return (p == MAP_FAILED) ? NULL : p;
}

int airlock_munmap(void *p, size_t size) {
    return munmap(p, size);
}
