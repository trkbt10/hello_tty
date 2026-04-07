///|
/// A terminal session — owns Terminal + Parser + PTY as an independent unit.
///
/// Each tab in the UI corresponds to one Session. The session owns its own
/// terminal state, parser, title, and PTY file descriptor — fully independent
/// of other sessions.
///
/// PTY I/O threading is a platform responsibility (Swift DispatchQueue,
/// GTK GLib main loop) because MoonBit's GC is not thread-safe. The session
/// exposes the master_fd so the platform adapter can drive the read loop,
/// but session creation, shell path resolution, and PTY spawning are
/// handled here (MoonBit is the SoT).
pub struct Session {
  /// Unique session identifier.
  id : Int
  /// The terminal emulator state (grid, cursor, scrollback).
  terminal : @terminal.Terminal
  /// The VT escape sequence parser.
  parser : @vt_parser.Parser
  /// Window title (set via OSC 0/2).
  mut title : String
  /// Whether this session is alive (PTY connected).
  mut alive : Bool
  /// PTY master file descriptor (-1 if not started).
  mut master_fd : Int
  /// Child process PID (0 if not started).
  mut child_pid : Int
  /// Grid dimensions.
  mut rows : Int
  mut cols : Int
}

///|
pub fn Session::new(id : Int, rows : Int, cols : Int) -> Session {
  {
    id,
    terminal: @terminal.Terminal::new(rows~, cols~),
    parser: @vt_parser.Parser::new(),
    title: "",
    alive: true,
    master_fd: -1,
    child_pid: 0,
    rows,
    cols,
  }
}

///|
pub fn Session::get_id(self : Session) -> Int {
  self.id
}

///|
pub fn Session::get_terminal(self : Session) -> @terminal.Terminal {
  self.terminal
}

///|
pub fn Session::get_title(self : Session) -> String {
  self.title
}

///|
pub fn Session::is_alive(self : Session) -> Bool {
  self.alive
}

///|
pub fn Session::get_master_fd(self : Session) -> Int {
  self.master_fd
}

///|
pub fn Session::get_child_pid(self : Session) -> Int {
  self.child_pid
}

///|
/// Feed raw PTY output into this session's parser and terminal.
pub fn Session::process_output(self : Session, data : String) -> Unit {
  let events = self.parser.feed_str(data)
  self.terminal.handle_events(events)
  self.title = self.terminal.get_title()
}

///|
/// Resize this session's terminal grid.
pub fn Session::resize(self : Session, rows : Int, cols : Int) -> Unit {
  self.terminal.resize(rows, cols)
  self.rows = rows
  self.cols = cols
}

///|
/// Handle a key input event and return the escape sequence to send to PTY.
pub fn Session::handle_key(self : Session, key_code : Int, modifiers : Int) -> String {
  let modes = self.terminal.get_modes()
  @input.translate_key_input(key_code, modifiers, modes.cursor_keys_application)
}

///|
/// Mark this session as dead (PTY disconnected).
pub fn Session::mark_dead(self : Session) -> Unit {
  self.alive = false
}

///|
/// Set the PTY master fd and child PID (called after platform PTY start).
pub fn Session::set_pty(self : Session, master_fd : Int, child_pid : Int) -> Unit {
  self.master_fd = master_fd
  self.child_pid = child_pid
}
