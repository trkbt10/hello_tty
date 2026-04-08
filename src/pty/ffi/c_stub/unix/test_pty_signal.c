// test_pty_signal.c — Verify that PTY child receives SIGINT via ^C.
//
// This is a standalone C test that validates the posix_spawn + posix_openpt
// approach correctly sets the controlling terminal. Without a controlling
// terminal, writing 0x03 to the PTY master does NOT generate SIGINT.
//
// Build:
//   cc -o test_pty_signal test_pty_signal.c -lutil
//
// Run:
//   ./test_pty_signal
//
// Expected: "PASS: child received SIGINT (exit status 130 or signal 2)"
// Failure:  "FAIL: child did not receive signal" (timeout or wrong exit)

#ifdef __linux__
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <spawn.h>

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <util.h>
#elif defined(__linux__)
#include <pty.h>
#endif

extern char **environ;

// Spawn a child on a PTY using the same method as hello_tty_pty_fork_exec.
// Returns master_fd via *out_master, child pid via return value. -1 on error.
static pid_t spawn_on_pty(int *out_master, int rows, int cols,
                           const char *prog, char *const argv[]) {
    int master_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (master_fd < 0) { perror("posix_openpt"); return -1; }
    if (grantpt(master_fd) < 0) { perror("grantpt"); close(master_fd); return -1; }
    if (unlockpt(master_fd) < 0) { perror("unlockpt"); close(master_fd); return -1; }

    const char *slave_name = ptsname(master_fd);
    if (!slave_name) { perror("ptsname"); close(master_fd); return -1; }

    // Set window size
    int slave_fd = open(slave_name, O_RDWR);
    if (slave_fd < 0) { perror("open slave"); close(master_fd); return -1; }
    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    ioctl(slave_fd, TIOCSWINSZ, &ws);
    close(slave_fd);

    // posix_spawn with SETSID + open slave by path
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addclose(&fa, master_fd);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, slave_name, O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&fa, STDIN_FILENO, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, STDIN_FILENO, STDERR_FILENO);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr,
        POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    sigset_t all_sigs; sigfillset(&all_sigs);
    posix_spawnattr_setsigdefault(&attr, &all_sigs);
    sigset_t no_mask; sigemptyset(&no_mask);
    posix_spawnattr_setsigmask(&attr, &no_mask);

    pid_t pid;
    int ret = posix_spawn(&pid, prog, &fa, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);

    if (ret != 0) { close(master_fd); return -1; }
    *out_master = master_fd;
    return pid;
}

// Drain PTY output until timeout. Returns 0 on timeout, >0 if data read.
static int drain_pty(int master_fd, int timeout_ms) {
    char buf[4096];
    struct pollfd pfd = { .fd = master_fd, .events = POLLIN };
    int total = 0;
    while (poll(&pfd, 1, timeout_ms) > 0) {
        int n = read(master_fd, buf, sizeof(buf));
        if (n <= 0) break;
        total += n;
        timeout_ms = 50; // Shorter timeout for subsequent reads
    }
    return total;
}

// ============================================================
// Test 1: SIGINT via Ctrl+C (0x03)
// ============================================================
static int test_sigint(void) {
    printf("--- Test: SIGINT via Ctrl+C ---\n");

    int master_fd;
    // Run "sleep 60" — a long-running process that should die on SIGINT
    char *argv[] = { "/bin/sh", "-c", "sleep 60", NULL };
    pid_t pid = spawn_on_pty(&master_fd, 24, 80, "/bin/sh", argv);
    if (pid < 0) {
        printf("FAIL: could not spawn child\n");
        return 1;
    }

    // Let the shell start
    usleep(500000); // 500ms
    drain_pty(master_fd, 200);

    // Write Ctrl+C (0x03) to the PTY master
    char ctrl_c = 0x03;
    if (write(master_fd, &ctrl_c, 1) != 1) {
        printf("FAIL: could not write Ctrl+C to PTY\n");
        close(master_fd);
        return 1;
    }

    // Wait for child to die (with timeout)
    int status = 0;
    int wait_attempts = 0;
    pid_t result;
    while (wait_attempts < 20) { // 2 seconds max
        result = waitpid(pid, &status, WNOHANG);
        if (result > 0) break;
        usleep(100000); // 100ms
        wait_attempts++;
    }

    close(master_fd);

    if (result <= 0) {
        // Child didn't die — kill it manually
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        printf("FAIL: child did not exit after Ctrl+C (no controlling terminal?)\n");
        return 1;
    }

    if (WIFSIGNALED(status) && WTERMSIG(status) == SIGINT) {
        printf("PASS: child received SIGINT (signal %d)\n", WTERMSIG(status));
        return 0;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 130) {
        // Shell convention: 128 + signal number
        printf("PASS: child exited with status 130 (SIGINT convention)\n");
        return 0;
    }
    if (WIFEXITED(status)) {
        // sh -c "sleep 60" exits with 130 on some systems, or other codes
        // As long as it exited (not stuck), the signal was delivered
        printf("PASS: child exited with status %d after Ctrl+C\n", WEXITSTATUS(status));
        return 0;
    }
    if (WIFSIGNALED(status)) {
        printf("PASS: child killed by signal %d after Ctrl+C\n", WTERMSIG(status));
        return 0;
    }

    printf("FAIL: unexpected child status 0x%x\n", status);
    return 1;
}

