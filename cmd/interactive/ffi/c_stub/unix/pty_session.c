// Complete PTY session management in C.
// Uses manual openpty + fork + setsid + dup2 instead of forkpty,
// to ensure correct slave fd setup in the child process.

#ifndef _WIN32
#define _GNU_SOURCE

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <errno.h>

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <util.h>
#elif defined(__linux__)
#include <pty.h>
#endif

// result[0] = master_fd, result[1] = child_pid.
// Returns 0 on success, -1 on error.
int hello_tty_pty_session_start(
    const char *shell, int rows, int cols,
    int32_t *result) {

    char shell_path[256];
    size_t slen = strlen(shell);
    if (slen > 255) slen = 255;
    memcpy(shell_path, shell, slen);
    shell_path[slen] = '\0';

    // Open PTY pair
    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0) {
        fprintf(stderr, "[pty] openpty failed: %s\n", strerror(errno));
        return -1;
    }

    // Set window size on slave
    struct winsize ws = {0};
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ioctl(slave, TIOCSWINSZ, &ws);

    // Block signals before fork
    sigset_t all_sigs, old_mask;
    sigfillset(&all_sigs);
    sigprocmask(SIG_BLOCK, &all_sigs, &old_mask);

    // Use posix_spawn with file actions to set up slave fd.
    // This avoids fork() entirely — posix_spawn may use vfork internally,
    // which doesn't run MoonBit's GC/atexit handlers in the child.
    #include <spawn.h>
    extern char **environ;

    // TERM env var is set by MoonBit before calling this.

    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    posix_spawn_file_actions_adddup2(&file_actions, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&file_actions, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&file_actions, slave, STDERR_FILENO);
    if (slave > STDERR_FILENO) {
        posix_spawn_file_actions_addclose(&file_actions, slave);
    }
    posix_spawn_file_actions_addclose(&file_actions, master);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);

    // Reset all signals to default in child
    sigset_t all_default;
    sigfillset(&all_default);
    posix_spawnattr_setsigdefault(&attr, &all_default);

    // Unblock all signals in child
    sigset_t no_mask;
    sigemptyset(&no_mask);
    posix_spawnattr_setsigmask(&attr, &no_mask);

    char *argv[] = { shell_path, NULL };
    pid_t pid;
    int spawn_ret = posix_spawn(&pid, shell_path, &file_actions, &attr, argv, environ);

    posix_spawn_file_actions_destroy(&file_actions);
    posix_spawnattr_destroy(&attr);
    close(slave);
    sigprocmask(SIG_SETMASK, &old_mask, NULL);

    if (spawn_ret != 0) {
        close(master);
        fprintf(stderr, "[pty] posix_spawn failed: %s\n", strerror(spawn_ret));
        return -1;
    }

    result[0] = master;
    result[1] = (int32_t)pid;
    return 0;
}

int hello_tty_pty_session_poll(int master_fd, int timeout_ms) {
    struct pollfd pfd = { master_fd, POLLIN, 0 };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) return -1;
    if (ret == 0) return 0;
    if (pfd.revents & POLLHUP) return -2;
    if (pfd.revents & POLLIN) return 1;
    return 0;
}

int hello_tty_pty_session_read(int master_fd, uint8_t *buf, int max_len) {
    ssize_t n = read(master_fd, buf, (size_t)max_len);
    if (n < 0) return -1;
    // Data is returned to MoonBit for VT parsing + stdout output.
    return (int)n;
}

int hello_tty_pty_session_write(int master_fd, const uint8_t *data, int len) {
    ssize_t n = write(master_fd, data, (size_t)len);
    if (n < 0) return -1;
    return (int)n;
}

void hello_tty_pty_session_close(int master_fd) {
    close(master_fd);
}

#endif
