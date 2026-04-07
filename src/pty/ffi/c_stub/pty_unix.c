// POSIX PTY implementation (macOS, Linux)

#ifdef __linux__
#define _GNU_SOURCE
#endif

#ifndef _WIN32

#include "pty_ffi.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <util.h>
#elif defined(__linux__)
#include <pty.h>
#include <utmp.h>
#endif

// ---------- PTY lifecycle ----------

int hello_tty_pty_open(int *master_fd, int *slave_fd) {
  if (openpty(master_fd, slave_fd, NULL, NULL, NULL) < 0) {
    return -1;
  }
  return 0;
}

int hello_tty_pty_set_winsize(int fd, int rows, int cols) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)rows;
  ws.ws_col = (unsigned short)cols;
  if (ioctl(fd, TIOCSWINSZ, &ws) < 0) {
    return -1;
  }
  return 0;
}

int hello_tty_pty_get_winsize(int fd, int *rows, int *cols) {
  struct winsize ws;
  if (ioctl(fd, TIOCGWINSZ, &ws) < 0) {
    return -1;
  }
  *rows = ws.ws_row;
  *cols = ws.ws_col;
  return 0;
}

int hello_tty_pty_forkpty(int *master_fd) {
  pid_t pid = forkpty(master_fd, NULL, NULL, NULL);
  return (int)pid;
}

// Fork a child PTY and exec a shell using posix_spawn.
// Uses openpty + posix_spawn instead of forkpty to avoid
// MoonBit GC corruption in the child process (MoonBit's GC
// registers pthread_atfork handlers that crash after fork).
//
// shell: UTF-8 path bytes (not necessarily null-terminated).
// result_buf[0] = master_fd.
// Returns: child PID to parent, -1 on error.
int hello_tty_pty_fork_exec(const unsigned char *shell, int shell_len,
                             int rows, int cols, int *result_buf) {
  #include <spawn.h>
  extern char **environ;

  char shell_path[256];
  int slen = shell_len < 255 ? shell_len : 255;
  memcpy(shell_path, shell, (size_t)slen);
  shell_path[slen] = '\0';

  // Open PTY pair
  int master_fd, slave_fd;
  if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) < 0)
    return -1;

  // Set window size on slave
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)rows;
  ws.ws_col = (unsigned short)cols;
  ioctl(slave_fd, TIOCSWINSZ, &ws);

  // TERM env var is set by MoonBit before calling this.

  // Configure posix_spawn file actions
  posix_spawn_file_actions_t file_actions;
  posix_spawn_file_actions_init(&file_actions);
  posix_spawn_file_actions_adddup2(&file_actions, slave_fd, STDIN_FILENO);
  posix_spawn_file_actions_adddup2(&file_actions, slave_fd, STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&file_actions, slave_fd, STDERR_FILENO);
  if (slave_fd > STDERR_FILENO)
    posix_spawn_file_actions_addclose(&file_actions, slave_fd);
  posix_spawn_file_actions_addclose(&file_actions, master_fd);

  // Configure spawn attributes
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr,
    POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);

  sigset_t all_sigs;
  sigfillset(&all_sigs);
  posix_spawnattr_setsigdefault(&attr, &all_sigs);

  sigset_t no_mask;
  sigemptyset(&no_mask);
  posix_spawnattr_setsigmask(&attr, &no_mask);

  char *argv[] = { shell_path, NULL };
  pid_t pid;
  int ret = posix_spawn(&pid, shell_path, &file_actions, &attr, argv, environ);

  posix_spawn_file_actions_destroy(&file_actions);
  posix_spawnattr_destroy(&attr);
  close(slave_fd);

  if (ret != 0) {
    close(master_fd);
    return -1;
  }

  result_buf[0] = master_fd;
  return (int)pid;
}

// ---------- I/O ----------

int hello_tty_pty_read(int fd, unsigned char *buf, int max_len) {
  ssize_t n = read(fd, buf, (size_t)max_len);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1;
  }
  return (int)n;
}

int hello_tty_pty_write(int fd, const unsigned char *buf, int len) {
  ssize_t total = 0;
  while (total < len) {
    ssize_t n = write(fd, buf + total, (size_t)(len - total));
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
      return -1;
    }
    total += n;
  }
  return (int)total;
}

void hello_tty_pty_close(int fd) {
  close(fd);
}

int hello_tty_pty_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
  return 0;
}

int hello_tty_pty_poll_read(int fd, int timeout_ms) {
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int ret = poll(&pfd, 1, timeout_ms);
  if (ret < 0) return -1;
  if (ret == 0) return 0;
  if (pfd.revents & (POLLIN | POLLHUP)) return 1;
  return -1;
}

int hello_tty_pty_get_slave_name(int master_fd, unsigned char *name_buf, int buf_len) {
  // ptsname is not thread-safe; use ptsname_r on Linux
#ifdef __linux__
  if (ptsname_r(master_fd, (char *)name_buf, (size_t)buf_len) != 0) {
    return -1;
  }
#else
  const char *name = ptsname(master_fd);
  if (name == NULL) return -1;
  size_t len = strlen(name);
  if ((int)len >= buf_len) return -1;
  memcpy(name_buf, name, len + 1);
#endif
  return 0;
}

void hello_tty_pty_exec_shell(const unsigned char *shell, int shell_len) {
  // Null-terminate the shell path
  char shell_path[256];
  if (shell_len >= (int)sizeof(shell_path)) shell_len = (int)sizeof(shell_path) - 1;
  memcpy(shell_path, shell, (size_t)shell_len);
  shell_path[shell_len] = '\0';

  // Reset signals to default for the child
  signal(SIGCHLD, SIG_DFL);
  signal(SIGHUP, SIG_DFL);
  signal(SIGINT, SIG_DFL);
  signal(SIGQUIT, SIG_DFL);
  signal(SIGTERM, SIG_DFL);
  signal(SIGALRM, SIG_DFL);

  // TERM env var is set by MoonBit before calling this.

  // Execute the shell as a login shell
  // Convention: prefix argv[0] with '-' to indicate login shell
  char login_name[258];
  login_name[0] = '-';
  const char *basename = strrchr(shell_path, '/');
  if (basename) {
    basename++;
  } else {
    basename = shell_path;
  }
  strncpy(login_name + 1, basename, sizeof(login_name) - 2);
  login_name[sizeof(login_name) - 1] = '\0';

  execl(shell_path, login_name, (char *)NULL);
  // If execl returns, it failed
  _exit(127);
}

#endif // _WIN32
