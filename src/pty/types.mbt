///|
/// Error type for PTY operations.
pub suberror PtyError {
  OpenFailed(String)
  ForkFailed(String)
  IoError(String)
  WinsizeFailed(String)
}

///|
/// Represents a master/slave PTY pair.
/// The master side is held by the terminal emulator for reading/writing.
/// The slave side is attached to the child shell process.
pub struct Pty {
  /// Master file descriptor — the emulator reads/writes here.
  master_fd : Int
  /// Slave file descriptor — the shell process's stdin/stdout/stderr.
  slave_fd : Int
  /// Current terminal dimensions.
  rows : Int
  cols : Int
} derive(Show)

///|
/// Represents a forked child process attached to a PTY.
pub struct PtyChild {
  /// Master fd for communicating with the child.
  master_fd : Int
  /// Process ID of the child.
  pid : Int
  /// Terminal dimensions.
  mut rows : Int
  mut cols : Int
} derive(Show)

///|
/// Window size dimensions.
pub struct WinSize {
  rows : Int
  cols : Int
} derive(Show, Eq)

///|
/// Default read buffer size for PTY reads (4KB).
pub let default_read_buf_size : Int = 4096
