///|
/// Application configuration.
pub struct AppConfig {
  /// Initial terminal rows.
  rows : Int
  /// Initial terminal columns.
  cols : Int
  /// Shell to execute (e.g. "/bin/bash", "/bin/zsh").
  shell : String
  /// Maximum scrollback lines.
  max_scrollback : Int
  /// Renderer configuration.
  renderer_config : @renderer.RendererConfig
} derive(Show)

///|
pub fn AppConfig::default() -> AppConfig {
  {
    rows: 24,
    cols: 80,
    shell: "/bin/zsh",
    max_scrollback: 10000,
    renderer_config: @renderer.RendererConfig::default(),
  }
}

///|
/// Application error type.
pub suberror AppError {
  IpcError(String)
}

///|
/// Application state.
pub(all) enum AppState {
  /// The application is starting up.
  Starting
  /// The application is running normally.
  Running
  /// The application is shutting down.
  ShuttingDown
  /// The application has stopped.
  Stopped
} derive(Show, Eq)

///|
/// Messages passed between the PTY reader process and the main process via IPC.
/// Serialized as length-prefixed strings over Unix sockets.
pub(all) enum IpcMessage {
  /// PTY output data to be parsed and displayed.
  PtyOutput(String)
  /// Keyboard input from the UI to be sent to the PTY.
  KeyInput(String)
  /// Window resize notification.
  Resize(rows~ : Int, cols~ : Int)
  /// Request to shut down.
  Shutdown
} derive(Show)

///|
/// Serialize an IPC message to a string for transport.
pub fn IpcMessage::serialize(self : IpcMessage) -> String {
  match self {
    PtyOutput(data) => "O:" + data
    KeyInput(data) => "K:" + data
    Resize(rows~, cols~) => "R:" + rows.to_string() + "," + cols.to_string()
    Shutdown => "S:"
  }
}

///|
/// Deserialize an IPC message from a string.
pub fn IpcMessage::deserialize(s : String) -> IpcMessage? {
  if s.char_length() < 2 {
    return None
  }
  let prefix = s[0:2].to_string()
  let data = s[2:].to_string()
  match prefix {
    "O:" => Some(PtyOutput(data))
    "K:" => Some(KeyInput(data))
    "R:" => {
      // Parse "rows,cols"
      let mut comma_pos = -1
      let mut idx = 0
      for c in data {
        if c == ',' {
          comma_pos = idx
          break
        }
        idx += 1
      }
      if comma_pos < 0 {
        None
      } else {
        let rows_str = data[0:comma_pos].to_string()
        let cols_str = data[comma_pos + 1:].to_string()
        // Simple parseInt
        let rows = parse_int(rows_str)
        let cols = parse_int(cols_str)
        match (rows, cols) {
          (Some(r), Some(c)) => Some(Resize(rows=r, cols=c))
          _ => None
        }
      }
    }
    "S:" => Some(Shutdown)
    _ => None
  }
}

///|
/// Simple non-negative integer parser. Returns None on non-digit characters.
pub fn parse_int(s : String) -> Int? {
  let mut result = 0
  let mut has_digit = false
  for c in s {
    let code = c.to_int()
    if code >= 0x30 && code <= 0x39 {
      result = result * 10 + (code - 0x30)
      has_digit = true
    } else {
      return None
    }
  }
  if has_digit {
    Some(result)
  } else {
    None
  }
}
