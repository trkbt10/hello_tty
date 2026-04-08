///|
/// FFI exports for platform adapters (macOS Swift, GTK, etc.).
///
/// These functions are called via C ABI (dlopen/dlsym).
/// They operate on a session-based architecture:
///   - SessionManager owns all terminal sessions
///   - Theme is the SoT for color resolution
///   - Colors are fully resolved before crossing FFI boundary
///
/// Following bartleby's pattern:
///   Swift -> dlsym("hello_tty_*") -> C stub -> mangled MoonBit export

///|
/// Global bridge state.
struct BridgeState {
  sessions : @session.SessionManager
  theme : @theme.Theme
  mut renderer : @renderer.Renderer?
  mut gpu_backend : @renderer.GpuBackend?
  mut initialized : Bool
}

///|
let bridge_state : BridgeState = {
  sessions: @session.SessionManager::new(),
  theme: @theme.Theme::midnight(),
  renderer: None,
  gpu_backend: None,
  initialized: false,
}

///|
/// Result buffer for returning data across FFI boundary.
struct ResultBuf {
  mut result_bytes : Bytes
}

///|
let result_buf : ResultBuf = { result_bytes: Bytes::new(0) }

// ========== Session Management ==========

///|
/// Create a new session with terminal init + PTY spawn.
/// Returns session info as JSON: {"id":N,"fd":N}
/// The platform adapter uses fd to drive PTY I/O.
pub fn ffi_create_session(rows_bytes : Bytes, cols_bytes : Bytes) -> Bytes {
  let rows = bytes_to_int(rows_bytes, 24)
  let cols = bytes_to_int(cols_bytes, 80)
  bridge_state.initialized = true
  let (session_id, master_fd) = bridge_state.sessions.create_session(rows, cols)
  let m : Map[String, Json] = {
    "id": session_id.to_json(),
    "fd": master_fd.to_json(),
  }
  result_buf.result_bytes = @utf8.encode(m.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Destroy a session by ID. Returns 0 on success.
pub fn ffi_destroy_session(id_bytes : Bytes) -> Int {
  let id = bytes_to_int(id_bytes, -1)
  bridge_state.sessions.destroy_session(id)
  0
}

///|
/// Switch active session. Returns 0 on success, -1 if session not found.
pub fn ffi_switch_session(id_bytes : Bytes) -> Int {
  let id = bytes_to_int(id_bytes, -1)
  if bridge_state.sessions.switch_to(id) { 0 } else { -1 }
}

///|
/// List all sessions as JSON: [{"id":1,"title":"zsh","active":true}, ...]
pub fn ffi_list_sessions() -> Bytes {
  let sessions = bridge_state.sessions.list_sessions()
  let arr : Array[Json] = []
  for item in sessions {
    let (id, title, active) = item
    let m : Map[String, Json] = {
      "id": id.to_json(),
      "title": title.to_json(),
      "active": active.to_json(),
    }
    arr.push(m.to_json())
  }
  result_buf.result_bytes = @utf8.encode(arr.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Get the active session ID. Returns -1 if no sessions.
pub fn ffi_get_active_session() -> Int {
  bridge_state.sessions.get_active_id()
}

// ========== Legacy single-session API (operates on active session) ==========

///|
/// Initialize the terminal state (legacy — creates a session if none exists).
/// Returns 0 on success.
pub fn ffi_init(rows_bytes : Bytes, cols_bytes : Bytes) -> Int {
  let rows = bytes_to_int(rows_bytes, 24)
  let cols = bytes_to_int(cols_bytes, 80)
  bridge_state.initialized = true
  // Create a session if none exists
  if bridge_state.sessions.count() == 0 {
    let _ = bridge_state.sessions.create_session(rows, cols)

  }
  0
}

///|
/// Feed PTY output bytes into the active session's parser and terminal.
/// Returns 0 on success.
pub fn ffi_process_output(data : Bytes) -> Int {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let s = bytes_to_string(data)
      session.process_output(s)
      0
    }
    _ => -1
  }
}

///|
/// Handle a key input event on the active session.
/// Returns the bytes to send to the PTY (escape sequence), or empty on error.
pub fn ffi_handle_key(key_code_bytes : Bytes, modifiers_bytes : Bytes) -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let key_code = bytes_to_int(key_code_bytes, 0)
      let modifiers = bytes_to_int(modifiers_bytes, 0)
      let result = session.handle_key(key_code, modifiers)
      result_buf.result_bytes = @utf8.encode(result)
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Resize the active session's terminal. Returns 0 on success.
pub fn ffi_resize(rows_bytes : Bytes, cols_bytes : Bytes) -> Int {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let rows = bytes_to_int(rows_bytes, 24)
      let cols = bytes_to_int(cols_bytes, 80)
      session.resize(rows, cols)
      0
    }
    None => -1
  }
}

