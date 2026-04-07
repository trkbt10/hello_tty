///|
/// Spawn the PTY reader subprocess.
///
/// The PTY reader is a separate binary that:
///   1. Connects to the given IPC socket path
///   2. Forks a shell via PTY
///   3. Bridges PTY I/O to IPC messages
///
/// Returns the child PID.
pub fn spawn_pty_reader(
  binary_path : String,
  socket_path : String,
  shell : String,
  rows : Int,
  cols : Int,
) -> Int raise AppError {
  let path_bytes = @utf8.encode(binary_path)
  let arg1_bytes = @utf8.encode(socket_path)
  let arg2_bytes = @utf8.encode(shell)
  let arg3_bytes = @utf8.encode(rows.to_string())
  let arg4_bytes = @utf8.encode(cols.to_string())
  let pid = @spawn_ffi.spawn_simple(
    path_bytes,
    path_bytes.length(),
    arg1_bytes,
    arg1_bytes.length(),
    arg2_bytes,
    arg2_bytes.length(),
    arg3_bytes,
    arg3_bytes.length(),
    arg4_bytes,
    arg4_bytes.length(),
  )
  if pid < 0 {
    raise IpcError("Failed to spawn PTY reader subprocess")
  }
  pid
}

///|
/// Get the current process ID (for generating unique socket paths).
pub fn current_pid() -> Int {
  @spawn_ffi.getpid()
}

///|
/// Check if a child process is still running.
pub fn is_child_alive(pid : Int) -> Bool {
  @spawn_ffi.waitpid_nonblock(pid) == -1
}

///|
/// Terminate a child process.
pub fn kill_child(pid : Int) -> Unit {
  @spawn_ffi.kill_process(pid)
}
