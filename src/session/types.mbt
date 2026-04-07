///|
/// A terminal session — wraps a Terminal + Parser as an independent unit.
///
/// Each tab in the UI corresponds to one Session. The session owns its own
/// terminal state, parser, and title — fully independent of other sessions.
///
/// This design enables:
///   - True multi-tab (each tab is a separate Session)
///   - Future tmux/screen-like multiplexing (a "window" contains sessions)
///   - Session persistence/restore
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
}

///|
pub fn Session::new(id : Int, rows : Int, cols : Int) -> Session {
  {
    id,
    terminal: @terminal.Terminal::new(rows~, cols~),
    parser: @vt_parser.Parser::new(),
    title: "",
    alive: true,
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
