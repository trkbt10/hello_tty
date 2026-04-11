///|
/// Open a master/slave PTY pair.
/// Writes master_fd into result_buf[0], slave_fd into result_buf[1].
#borrow(result_buf)
pub extern "C" fn pty_open_master_slave(result_buf : FixedArray[Int]) -> Int = "hello_tty_pty_open_pair"

///|
/// Set the terminal window size on a PTY file descriptor.
pub extern "C" fn pty_set_winsize(fd : Int, rows : Int, cols : Int) -> Int = "hello_tty_pty_set_winsize"

///|
/// Get the terminal window size. Writes rows/cols into result_buf[0] and result_buf[1].
#borrow(result_buf)
pub extern "C" fn pty_get_winsize(
  fd : Int,
  result_buf : FixedArray[Int],
) -> Int = "hello_tty_pty_get_winsize_pair"

///|
/// Fork a child process attached to a new PTY.
/// result_buf[0] receives the master fd.
/// Returns: child PID to parent, 0 to child, -1 on error.
#borrow(result_buf)
pub extern "C" fn pty_forkpty(result_buf : FixedArray[Int]) -> Int = "hello_tty_pty_forkpty"

///|
/// Read from a file descriptor into a buffer.
/// Returns bytes read, 0 on EOF/EAGAIN, -1 on error.
#borrow(buf)
pub extern "C" fn pty_read(
  fd : Int,
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "hello_tty_pty_read"

///|
/// Write bytes to a file descriptor.
/// Returns bytes written, -1 on error.
#borrow(buf)
pub extern "C" fn pty_write(fd : Int, buf : Bytes, len : Int) -> Int = "hello_tty_pty_write"

///|
/// Close a file descriptor.
pub extern "C" fn pty_close(fd : Int) = "hello_tty_pty_close"

///|
/// Terminate a child process (SIGHUP → SIGKILL) and reap with waitpid.
pub extern "C" fn pty_kill_child(pid : Int) = "hello_tty_pty_kill_child"

///|
/// Check if a process is alive. Returns true if alive.
pub extern "C" fn pty_is_pid_alive(pid : Int) -> Int = "hello_tty_pty_is_pid_alive"

///|
/// Set a file descriptor to non-blocking mode.
pub extern "C" fn pty_set_nonblocking(fd : Int) -> Int = "hello_tty_pty_set_nonblocking"

///|
/// Poll a file descriptor for readability.
/// timeout_ms: -1 = block forever, 0 = non-blocking, >0 = timeout in ms.
/// Returns 1 if readable, 0 if timeout, -1 on error.
pub extern "C" fn pty_poll_read(fd : Int, timeout_ms : Int) -> Int = "hello_tty_pty_poll_read"

///|
/// Execute a shell in the child process (after forkpty returns 0).
/// Does not return on success.
#borrow(shell)
pub extern "C" fn pty_exec_shell(shell : Bytes, shell_len : Int) = "hello_tty_pty_exec_shell"

///|
/// Fork a child PTY and exec a shell in a single C call.
/// This avoids returning to MoonBit in the child process (GC safety).
/// shell: UTF-8 path. result_buf[0] = master_fd.
/// Returns: child PID to parent, -1 on error.
#borrow(shell, result_buf)
pub extern "C" fn pty_fork_exec(
  shell : Bytes,
  shell_len : Int,
  rows : Int,
  cols : Int,
  result_buf : FixedArray[Int],
) -> Int = "hello_tty_pty_fork_exec"
