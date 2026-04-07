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
  mut renderer : @renderer.Renderer?
  mut gpu_backend : @renderer.GpuBackend?
  mut title : String
  mut rows : Int
  mut cols : Int
  mut initialized : Bool
}

///|
let bridge_state : BridgeState = {
  terminal: None,
  parser: None,
  renderer: None,
  gpu_backend: None,
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
      let result = @input.translate_key_input(
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
            "fg": color_to_json_fg(cell.fg),
            "bg": color_to_json_bg(cell.bg),
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
/// Initialize the GPU rendering backend.
/// surface_handle_lo/hi: CAMetalLayer* split into two 32-bit halves.
/// width, height: framebuffer pixel dimensions.
/// Returns 0 on success.
pub fn ffi_gpu_init(
  surface_bytes : Bytes,
  width_bytes : Bytes,
  height_bytes : Bytes
) -> Int {
  let surface_handle = bytes_to_int(surface_bytes, 0)
  let width = bytes_to_int(width_bytes, 0)
  let height = bytes_to_int(height_bytes, 0)
  // Configure renderer with terminal-appropriate defaults:
  // - Dark background (matching midnight theme)
  // - Light foreground
  // - DPI scale from pixel width / approximate point width
  let font_config : @font.FontConfig = { font_size: 26, atlas_size: 1024 }
  let font_engine = @font.FontEngine::new(config=font_config)
  let render_config : @renderer.RendererConfig = {
    cell_width: 8,
    cell_height: 16,
    font_size: 26,
    dpi_scale: 2.0,
    atlas_size: 1024,
    default_fg: @renderer.RgbaColor::opaque(b'\xE6', b'\xE6', b'\xE6'),
    default_bg: @renderer.RgbaColor::opaque(b'\x14', b'\x14', b'\x1A'),
  }
  let renderer = @renderer.Renderer::new(config=render_config)
  let gpu = @renderer.GpuBackend::new(config=render_config, font=font_engine)
  try {
    gpu.init!(surface_handle, width, height)
    bridge_state.renderer = Some(renderer)
    bridge_state.gpu_backend = Some(gpu)
    0
  } catch {
    _ => -1
  }
}

///|
/// Render the current terminal state to the GPU.
/// This is the single call Swift needs for drawing — all rendering logic
/// (glyph atlas, vertex generation, color resolution) runs in MoonBit.
/// Returns 0 on success.
pub fn ffi_render_frame() -> Int {
  match (bridge_state.terminal, bridge_state.renderer, bridge_state.gpu_backend) {
    (Some(terminal), Some(renderer), Some(gpu)) => {
      let commands = renderer.render(terminal)
      try {
        gpu.execute_frame!(commands)
        0
      } catch {
        _ => -1
      }
    }
    _ => -1
  }
}

///|
/// Resize the GPU surface.
/// Returns 0 on success.
pub fn ffi_gpu_resize(width_bytes : Bytes, height_bytes : Bytes) -> Int {
  let width = bytes_to_int(width_bytes, 0)
  let height = bytes_to_int(height_bytes, 0)
  match bridge_state.gpu_backend {
    Some(gpu) =>
      try {
        gpu.resize!(width, height)
        0
      } catch {
        _ => -1
      }
    None => -1
  }
}

///|
/// Shut down the terminal state.
pub fn ffi_shutdown() -> Int {
  if bridge_state.gpu_backend is Some(gpu) {
    gpu.shutdown()
  }
  bridge_state.gpu_backend = None
  bridge_state.renderer = None
  bridge_state.terminal = None
  bridge_state.parser = None
  bridge_state.initialized = false
  bridge_state.title = ""
  0
}

///|
/// Classify a key event — SoT for input routing decisions.
/// Returns: 0=DirectToPty, 1=ForwardToIme, 2=ClipboardCopy, 3=ClipboardPaste
pub fn ffi_classify_key(
  key_code_bytes : Bytes,
  modifiers_bytes : Bytes,
  has_marked_bytes : Bytes,
) -> Int {
  let key_code = bytes_to_int(key_code_bytes, 0)
  let modifiers = bytes_to_int(modifiers_bytes, 0)
  let has_marked = bytes_to_int(has_marked_bytes, 0) != 0
  match @input.classify_key(key_code, modifiers, has_marked) {
    DirectToPty => 0
    ForwardToIme => 1
    ClipboardCopy => 2
    ClipboardPaste => 3
  }
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
/// Encode foreground color to JSON.
/// Default fg → null (let the UI theme decide).
fn color_to_json_fg(color : @terminal.Color) -> Json {
  match color {
    Default => Json::null()
    Indexed(idx) => [idx].to_json()
    Palette(idx) => [idx].to_json()
    Rgb(r, g, b) => [r.to_int(), g.to_int(), b.to_int()].to_json()
  }
}

///|
/// Encode background color to JSON.
/// Default bg → null (let the UI theme decide).
fn color_to_json_bg(color : @terminal.Color) -> Json {
  match color {
    Default => Json::null()
    Indexed(idx) => [idx].to_json()
    Palette(idx) => [idx].to_json()
    Rgb(r, g, b) => [r.to_int(), g.to_int(), b.to_int()].to_json()
  }
}
