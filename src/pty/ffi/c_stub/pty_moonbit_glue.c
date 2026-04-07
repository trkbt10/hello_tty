// Glue functions bridging MoonBit FixedArray[Int] to C out-params
// MoonBit FixedArray[Int] is passed as int32_t* in C backend

#include "pty_ffi.h"
#include <stdint.h>

int hello_tty_pty_open_pair(int32_t *result_buf) {
  int master_fd, slave_fd;
  int ret = hello_tty_pty_open(&master_fd, &slave_fd);
  if (ret == 0) {
    result_buf[0] = (int32_t)master_fd;
    result_buf[1] = (int32_t)slave_fd;
  }
  return ret;
}

int hello_tty_pty_get_winsize_pair(int fd, int32_t *result_buf) {
  int rows, cols;
  int ret = hello_tty_pty_get_winsize(fd, &rows, &cols);
  if (ret == 0) {
    result_buf[0] = (int32_t)rows;
    result_buf[1] = (int32_t)cols;
  }
  return ret;
}
