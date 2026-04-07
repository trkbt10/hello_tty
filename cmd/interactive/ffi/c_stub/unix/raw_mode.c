// Terminal raw mode control for the interactive test.

#ifndef _WIN32

#include <termios.h>
#include <unistd.h>
#include <poll.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

static struct termios saved_termios[4];
static int next_handle = 0;

int hello_tty_enable_raw_mode(void) {
    if (next_handle >= 4) return -1;
    int h = next_handle++;
    if (tcgetattr(STDIN_FILENO, &saved_termios[h]) < 0) return -1;

    struct termios raw = saved_termios[h];
    raw.c_iflag &= ~(unsigned)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~(unsigned)(OPOST);
    raw.c_cflag |= (unsigned)(CS8);
    raw.c_lflag &= ~(unsigned)(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) < 0) return -1;
    return h;
}

void hello_tty_restore_mode(int handle) {
    if (handle < 0 || handle >= 4) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios[handle]);
}

int hello_tty_poll_stdin(int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) return -1;
    if (ret == 0) return 0;
    if (pfd.revents & POLLHUP) return -1;  // pipe closed
    return (pfd.revents & POLLIN) ? 1 : 0;
}

int hello_tty_read_stdin(uint8_t *buf, int max_len) {
    ssize_t n = read(STDIN_FILENO, buf, (size_t)max_len);
    if (n < 0) return -1;
    return (int)n;
}

int hello_tty_write_stdout(const uint8_t *data, int len) {
    ssize_t total = 0;
    while (total < len) {
        ssize_t n = write(STDOUT_FILENO, data + total, (size_t)(len - total));
        if (n < 0) return -1;
        total += n;
    }
    return (int)total;
}

// Debug: write to stderr
int hello_tty_debug_log(const uint8_t *data, int len) {
    return (int)write(STDERR_FILENO, data, (size_t)len);
}

#endif // _WIN32
