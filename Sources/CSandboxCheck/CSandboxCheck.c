// `sandbox_check` is variadic, which Swift cannot call; this is its one caller. It asks the kernel what a process's sandbox
// allows, without the process's cooperation: a process cannot drop the sandbox it was started in (setsid, a cleared
// environment and a double fork all keep it), so this is how the engine finds what is left of an agent's earlier turn.
#include "CSandboxCheck.h"

#if defined(__APPLE__)
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
#define BRAHMA_SANDBOX_FILTER_NONE 0
#define BRAHMA_SANDBOX_FILTER_PATH 1
#define BRAHMA_SANDBOX_CHECK_NO_REPORT 0x40000000

int brahma_sandbox_is_sandboxed(pid_t pid) {
    int r = sandbox_check(pid, 0, BRAHMA_SANDBOX_FILTER_NONE);
    return r < 0 ? -1 : (r != 0 ? 1 : 0);
}

int brahma_sandbox_write_denied(pid_t pid, const char *path) {
    // The kernel answers for existing paths only (a missing one reads as denied).
    int r = sandbox_check(pid, "file-write-data", BRAHMA_SANDBOX_FILTER_PATH | BRAHMA_SANDBOX_CHECK_NO_REPORT, path);
    return r < 0 ? -1 : (r != 0 ? 1 : 0);
}
#else
int brahma_sandbox_is_sandboxed(pid_t pid) { (void)pid; return -1; }
int brahma_sandbox_write_denied(pid_t pid, const char *path) { (void)pid; (void)path; return -1; }
#endif
