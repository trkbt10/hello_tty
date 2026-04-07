///|
/// Open a new PTY master/slave pair with the given initial window size.
pub fn Pty::open(rows? : Int = 24, cols? : Int = 80) -> Pty raise PtyError {
  let result_buf : FixedArray[Int] = FixedArray::make(2, 0)
  let ret = @ffi.pty_open_master_slave(result_buf)
  if ret < 0 {
    raise OpenFailed("openpty() failed")
  }
  let master_fd = result_buf[0]
  let slave_fd = result_buf[1]
  // Set initial window size on the slave
  let ws_ret = @ffi.pty_set_winsize(slave_fd, rows, cols)
  if ws_ret < 0 {
    @ffi.pty_close(master_fd)
    @ffi.pty_close(slave_fd)
    raise WinsizeFailed("Failed to set initial window size")
  }
  { master_fd, slave_fd, rows, cols }
}

///|
/// Close both sides of the PTY pair.
pub fn Pty::close(self : Pty) -> Unit {
  @ffi.pty_close(self.master_fd)
  @ffi.pty_close(self.slave_fd)
}

///|
/// Fork a child process attached to a new PTY.
/// Returns a `PtyChild` in the parent process.
/// In the child process, this function does not return — it execs the shell.
pub fn fork_with_shell(
  shell? : String = "/bin/bash",
  rows? : Int = 24,
  cols? : Int = 80,
) -> PtyChild raise PtyError {
  let result_buf : FixedArray[Int] = FixedArray::make(1, 0)
  let pid = @ffi.pty_forkpty(result_buf)
  if pid < 0 {
    raise ForkFailed("forkpty() failed")
  }
  if pid == 0 {
    // Child process: set window size and exec the shell
    let shell_bytes = @utf8.encode(shell)
    @ffi.pty_exec_shell(shell_bytes, shell_bytes.length())
    // exec_shell does not return on success; if we reach here, it failed
    raise ForkFailed("exec failed for shell: " + shell)
  }
  // Parent process
  let master_fd = result_buf[0]
  let ws_ret = @ffi.pty_set_winsize(master_fd, rows, cols)
  if ws_ret < 0 {
    // Non-fatal: log warning but continue
    ()
  }
  { master_fd, pid, rows, cols }
}

///|
/// Read bytes from the PTY master.
/// Returns the bytes read, or an empty Bytes on EOF/EAGAIN.
pub fn PtyChild::read(self : PtyChild) -> Bytes raise PtyError {
  let buf : FixedArray[Byte] = FixedArray::make(default_read_buf_size, b'\x00')
  let n = @ffi.pty_read(self.master_fd, buf, default_read_buf_size)
  if n < 0 {
    raise IoError("read() failed on PTY master")
  }
  if n == 0 {
    return Bytes::new(0)
  }
  let arr : Array[Byte] = Array::new(capacity=n)
  for i in 0..<n {
    arr.push(buf[i])
  }
  Bytes::from_array(arr)
}

///|
/// Read from PTY master with a custom buffer size.
pub fn PtyChild::read_with_buf_size(
  self : PtyChild,
  buf_size : Int,
) -> Bytes raise PtyError {
  let buf : FixedArray[Byte] = FixedArray::make(buf_size, b'\x00')
  let n = @ffi.pty_read(self.master_fd, buf, buf_size)
  if n < 0 {
    raise IoError("read() failed on PTY master")
  }
  if n == 0 {
    return Bytes::new(0)
  }
  let arr : Array[Byte] = Array::new(capacity=n)
  for i in 0..<n {
    arr.push(buf[i])
  }
  Bytes::from_array(arr)
}

///|
/// Write bytes to the PTY master (sends data to the child shell).
pub fn PtyChild::write(self : PtyChild, data : Bytes) -> Unit raise PtyError {
  let n = @ffi.pty_write(self.master_fd, data, data.length())
  if n < 0 {
    raise IoError("write() failed on PTY master")
  }
}

///|
/// Write a string to the PTY master.
pub fn PtyChild::write_string(
  self : PtyChild,
  s : String,
) -> Unit raise PtyError {
  let bytes = @utf8.encode(s)
  self.write(bytes)
}

///|
/// Resize the PTY terminal.
pub fn PtyChild::resize(
  self : PtyChild,
  rows : Int,
  cols : Int,
) -> Unit raise PtyError {
  let ret = @ffi.pty_set_winsize(self.master_fd, rows, cols)
  if ret < 0 {
    raise WinsizeFailed("Failed to set window size")
  }
  self.rows = rows
  self.cols = cols
}

///|
/// Get current window size from the PTY.
pub fn PtyChild::get_winsize(self : PtyChild) -> WinSize raise PtyError {
  let result_buf : FixedArray[Int] = FixedArray::make(2, 0)
  let ret = @ffi.pty_get_winsize(self.master_fd, result_buf)
  if ret < 0 {
    raise WinsizeFailed("Failed to get window size")
  }
  { rows: result_buf[0], cols: result_buf[1] }
}

///|
/// Set the master fd to non-blocking mode.
pub fn PtyChild::set_nonblocking(self : PtyChild) -> Unit raise PtyError {
  let ret = @ffi.pty_set_nonblocking(self.master_fd)
  if ret < 0 {
    raise IoError("Failed to set non-blocking mode")
  }
}

///|
/// Poll the master fd for readability.
/// Returns true if data is available to read.
pub fn PtyChild::poll_read(
  self : PtyChild,
  timeout_ms? : Int = 0,
) -> Bool raise PtyError {
  let ret = @ffi.pty_poll_read(self.master_fd, timeout_ms)
  if ret < 0 {
    raise IoError("poll() failed on PTY master")
  }
  ret == 1
}

///|
/// Close the master fd, terminating communication with the child.
pub fn PtyChild::close(self : PtyChild) -> Unit {
  @ffi.pty_close(self.master_fd)
}

///|
/// Get the process ID of the child.
pub fn PtyChild::get_pid(self : PtyChild) -> Int {
  self.pid
}