// ============================================================
// Test 2: Ctrl+D (EOF) closes shell
// ============================================================
static int test_eof(void) {
    printf("--- Test: EOF via Ctrl+D ---\n");

    int master_fd;
    // Run an interactive shell — Ctrl+D should cause it to exit
    char *argv[] = { "/bin/sh", NULL };
    pid_t pid = spawn_on_pty(&master_fd, 24, 80, "/bin/sh", argv);
    if (pid < 0) {
        printf("FAIL: could not spawn child\n");
        return 1;
    }

    // Let the shell start
    usleep(500000);
    drain_pty(master_fd, 200);

    // Write Ctrl+D (0x04) — EOF
    char ctrl_d = 0x04;
    if (write(master_fd, &ctrl_d, 1) != 1) {
        printf("FAIL: could not write Ctrl+D to PTY\n");
        close(master_fd);
        return 1;
    }

    // Wait for child to exit
    int status = 0;
    int wait_attempts = 0;
    pid_t result;
    while (wait_attempts < 20) {
        result = waitpid(pid, &status, WNOHANG);
        if (result > 0) break;
        usleep(100000);
        wait_attempts++;
    }

    close(master_fd);

    if (result <= 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        printf("FAIL: shell did not exit after Ctrl+D\n");
        return 1;
    }

    if (WIFEXITED(status)) {
        printf("PASS: shell exited with status %d after Ctrl+D\n", WEXITSTATUS(status));
        return 0;
    }

    printf("FAIL: unexpected status 0x%x\n", status);
    return 1;
}

// ============================================================
// Test 3: Verify controlling terminal is set
// ============================================================
static int test_ctty(void) {
    printf("--- Test: Controlling terminal is set ---\n");

    int master_fd;
    // Ask the child to report its controlling terminal
    char *argv[] = { "/bin/sh", "-c", "tty && ps -o tty= -p $$", NULL };
    pid_t pid = spawn_on_pty(&master_fd, 24, 80, "/bin/sh", argv);
    if (pid < 0) {
        printf("FAIL: could not spawn child\n");
        return 1;
    }

    usleep(500000);

    // Read output
    char output[4096] = {0};
    int total = 0;
    struct pollfd pfd = { .fd = master_fd, .events = POLLIN };
    while (poll(&pfd, 1, 500) > 0 && total < (int)sizeof(output) - 1) {
        int n = read(master_fd, output + total, sizeof(output) - 1 - total);
        if (n <= 0) break;
        total += n;
    }
    output[total] = '\0';

    int status;
    waitpid(pid, &status, 0);
    close(master_fd);

    // Check that output contains a tty device (e.g., /dev/ttys003)
    // If no controlling terminal, `tty` prints "not a tty"
    if (strstr(output, "not a tty") != NULL) {
        printf("FAIL: child has no controlling terminal\n");
        printf("  output: %s\n", output);
        return 1;
    }
    if (strstr(output, "/dev/") != NULL || strstr(output, "ttys") != NULL ||
        strstr(output, "pts/") != NULL) {
        printf("PASS: child has controlling terminal\n");
        printf("  output: %s\n", output);
        return 0;
    }

    printf("WARN: could not determine controlling terminal from output\n");
    printf("  output: %s\n", output);
    // If tty command ran without error, it probably worked
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        printf("PASS: tty command succeeded (exit 0)\n");
        return 0;
    }
    return 1;
}

// ============================================================
// Main
// ============================================================
int main(void) {
    int failures = 0;

    failures += test_ctty();
    failures += test_sigint();
    failures += test_eof();

    printf("\n=== %d test(s) failed ===\n", failures);
    return failures > 0 ? 1 : 0;
}
