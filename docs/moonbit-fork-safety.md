# fork() Safety in the MoonBit Native Backend

## Overview

The runtime used by the MoonBit native (C) backend is **fork-unsafe**.
If MoonBit code runs in a child process after `fork()`, the GC (garbage collector)
can operate in a corrupted state and crash with **SIGSEGV (signal 11, exit code 139)**.

## Root Cause

The MoonBit runtime registers `pthread_atfork` handlers.
`fork()` copies the parent's memory space, but it does not copy threads.
As a result, GC threads and lock states can become inconsistent in the child process.

The child process can crash when any of the following occurs:
- MoonBit heap allocation (`Bytes::new`, `Array::new`, etc.)
- A GC cycle starts
- GC is triggered from a signal handler

## Symptoms

```text
# With fork():
child wait status: 139   # = 128 + 11 = SIGSEGV

# Through PTY:
# poll() -> POLLIN|POLLHUP (revents=0x11)
# read() -> 0 (EOF)
# -> Child crashed before exec, so the slave side was closed
```

The same issue occurs with `forkpty()`.
The MoonBit atfork handler runs before the child calls `exec`, causing a crash.
The PTY slave closes immediately, and the master side observes EOF.

## Solution: Use posix_spawn

On macOS, `posix_spawn()` is implemented internally with `vfork()` + `exec()`.
With `vfork()`, the child shares memory with the parent and must not run arbitrary code
before `exec`, so MoonBit GC handlers are not entered in the child path.

### Implementation Pattern

```c
#include <spawn.h>
#include <util.h>  // openpty (macOS)

extern char **environ;

int spawn_shell_with_pty(const char *shell, int rows, int cols,
                          int *master_fd_out, pid_t *pid_out) {
    // 1. Open a PTY pair (before any process split)
    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0)
        return -1;

    // 2. Configure window size on the slave side
    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    ioctl(slave, TIOCSWINSZ, &ws);

    // 3. Route slave fd to stdin/stdout/stderr via posix_spawn file actions
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&fa, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, slave, STDERR_FILENO);
    if (slave > STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fa, slave);
    posix_spawn_file_actions_addclose(&fa, master);

    // 4. Spawn attributes: new session + signal reset
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr,
        POSIX_SPAWN_SETSID |
        POSIX_SPAWN_SETSIGDEF |
        POSIX_SPAWN_SETSIGMASK);

    sigset_t all_sigs, no_mask;
    sigfillset(&all_sigs);
    sigemptyset(&no_mask);
    posix_spawnattr_setsigdefault(&attr, &all_sigs);
    posix_spawnattr_setsigmask(&attr, &no_mask);

    // 5. Spawn child process
    setenv("TERM", "xterm-256color", 1);
    char *argv[] = { (char *)shell, NULL };
    pid_t pid;
    int ret = posix_spawn(&pid, shell, &fa, &attr, argv, environ);

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(slave);

    if (ret != 0) { close(master); return -1; }

    *master_fd_out = master;
    *pid_out = pid;
    return 0;
}
```

### MoonBit-side Usage

```moonbit
// FFI declaration
#borrow(shell)
#borrow(result)
pub extern "C" fn pty_session_start(
  shell : Bytes, rows : Int, cols : Int,
  result : FixedArray[Int],
) -> Int = "hello_tty_pty_session_start"

// Example usage
let shell = @utf8.encode("/bin/bash\x00")
let result : FixedArray[Int] = FixedArray::make(2, 0)
let ret = @ffi.pty_session_start(shell, 24, 80, result)
let master_fd = result[0]
let child_pid = result[1]
// After this, just poll/read/write on master_fd
```

## What Not To Do

```moonbit
// BAD: running MoonBit code in the child process after fork
let pid = @ffi.pty_forkpty(result_buf)
if pid == 0 {
    // MoonBit GC can run here and crash
    let shell_bytes = @utf8.encode(shell)  // <- GC allocation!
    @ffi.pty_exec_shell(shell_bytes, shell_bytes.length())
}
```

```c
// BAD: returning control to MoonBit after forkpty
int hello_tty_pty_forkpty(int *master_fd) {
    pid_t pid = forkpty(master_fd, NULL, NULL, NULL);
    return (int)pid;
    // -> If pid == 0 and control returns to MoonBit, GC state is broken
}
```

## Scope

- Verified with **MoonBit 0.1.20260330**
- macOS (arm64) + MoonBit native C backend
- The same issue is likely on Linux
- Because this depends on MoonBit runtime internals, future versions may improve this behavior

## Related Files

- `src/pty/ffi/c_stub/pty_unix.c` - `hello_tty_pty_fork_exec` (posix_spawn version)
- `cmd/interactive/ffi/c_stub/pty_session.c` - PTY session control for interactive testing