///|
/// Get the active session's terminal title.
pub fn ffi_get_title() -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      result_buf.result_bytes = @utf8.encode(session.get_title())
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Get cursor position and visibility — lightweight alternative to ffi_get_grid.
/// Returns "row,col,visible,style" (e.g. "5,12,1,block").
/// For GPU renderer path where full grid serialization is unnecessary.
pub fn ffi_get_cursor() -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let cursor = session.get_terminal().get_cursor()
      let sb = StringBuilder::new(size_hint=32)
      sb.write_string(cursor.row.to_string())
      sb.write_char(',')
      sb.write_string(cursor.col.to_string())
      sb.write_char(',')
      sb.write_string(if cursor.visible { "1" } else { "0" })
      sb.write_char(',')
      sb.write_string(
        match cursor.style {
          Block => "block"
          Underline => "underline"
          Bar => "bar"
        },
      )
      result_buf.result_bytes = @utf8.encode(sb.to_string())
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Get the visible terminal grid as a JSON string.
/// Colors are FULLY RESOLVED using the theme — platform adapters receive
/// only concrete RGB values, never palette indices or "default" markers.
///
/// Uses direct StringBuilder to avoid Map/Json/stringify overhead.
/// This function is on the hot path (called every refresh cycle).
pub fn ffi_get_grid() -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let terminal = session.get_terminal()
      let grid = terminal.get_grid()
      let cursor = terminal.get_cursor()
      let theme = bridge_state.theme
      // Pre-size: ~20 bytes per empty cell skip, ~80 bytes per cell with content
      let sb = StringBuilder::new(size_hint=grid.rows * grid.cols * 20)
      sb.write_string("{\"rows\":")
      sb.write_string(grid.rows.to_string())
      sb.write_string(",\"cols\":")
      sb.write_string(grid.cols.to_string())
      sb.write_string(",\"cursor\":{\"row\":")
      sb.write_string(cursor.row.to_string())
      sb.write_string(",\"col\":")
      sb.write_string(cursor.col.to_string())
      sb.write_string(",\"visible\":")
      sb.write_string(if cursor.visible { "true" } else { "false" })
      sb.write_string(",\"style\":\"")
      sb.write_string(
        match cursor.style {
          Block => "block"
          Underline => "underline"
          Bar => "bar"
        },
      )
      sb.write_string("\"},\"cells\":[")
      let mut first = true
      for row in 0..<grid.rows {
        let line = grid.lines[row]
        for col in 0..<grid.cols {
          let cell = line.get(col)
          if cell.char == '\u0000' {
            continue
          }
          if first {
            first = false
          } else {
            sb.write_char(',')
          }
          // Resolve colors using theme (SoT)
          let mut fg_color = cell.fg
          let mut bg_color = cell.bg
          if cell.attrs.has(@terminal.attr_inverse) {
            let tmp = fg_color
            fg_color = bg_color
            bg_color = tmp
          }
          let resolved_fg = theme.resolve_color(fg_color, true)
          let resolved_bg = theme.resolve_color(bg_color, false)
          sb.write_string("{\"r\":")
          sb.write_string(row.to_string())
          sb.write_string(",\"c\":")
          sb.write_string(col.to_string())
          sb.write_string(",\"ch\":")
          write_json_char(sb, cell.char)
          sb.write_string(",\"fg\":[")
          sb.write_string(resolved_fg.r.to_int().to_string())
          sb.write_char(',')
          sb.write_string(resolved_fg.g.to_int().to_string())
          sb.write_char(',')
          sb.write_string(resolved_fg.b.to_int().to_string())
          sb.write_string("],\"bg\":[")
          sb.write_string(resolved_bg.r.to_int().to_string())
          sb.write_char(',')
          sb.write_string(resolved_bg.g.to_int().to_string())
          sb.write_char(',')
          sb.write_string(resolved_bg.b.to_int().to_string())
          sb.write_string("],\"a\":")
          sb.write_string(cell.attrs.flags.to_string())
          sb.write_string(",\"w\":")
          sb.write_string(cell.width.to_string())
          sb.write_char('}')
        }
      }
      sb.write_string("]}")
      result_buf.result_bytes = @utf8.encode(sb.to_string())
      result_buf.result_bytes
    }
    None => @utf8.encode("{}")
  }
}

