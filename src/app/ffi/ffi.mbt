///|
/// Spawn a child process with up to 4 arguments.
/// Returns child PID or -1 on failure.
#borrow(path, arg1, arg2, arg3, arg4)
pub extern "C" fn spawn_simple(
  path : Bytes,
  path_len : Int,
  arg1 : Bytes,
  arg1_len : Int,
  arg2 : Bytes,
  arg2_len : Int,
  arg3 : Bytes,
  arg3_len : Int,
  arg4 : Bytes,
  arg4_len : Int,
) -> Int = "hello_tty_spawn_simple"

///|
/// Get the current process ID.
pub extern "C" fn getpid() -> Int = "hello_tty_getpid"

///|
/// Wait for a child process (non-blocking).
/// Returns: exit status if exited, -1 if still running, -2 on error.
pub extern "C" fn waitpid_nonblock(pid : Int) -> Int = "hello_tty_waitpid_nonblock"

///|
/// Send SIGTERM to a child process.
pub extern "C" fn kill_process(pid : Int) = "hello_tty_kill"

///|
/// Write a debug message to stderr (unbuffered).
#borrow(msg)
pub extern "C" fn debug_log(msg : Bytes, msg_len : Int) = "hello_tty_debug_log"
