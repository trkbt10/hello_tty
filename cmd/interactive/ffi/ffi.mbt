///|
pub extern "C" fn enable_raw_mode() -> Int = "hello_tty_enable_raw_mode"

///|
pub extern "C" fn restore_mode(handle : Int) = "hello_tty_restore_mode"

///|
pub extern "C" fn poll_stdin(timeout_ms : Int) -> Int = "hello_tty_poll_stdin"

///|
#borrow(buf)
pub extern "C" fn read_stdin(buf : FixedArray[Byte], max_len : Int) -> Int = "hello_tty_read_stdin"

///|
#borrow(data)
pub extern "C" fn write_stdout(data : Bytes, len : Int) -> Int = "hello_tty_write_stdout"

///|
#borrow(data)
pub extern "C" fn debug_log(data : Bytes, len : Int) -> Int = "hello_tty_debug_log"

// ---------- PTY session (pure C, fork-safe) ----------

///|
/// Start a PTY session. Forks shell entirely in C (no MoonBit GC in child).
/// shell: null-terminated shell path.
/// result[0] = master_fd, result[1] = child_pid.
/// Returns 0 on success.
#borrow(shell, result)
pub extern "C" fn pty_session_start(
  shell : Bytes,
  rows : Int,
  cols : Int,
  result : FixedArray[Int],
) -> Int = "hello_tty_pty_session_start"

///|
/// Poll PTY master. Returns 1=readable, 0=timeout, -2=EOF, -1=error.
pub extern "C" fn pty_session_poll(master_fd : Int, timeout_ms : Int) -> Int = "hello_tty_pty_session_poll"

///|
/// Read from PTY master.
#borrow(buf)
pub extern "C" fn pty_session_read(
  master_fd : Int,
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "hello_tty_pty_session_read"

///|
/// Write to PTY master.
#borrow(data)
pub extern "C" fn pty_session_write(
  master_fd : Int,
  data : Bytes,
  len : Int,
) -> Int = "hello_tty_pty_session_write"

///|
/// Close PTY master.
pub extern "C" fn pty_session_close(master_fd : Int) = "hello_tty_pty_session_close"