///|
/// Write a character as a JSON string value (with quotes and escaping).
fn write_json_char(sb : StringBuilder, c : Char) -> Unit {
  let cp = c.to_int()
  sb.write_char('"')
  match cp {
    0x22 => sb.write_string("\\\"") // "
    0x5C => sb.write_string("\\\\") // \
    0x08 => sb.write_string("\\b")
    0x0C => sb.write_string("\\f")
    0x0A => sb.write_string("\\n")
    0x0D => sb.write_string("\\r")
    0x09 => sb.write_string("\\t")
    _ =>
      if cp < 0x20 {
        // Control character: \u00XX
        sb.write_string("\\u00")
        let hi = cp / 16
        let lo = cp % 16
        sb.write_char(hex_digit(hi))
        sb.write_char(hex_digit(lo))
      } else {
        sb.write_char(c)
      }
  }
  sb.write_char('"')
}

///|
fn hex_digit(n : Int) -> Char {
  if n < 10 {
    (0x30 + n).unsafe_to_char()
  } else {
    (0x61 + n - 10).unsafe_to_char()
  }
}

///|
/// Get the terminal modes as a JSON string.
pub fn ffi_get_modes() -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let modes = session.get_terminal().get_modes()
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
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let modes = session.get_terminal().get_modes()
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

// ========== GPU Rendering ==========

///|
/// Initialize the GPU rendering backend.
pub fn ffi_gpu_init(
  surface_bytes : Bytes,
  width_bytes : Bytes,
  height_bytes : Bytes,
) -> Int {
  let surface_handle = bytes_to_int(surface_bytes, 0)
  let width = bytes_to_int(width_bytes, 0)
  let height = bytes_to_int(height_bytes, 0)
  let theme = bridge_state.theme
  let font_config : @font.FontConfig = { font_name: "Menlo", font_size: 26, atlas_size: 1024 }
  let font_engine = @font.FontEngine::new(config=font_config)
  let render_config : @renderer.RendererConfig = {
    cell_width: 8,
    cell_height: 16,
    font_size: 26,
    dpi_scale: 2.0,
    atlas_size: 1024,
    default_fg: renderer_color(theme.fg),
    default_bg: renderer_color(theme.bg),
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
pub fn ffi_render_frame() -> Int {
  match (bridge_state.sessions.active_session(), bridge_state.renderer, bridge_state.gpu_backend) {
    (Some(session), Some(renderer), Some(gpu)) => {
      let commands = renderer.render(session.get_terminal())
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

// ========== Input Classification ==========

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

// ========== Theme ==========

///|
/// Get theme info as JSON (for platform adapter configuration).
/// Includes is_dark, bg_alpha, and key colors as RGB arrays.
pub fn ffi_get_theme() -> Bytes {
  let theme = bridge_state.theme
  let theme_map : Map[String, Json] = {
    "name": theme.name.to_json(),
    "is_dark": theme.is_dark().to_json(),
    "bg_alpha": theme.bg_alpha.to_double().to_json(),
    "fg": rgba_to_json(theme.fg),
    "bg": rgba_to_json(theme.bg),
    "cursor": rgba_to_json(theme.cursor),
    "selection": rgba_to_json(theme.selection),
  }
  result_buf.result_bytes = @utf8.encode(theme_map.to_json().stringify())
  result_buf.result_bytes
}

// ========== Shutdown ==========

///|
/// Shut down all sessions and resources.
pub fn ffi_shutdown() -> Int {
  if bridge_state.gpu_backend is Some(gpu) {
    gpu.shutdown()
  }
  bridge_state.gpu_backend = None
  bridge_state.renderer = None
  bridge_state.sessions.destroy_all()
  bridge_state.initialized = false
  0
}

// ========== Helpers ==========

///|
fn bytes_to_string(data : Bytes) -> String {
  @utf8.decode_lossy(data)
}

///|
fn bytes_to_int(data : Bytes, default_ : Int) -> Int {
  let s = bytes_to_string(data)
  let mut result = 0
  let mut has_digit = false
  let mut negative = false
  let mut first = true
  for c in s {
    let code = c.to_int()
    if first && code == 0x2D {
      // '-'
      negative = true
      first = false
      continue
    }
    first = false
    if code >= 0x30 && code <= 0x39 {
      result = result * 10 + (code - 0x30)
      has_digit = true
    } else {
      break
    }
  }
  if has_digit {
    if negative { -result } else { result }
  } else {
    default_
  }
}

///|
/// Encode a theme RgbaColor to JSON as [r, g, b] (0-255).
fn rgba_to_json(color : @theme.RgbaColor) -> Json {
  [color.r.to_int(), color.g.to_int(), color.b.to_int()].to_json()
}

///|
/// Convert theme RgbaColor to renderer RgbaColor.
fn renderer_color(c : @theme.RgbaColor) -> @renderer.RgbaColor {
  @renderer.RgbaColor::opaque(c.r, c.g, c.b)
}
