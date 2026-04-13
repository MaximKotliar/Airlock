#ifndef AIRLOCK_H
#define AIRLOCK_H

#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

// ── fork-based isolation (runUnsafely) ──────────────────────────────────

pid_t airlock_fork(void);
void *airlock_mmap_shared_anon(size_t size);

// ── fd-based re-exec task API ───────────────────────────────────────────

// Child-mode detection (globals set by __attribute__((constructor))).
// Returns non-zero when this process was spawned as a child by Airlock.
int    airlock_is_child(void);

// The inherited shmem fd and its size, valid only when airlock_is_child().
int    airlock_child_fd(void);
size_t airlock_child_shmem_size(void);

// Create anonymous shmem: shm_open + ftruncate + shm_unlink (name gone).
// Returns the fd (>= 0) on success, -1 on failure. Caller owns the fd.
int airlock_shmem_create(size_t size);

// Spawn a child process. The shmem fd is inherited (dup2'd to survive exec).
// Pass NULL for `executable` to re-exec the current process.
pid_t airlock_spawn(const char *executable, int shmem_fd, size_t shmem_size);

// ── shared ──────────────────────────────────────────────────────────────

int airlock_munmap(void *p, size_t size);

#endif
