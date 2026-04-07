///|
/// FFI exports for the macOS Swift adapter.
///
/// These functions are called by the Swift UI layer via C ABI (dlopen/dlsym).
/// They operate on a global terminal state singleton, serializing data as
/// JSON strings for cross-language transport.
///
/// Following bartleby's pattern:
///   Swift → dlsym("hello_tty_*") → C stub → mangled MoonBit export

///|
/// Global application state.
struct BridgeState {
  mut terminal : @terminal.Terminal?
  mut parser : @vt_parser.Parser?
  mut title : String
  mut rows : Int
  mut cols : Int
  mut initialized : Bool
}

///|
let bridge_state : BridgeState = {
  terminal: None,
  parser: None,
  title: "",
  rows: 24,
  cols: 80,
  initialized: false,
}

///|
/// Result buffer for returning data across FFI boundary.
struct ResultBuf {
  mut result_bytes : Bytes
}

///|
let result_buf : ResultBuf = { result_bytes: Bytes::new(0) }

///|
/// Initialize the terminal state.
/// Returns 0 on success.
pub fn ffi_init(rows_bytes : Bytes, cols_bytes : Bytes) -> Int {
  let rows = bytes_to_int(rows_bytes, 24)
  let cols = bytes_to_int(cols_bytes, 80)
  bridge_state.terminal = Some(@terminal.Terminal::new(rows~, cols~))
  bridge_state.parser = Some(@vt_parser.Parser::new())
  bridge_state.rows = rows
  bridge_state.cols = cols
  bridge_state.title = ""
  bridge_state.initialized = true
  0
}

///|
/// Feed PTY output bytes into the parser and terminal.
/// Returns 0 on success.
pub fn ffi_process_output(data : Bytes) -> Int {
  match (bridge_state.terminal, bridge_state.parser) {
    (Some(terminal), Some(parser)) => {
      let s = bytes_to_string(data)
      let events = parser.feed_str(s)
      terminal.handle_events(events)
      bridge_state.title = terminal.get_title()
      0
    }
    _ => -1
  }
}

///|
/// Handle a key input event.
/// Returns the bytes to send to the PTY (escape sequence), or empty on error.
pub fn ffi_handle_key(key_code_bytes : Bytes, modifiers_bytes : Bytes) -> Bytes {
  match bridge_state.terminal {
    Some(terminal) => {
      let key_code = bytes_to_int(key_code_bytes, 0)
      let modifiers = bytes_to_int(modifiers_bytes, 0)
      let modes = terminal.get_modes()
      let result = @app.translate_key_input(
        key_code,
        modifiers,
        modes.cursor_keys_application,
      )
      result_buf.result_bytes = @utf8.encode(result)
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Resize the terminal. Returns 0 on success.
pub fn ffi_resize(rows_bytes : Bytes, cols_bytes : Bytes) -> Int {
  match bridge_state.terminal {
    Some(terminal) => {
      let rows = bytes_to_int(rows_bytes, 24)
      let cols = bytes_to_int(cols_bytes, 80)
      terminal.resize(rows, cols)
      bridge_state.rows = rows
      bridge_state.cols = cols
      0
    }
    None => -1
  }
}

///|
/// Get the terminal title (set via OSC 0/2).
pub fn ffi_get_title() -> Bytes {
  match bridge_state.terminal {
    Some(terminal) => {
      result_buf.result_bytes = @utf8.encode(terminal.get_title())
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Get the visible terminal grid as a JSON string.
/// Uses the standard Json type with ToJson for correct serialization.
pub fn ffi_get_grid() -> Bytes {
  match bridge_state.terminal {
    Some(terminal) => {
      let grid = terminal.get_grid()
      let cursor = terminal.get_cursor()
      // Build via Map → .to_json() → .stringify()
      let cursor_map : Map[String, Json] = {
        "row": cursor.row.to_json(),
        "col": cursor.col.to_json(),
        "visible": cursor.visible.to_json(),
        "style": (match cursor.style {
            Block => "block"
            Underline => "underline"
            Bar => "bar"
          }).to_json(),
      }
      // Non-empty cells
      let cells_arr : Array[Json] = []
      for row in 0..<grid.rows {
        let line = grid.lines[row]
        for col in 0..<grid.cols {
          let cell = line.get(col)
          if cell.char == '\u0000' {
            continue
          }
          let cell_map : Map[String, Json] = {
            "r": row.to_json(),
            "c": col.to_json(),
            "ch": cell.char.to_string().to_json(),
            "fg": color_to_json(cell.fg),
            "bg": color_to_json(cell.bg),
            "a": cell.attrs.flags.to_json(),
          }
          cells_arr.push(cell_map.to_json())
        }
      }
      let grid_map : Map[String, Json] = {
        "rows": grid.rows.to_json(),
        "cols": grid.cols.to_json(),
        "cursor": cursor_map.to_json(),
        "cells": cells_arr.to_json(),
      }
      result_buf.result_bytes = @utf8.encode(grid_map.to_json().stringify())
      result_buf.result_bytes
    }
    None => @utf8.encode("{}")
  }
}

///|
/// Get the terminal modes as a JSON string.
pub fn ffi_get_modes() -> Bytes {
  match bridge_state.terminal {
    Some(terminal) => {
      let modes = terminal.get_modes()
      let modes_map : Map[String, Json] = {
        "cursor_keys_app": modes.cursor_keys_application.to_json(),
        "reverse_video": modes.reverse_video.to_json(),
        "auto_wrap": modes.auto_wrap.to_json(),
        "cursor_visible": modes.cursor_visible.to_json(),
        "alt_screen": modes.alternate_screen.to_json(),
        "bracketed_paste": modes.bracketed_paste.to_json(),
        "mouse_tracking": modes.mouse_tracking.to_json(),
        "focus_tracking": modes.focus_tracking.to_json(),
      }
      result_buf.result_bytes = @utf8.encode(modes_map.to_json().stringify())
      result_buf.result_bytes
    }
    None => @utf8.encode("{}")
  }
}

///|
/// Get focus event escape sequence (for focus tracking mode).
pub fn ffi_focus_event(gained_bytes : Bytes) -> Bytes {
  match bridge_state.terminal {
    Some(terminal) => {
      let modes = terminal.get_modes()
      if !modes.focus_tracking {
        return Bytes::new(0)
      }
      let gained = bytes_to_int(gained_bytes, 0) != 0
      let seq = if gained { "\u001b[I" } else { "\u001b[O" }
      result_buf.result_bytes = @utf8.encode(seq)
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Shut down the terminal state.
pub fn ffi_shutdown() -> Int {
  bridge_state.terminal = None
  bridge_state.parser = None
  bridge_state.initialized = false
  bridge_state.title = ""
  0
}

// ---------- Helpers ----------

///|
fn bytes_to_string(data : Bytes) -> String {
  @utf8.decode_lossy(data)
}

///|
fn bytes_to_int(data : Bytes, default_ : Int) -> Int {
  let s = bytes_to_string(data)
  let mut result = 0
  let mut has_digit = false
  for c in s {
    let code = c.to_int()
    if code >= 0x30 && code <= 0x39 {
      result = result * 10 + (code - 0x30)
      has_digit = true
    } else {
      break
    }
  }
  if has_digit {
    result
  } else {
    default_
  }
}

///|
fn color_to_json(color : @terminal.Color) -> Json {
  match color {
    Default => [255, 255, 255].to_json()
    Indexed(idx) => [idx].to_json()
    Palette(idx) => [idx].to_json()
    Rgb(r, g, b) => [r.to_int(), g.to_int(), b.to_int()].to_json()
  }
}
