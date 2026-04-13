#include "airlock.h"

#include <crt_externs.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// ---------------------------------------------------------------------------
// fork-based isolation (runUnsafely)
// ---------------------------------------------------------------------------

pid_t airlock_fork(void) {
    return fork();
}

void *airlock_mmap_shared_anon(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANON, -1, 0);
    return (p == MAP_FAILED) ? NULL : p;
}

// ---------------------------------------------------------------------------
// Globals populated by the constructor before main().
// argv: <exe> --airlock <fd> <shmem_size>
// ---------------------------------------------------------------------------

static int    g_child_mode = 0;
static int    g_child_fd   = -1;
static size_t g_shmem_size = 0;

__attribute__((constructor))
static void airlock_parse_argv(void) {
    int    argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();

    for (int i = 1; i < argc - 2; i++) {
        if (strcmp(argv[i], "--airlock") == 0) {
            g_child_fd   = atoi(argv[i + 1]);
            g_shmem_size = (size_t)atol(argv[i + 2]);
            break;
        }
    }

    if (g_child_fd >= 0 && g_shmem_size > 0)
        g_child_mode = 1;
}

// ---------------------------------------------------------------------------
// Public accessors
// ---------------------------------------------------------------------------

int    airlock_is_child(void)       { return g_child_mode; }
int    airlock_child_fd(void)       { return g_child_fd;   }
size_t airlock_child_shmem_size(void) { return g_shmem_size; }

// ---------------------------------------------------------------------------
// Anonymous shared memory via fd
// ---------------------------------------------------------------------------

static _Atomic int g_counter = 0;

int airlock_shmem_create(size_t size) {
    char name[64];
    snprintf(name, sizeof(name), "/al.%d.%d",
             getpid(), atomic_fetch_add(&g_counter, 1));

    int fd = shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0600);
    if (fd < 0) return -1;

    // Unlink immediately — the name disappears, only the fd keeps it alive.
    shm_unlink(name);

    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return -1;
    }

    return fd;
}

// ---------------------------------------------------------------------------
// Spawn
// ---------------------------------------------------------------------------

pid_t airlock_spawn(const char *executable, int shmem_fd, size_t shmem_size)
{
    char resolved[PATH_MAX];

    if (executable) {
        if (!realpath(executable, resolved)) return -1;
    } else {
        char raw[PATH_MAX];
        uint32_t rawsz = (uint32_t)sizeof(raw);
        if (_NSGetExecutablePath(raw, &rawsz) != 0) return -1;
        if (!realpath(raw, resolved)) return -1;
    }

    // Pick a target fd number unlikely to collide. dup2 clears FD_CLOEXEC.
    int target_fd = 100 + (shmem_fd % 100);

    char fd_str[16];
    snprintf(fd_str, sizeof(fd_str), "%d", target_fd);

    char size_str[32];
    snprintf(size_str, sizeof(size_str), "%zu", shmem_size);

    char *child_argv[] = {
        resolved,
        "--airlock", fd_str, size_str,
        NULL
    };

    // Build environment with SWIFT_BACKTRACE=enable=no.
    char **parent_env = *_NSGetEnviron();
    size_t env_count = 0;
    int    bt_index  = -1;
    for (size_t i = 0; parent_env[i]; i++) {
        if (strncmp(parent_env[i], "SWIFT_BACKTRACE=", 16) == 0)
            bt_index = (int)i;
        env_count++;
    }

    static const char bt_off[] = "SWIFT_BACKTRACE=enable=no";
    int need_extra = (bt_index < 0) ? 1 : 0;
    char **child_env = (char **)malloc((env_count + need_extra + 1) * sizeof(char *));
    if (!child_env) return -1;

    for (size_t i = 0; i < env_count; i++)
        child_env[i] = (bt_index >= 0 && (int)i == bt_index)
                            ? (char *)bt_off
                            : parent_env[i];
    if (need_extra)
        child_env[env_count++] = (char *)bt_off;
    child_env[env_count] = NULL;

    // File actions: dup2 the shmem fd so it survives exec.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, shmem_fd, target_fd);

    pid_t pid;
    int ret = posix_spawn(&pid, resolved, &actions, NULL,
                          child_argv, child_env);

    posix_spawn_file_actions_destroy(&actions);
    free(child_env);
    return (ret == 0) ? pid : -1;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

int airlock_munmap(void *p, size_t size) {
    return munmap(p, size);
}
