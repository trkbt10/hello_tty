// PTY session management for the hello_tty dylib.
// Uses posix_spawn instead of fork to avoid MoonBit GC corruption.
// See docs/moonbit-fork-safety.md for details.

#ifndef _WIN32
#define _GNU_SOURCE

#include "hello_tty_core.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <spawn.h>
#include <stdint.h>

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <util.h>
#elif defined(__linux__)
#include <pty.h>
#endif

extern char **environ;

int32_t hello_tty_pty_start(const char *shell, int32_t rows, int32_t cols, int32_t *pid_out) {
    if (!shell || !pid_out) return -1;

    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0)
        return -1;

    struct winsize ws = {0};
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ioctl(slave, TIOCSWINSZ, &ws);

    setenv("TERM", "xterm-256color", 1);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&fa, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, slave, STDERR_FILENO);
    if (slave > STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fa, slave);
    posix_spawn_file_actions_addclose(&fa, master);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr,
        POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);

    sigset_t all_sigs, no_mask;
    sigfillset(&all_sigs);
    sigemptyset(&no_mask);
    posix_spawnattr_setsigdefault(&attr, &all_sigs);
    posix_spawnattr_setsigmask(&attr, &no_mask);

    char *argv[] = { (char *)shell, NULL };
    pid_t pid;
    int ret = posix_spawn(&pid, shell, &fa, &attr, argv, environ);

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(slave);

    if (ret != 0) {
        close(master);
        return -1;
    }

    *pid_out = (int32_t)pid;
    return (int32_t)master;
}

int32_t hello_tty_pty_poll(int32_t master_fd, int32_t timeout_ms) {
    struct pollfd pfd = { master_fd, POLLIN, 0 };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) return -1;
    if (ret == 0) return 0;
    if (pfd.revents & POLLHUP) return -2;
    if (pfd.revents & POLLIN) return 1;
    return 0;
}

int32_t hello_tty_pty_read(int32_t master_fd, uint8_t *buf, int32_t max_len) {
    ssize_t n = read(master_fd, buf, (size_t)max_len);
    if (n < 0) return -1;
    return (int32_t)n;
}

int32_t hello_tty_pty_write(int32_t master_fd, const uint8_t *data, int32_t len) {
    ssize_t total = 0;
    while (total < len) {
        ssize_t n = write(master_fd, data + total, (size_t)(len - total));
        if (n < 0) return -1;
        total += n;
    }
    return (int32_t)total;
}

void hello_tty_pty_close(int32_t master_fd) {
    close(master_fd);
}

int32_t hello_tty_pty_resize(int32_t master_fd, int32_t rows, int32_t cols) {
    struct winsize ws = {0};
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    return ioctl(master_fd, TIOCSWINSZ, &ws) < 0 ? -1 : 0;
}

#endif // _WIN32
