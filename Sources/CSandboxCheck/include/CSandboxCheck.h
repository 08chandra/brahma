#ifndef CSANDBOXCHECK_H
#define CSANDBOXCHECK_H
#include <sys/types.h>

/// 1 when process `pid` runs under a sandbox profile, 0 when it does not, -1 when that cannot be told (Linux: always -1).
int brahma_sandbox_is_sandboxed(pid_t pid);

/// 0 when the sandbox of process `pid` allows it to write `path` (which must exist; a missing path reads as denied), 1 when
/// it denies it, -1 when that cannot be told. A process without a sandbox is allowed everything (0). Nothing is logged for a denial.
int brahma_sandbox_write_denied(pid_t pid, const char *path);

#endif
