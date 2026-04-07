///|
/// SessionManager — manages multiple terminal sessions.
///
/// This is the MoonBit SoT for tab/session lifecycle. Platform adapters
/// (Swift TabManager, GTK tab bar) delegate creation/destruction here.
///
/// Design considerations for future tmux/screen abstraction:
///   - Each Session is independent (own terminal, parser, title)
///   - SessionManager could be extended with "Window" groupings
///   - Session IDs are stable across the lifetime of the process
///   - Sessions can be detached/reattached without losing state
pub struct SessionManager {
  /// All sessions, keyed by session ID.
  sessions : Map[Int, Session]
  /// Currently active session ID.
  mut active_id : Int
  /// Next session ID to assign (monotonically increasing).
  mut next_id : Int
}

///|
pub fn SessionManager::new() -> SessionManager {
  { sessions: {}, active_id: -1, next_id: 1 }
}

///|
/// Create a new session with the given grid dimensions.
/// Returns the session ID.
pub fn SessionManager::create_session(
  self : SessionManager,
  rows : Int,
  cols : Int,
) -> Int {
  let id = self.next_id
  self.next_id += 1
  let session = Session::new(id, rows, cols)
  self.sessions[id] = session
  // Auto-activate if this is the first session
  if self.active_id < 0 {
    self.active_id = id
  }
  id
}

///|
/// Destroy a session by ID.
/// If the destroyed session was active, switches to the most recent remaining session.
pub fn SessionManager::destroy_session(self : SessionManager, id : Int) -> Unit {
  self.sessions.remove(id) |> ignore
  if self.active_id == id {
    // Switch to the highest-ID remaining session (most recently created)
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
/// Returns true if the session exists and was activated.
pub fn SessionManager::switch_to(self : SessionManager, id : Int) -> Bool {
  if self.sessions.contains(id) {
    self.active_id = id
    true
  } else {
    false
  }
}

///|
/// Get the currently active session, or None if no sessions exist.
pub fn SessionManager::active_session(self : SessionManager) -> Session? {
  self.sessions.get(self.active_id)
}

///|
/// Get the active session ID (-1 if none).
pub fn SessionManager::get_active_id(self : SessionManager) -> Int {
  self.active_id
}

///|
/// Get a session by ID.
pub fn SessionManager::get_session(self : SessionManager, id : Int) -> Session? {
  self.sessions.get(id)
}

///|
/// List all session IDs and titles.
/// Returns an array of (id, title, is_active) tuples.
pub fn SessionManager::list_sessions(
  self : SessionManager,
) -> Array[(Int, String, Bool)] {
  let result : Array[(Int, String, Bool)] = []
  for id, session in self.sessions {
    result.push((id, session.get_title(), id == self.active_id))
  }
  // Sort by ID for stable ordering
  result.sort_by(fn(a, b) { a.0.compare(b.0) })
  result
}

///|
/// Get the number of sessions.
pub fn SessionManager::count(self : SessionManager) -> Int {
  self.sessions.size()
}

///|
/// Destroy all sessions.
pub fn SessionManager::destroy_all(self : SessionManager) -> Unit {
  self.sessions.clear()
  self.active_id = -1
}
