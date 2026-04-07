// Complete interactive PTY session implemented entirely in C.
// This eliminates all MoonBit PTY/FFI from the equation.
#ifndef _WIN32
#define _GNU_SOURCE

#include <unistd.h>
#include <poll.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/ioctl.h>
#include "moonbit.h"

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <util.h>
#elif defined(__linux__)
#include <pty.h>
#endif

// Run a complete interactive PTY session in C.
// Forks bash, relays stdin↔PTY, writes all PTY output to stdout.
// Returns the number of bytes read from PTY total.
int hello_tty_run_interactive_c(void) {
    char shell[] = "/bin/bash";

    sigset_t all_sigs, old_mask;
    sigfillset(&all_sigs);
    sigprocmask(SIG_BLOCK, &all_sigs, &old_mask);

    int master;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) {
        sigprocmask(SIG_SETMASK, &old_mask, NULL);
        return -1;
    }

    if (pid == 0) {
        signal(SIGCHLD, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGSEGV, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);

        struct winsize ws = { .ws_row = 24, .ws_col = 80 };
        ioctl(STDIN_FILENO, TIOCSWINSZ, &ws);
        setenv("TERM", "xterm-256color", 1);
        execl(shell, "-bash", (char *)NULL);
        _exit(127);
    }

    sigprocmask(SIG_SETMASK, &old_mask, NULL);
    fprintf(stderr, "[c_interactive] forked pid=%d master=%d\n", (int)pid, master);

    int total_read = 0;
    int stdin_open = 1;
    char buf[4096];

    for (int iter = 0; iter < 2000; iter++) {
        struct pollfd pfds[2];
        pfds[0].fd = master;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = stdin_open ? STDIN_FILENO : -1;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;

        int ret = poll(pfds, 2, 30);
        if (ret < 0) break;

        if (pfds[0].revents & POLLIN) {
            ssize_t n = read(master, buf, sizeof(buf));
            if (n > 0) {
                write(STDOUT_FILENO, buf, (size_t)n);
                total_read += (int)n;
            } else {
                break;
            }
        }
        if (pfds[0].revents & POLLHUP) break;

        if (stdin_open && (pfds[1].revents & POLLIN)) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n > 0) {
                write(master, buf, (size_t)n);
            } else {
                stdin_open = 0;
            }
        }
        if (stdin_open && (pfds[1].revents & POLLHUP)) {
            stdin_open = 0;
        }
    }

    close(master);
    fprintf(stderr, "[c_interactive] done, total_read=%d\n", total_read);
    return total_read;
}

#endif


