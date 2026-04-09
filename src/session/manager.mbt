///|
/// SessionManager — manages multiple terminal sessions.
///
/// This is the MoonBit SoT for session lifecycle. Tabs and panels are modeled
/// one layer above this in LayoutManager. Platform adapters consume this — they
/// do NOT decide shell paths, grid dimensions, or initialization sequences.
///
/// Session creation is a single atomic operation:
///   create_session() → terminal init + PTY spawn + activate
///
/// The platform adapter receives (session_id, master_fd) and only needs
/// to drive the PTY I/O loop (platform threading concern).
pub struct SessionManager {
  sessions : Map[Int, Session]
  mut active_id : Int
  mut next_id : Int
}

///|
pub fn SessionManager::new() -> SessionManager {
  { sessions: {}, active_id: -1, next_id: 1 }
}

///|
/// Resolve the user's preferred shell.
///
/// Priority:
///   1. $SHELL environment variable
///   2. /bin/zsh (macOS default)
///   3. /bin/sh (POSIX fallback)
fn resolve_shell() -> String {
  match @sys.get_env_var("SHELL") {
    Some(shell) => if shell.length() > 0 { shell } else { "/bin/sh" }
    None => "/bin/sh"
  }
}

///|
/// Create a new session: terminal init + PTY spawn.
///
/// Returns (session_id, master_fd) on success, or (-1, -1) on failure.
/// The platform adapter uses master_fd to drive PTY I/O.
pub fn SessionManager::create_session(
  self : SessionManager,
  rows : Int,
  cols : Int,
) -> (Int, Int) {
  let id = self.next_id
  self.next_id += 1
  let session = Session::new(id, rows, cols)
  // Set TERM before PTY spawn — this is the SoT for terminal type.
  @sys.set_env_var("TERM", "xterm-256color")
  // Resolve shell and start PTY
  let shell = resolve_shell()
  let shell_bytes = @utf8.encode(shell)
  let result_buf : FixedArray[Int] = FixedArray::make(1, 0)
  let pid = @pty_ffi.pty_fork_exec(
    shell_bytes,
    shell_bytes.length(),
    rows,
    cols,
    result_buf,
  )
  if pid >= 0 {
    let master_fd = result_buf[0]
    session.set_pty(master_fd, pid)
  }
  self.sessions[id] = session
  if self.active_id < 0 {
    self.active_id = id
  }
  (id, session.get_master_fd())
}

///|
/// Destroy a session by ID. Closes PTY if open.
pub fn SessionManager::destroy_session(self : SessionManager, id : Int) -> Unit {
  match self.sessions.get(id) {
    Some(session) =>
      if session.get_master_fd() >= 0 {
        @pty_ffi.pty_close(session.get_master_fd())
      }
    None => ()
  }
  self.sessions.remove(id) |> ignore
  if self.active_id == id {
    self.active_id = -1
    for k, _ in self.sessions {
      if k > self.active_id {
        self.active_id = k
      }
    }
  }
}

///|
/// Switch the active session.
pub fn SessionManager::switch_to(self : SessionManager, id : Int) -> Bool {
  if self.sessions.contains(id) {
    self.active_id = id
    true
  } else {
    false
  }
}

///|
pub fn SessionManager::active_session(self : SessionManager) -> Session? {
  self.sessions.get(self.active_id)
}

///|
pub fn SessionManager::get_active_id(self : SessionManager) -> Int {
  self.active_id
}

///|
pub fn SessionManager::get_session(self : SessionManager, id : Int) -> Session? {
  self.sessions.get(id)
}

///|
/// List all sessions: (id, title, is_active).
pub fn SessionManager::list_sessions(
  self : SessionManager,
) -> Array[(Int, String, Bool)] {
  let result : Array[(Int, String, Bool)] = []
  for id, session in self.sessions {
    result.push((id, session.get_title(), id == self.active_id))
  }
  result.sort_by(fn(a, b) { a.0.compare(b.0) })
  result
}

///|
pub fn SessionManager::count(self : SessionManager) -> Int {
  self.sessions.length()
}

///|
/// Destroy all sessions. Closes all PTYs.
pub fn SessionManager::destroy_all(self : SessionManager) -> Unit {
  for _, session in self.sessions {
    if session.get_master_fd() >= 0 {
      @pty_ffi.pty_close(session.get_master_fd())
    }
  }
  self.sessions.clear()
  self.active_id = -1
}
