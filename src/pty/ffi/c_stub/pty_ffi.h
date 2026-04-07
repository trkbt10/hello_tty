// PTY FFI header for hello_tty
// Wraps POSIX openpty/forkpty for MoonBit C backend

#ifndef HELLO_TTY_PTY_FFI_H
#define HELLO_TTY_PTY_FFI_H

#include <stdint.h>

// Open a PTY master/slave pair. Returns 0 on success, -1 on failure.
// On success, *master_fd and *slave_fd are set.
int hello_tty_pty_open(int *master_fd, int *slave_fd);

// Set terminal window size (rows, cols) on the given fd.
int hello_tty_pty_set_winsize(int fd, int rows, int cols);

// Get terminal window size. Returns 0 on success.
int hello_tty_pty_get_winsize(int fd, int *rows, int *cols);

// Fork a child process attached to a new PTY.
// Returns: child PID to parent (master_fd set), 0 to child, -1 on error.
int hello_tty_pty_forkpty(int *master_fd);

// Read from fd into buf. Returns bytes read, 0 on EOF, -1 on error.
int hello_tty_pty_read(int fd, unsigned char *buf, int max_len);

// Write buf to fd. Returns bytes written, -1 on error.
int hello_tty_pty_write(int fd, const unsigned char *buf, int len);

// Close a file descriptor.
void hello_tty_pty_close(int fd);

// Set fd to non-blocking mode. Returns 0 on success.
int hello_tty_pty_set_nonblocking(int fd);

// Poll fd for readability with timeout_ms (-1 = block, 0 = non-blocking).
// Returns 1 if readable, 0 if timeout, -1 on error.
int hello_tty_pty_poll_read(int fd, int timeout_ms);

// Get the name of the slave PTY device from master fd.
// Writes into name_buf, returns 0 on success.
int hello_tty_pty_get_slave_name(int master_fd, unsigned char *name_buf, int buf_len);

// Execute a shell in the child side of a forkpty.
// This is called after forkpty returns 0 (in the child).
// shell: path to shell (e.g. "/bin/bash")
// Does not return on success.
void hello_tty_pty_exec_shell(const unsigned char *shell, int shell_len);

#endif // HELLO_TTY_PTY_FFI_H
