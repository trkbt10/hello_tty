// Simple subprocess spawning via fork+exec.
//
// Used to launch the PTY reader subprocess without requiring
// the async runtime (since the main event loop is synchronous).

#ifndef _WIN32

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

// Spawn a child process. Returns the child PID, or -1 on failure.
// argv is a NULL-terminated array of strings.
int hello_tty_spawn(const char *path, const char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        // Child process
        // Reset signals
        signal(SIGPIPE, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        // Create a new process group so the child doesn't get our signals
        setsid();
        execv(path, (char *const *)argv);
        _exit(127); // exec failed
    }
    return (int)pid;
}

// Simple wrapper for MoonBit: spawn with up to 8 string args.
// args are passed as UTF-8 byte arrays with lengths.
// Returns child PID or -1.
int hello_tty_spawn_simple(
    const uint8_t *path, int path_len,
    const uint8_t *arg1, int arg1_len,
    const uint8_t *arg2, int arg2_len,
    const uint8_t *arg3, int arg3_len,
    const uint8_t *arg4, int arg4_len) {

    char path_buf[512];
    char a1[512], a2[512], a3[512], a4[512];

    int plen = path_len < 511 ? path_len : 511;
    memcpy(path_buf, path, (size_t)plen);
    path_buf[plen] = '\0';

    const char *argv[6];
    int argc = 1;
    argv[0] = path_buf;

    if (arg1 && arg1_len > 0) {
        int l = arg1_len < 511 ? arg1_len : 511;
        memcpy(a1, arg1, (size_t)l); a1[l] = '\0';
        argv[argc++] = a1;
    }
    if (arg2 && arg2_len > 0) {
        int l = arg2_len < 511 ? arg2_len : 511;
        memcpy(a2, arg2, (size_t)l); a2[l] = '\0';
        argv[argc++] = a2;
    }
    if (arg3 && arg3_len > 0) {
        int l = arg3_len < 511 ? arg3_len : 511;
        memcpy(a3, arg3, (size_t)l); a3[l] = '\0';
        argv[argc++] = a3;
    }
    if (arg4 && arg4_len > 0) {
        int l = arg4_len < 511 ? arg4_len : 511;
        memcpy(a4, arg4, (size_t)l); a4[l] = '\0';
        argv[argc++] = a4;
    }
    argv[argc] = NULL;

    return hello_tty_spawn(path_buf, argv);
}

// Get the current process ID.
int hello_tty_getpid(void) {
    return (int)getpid();
}

// Wait for a child process to exit (non-blocking).
// Returns: exit status if exited, -1 if still running, -2 on error.
int hello_tty_waitpid_nonblock(int pid) {
    int status;
    pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
    if (result == 0) return -1; // Still running
    if (result < 0) return -2;  // Error
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -2;
}

// Send SIGTERM to a child process.
void hello_tty_kill(int pid) {
    kill((pid_t)pid, SIGTERM);
}

#endif // _WIN32
