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
priv struct BridgeState {
  sessions : @session.SessionManager
  layout : @layout.LayoutManager
  theme : @theme.Theme
  mut renderer : @renderer.Renderer?
  mut gpu_backend : @renderer.GpuBackend?
  /// Mapping from session_id to GPU surface_id.
  /// Each panel's TerminalGPUView creates its own surface; this map
  /// connects sessions to their rendering surface.
  surface_map : Map[Int, Int]
}

///|
let bridge_state : BridgeState = {
  let sessions = @session.SessionManager::new()
  {
    sessions,
    layout: @layout.LayoutManager::new(sessions),
    theme: @theme.Theme::midnight(),
    renderer: None,
    gpu_backend: None,
    surface_map: {},
  }
}

///|
/// Result buffer for returning data across FFI boundary.
priv struct ResultBuf {
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
  if bridge_state.sessions.switch_to(id) {
    0
  } else {
    -1
  }
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
  // Create a session if none exists
  if bridge_state.sessions.count() == 0 {
    let _ = bridge_state.sessions.create_session(rows, cols)
  }
  0
}

///|
/// Feed PTY output bytes into the active session's parser and terminal.
/// Returns reply data to write back to the PTY (DSR/DA responses), or empty bytes.
pub fn ffi_process_output(data : Bytes) -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let s = bytes_to_string(data)
      let reply = session.process_output(s)
      result_buf.result_bytes = @utf8.encode(reply)
      result_buf.result_bytes
    }
    _ => Bytes::new(0)
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
/// Get the shell input region (OSC 133 semantic prompt).
///
/// Returns "start_row,start_col,end_row,end_col" when the user is typing
/// a command (CommandInput state), or empty bytes when not in input mode.
///
/// The coordinates are grid-relative (0-indexed), matching the coordinate
/// system used by ffi_get_cursor and pixelToGrid.
pub fn ffi_get_input_region() -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => {
      let terminal = session.get_terminal()
      match terminal.get_input_region() {
        Some((sr, sc, er, ec)) => {
          let sb = StringBuilder::new(size_hint=32)
          sb.write_string(sr.to_string())
          sb.write_char(',')
          sb.write_string(sc.to_string())
          sb.write_char(',')
          sb.write_string(er.to_string())
          sb.write_char(',')
          sb.write_string(ec.to_string())
          result_buf.result_bytes = @utf8.encode(sb.to_string())
          result_buf.result_bytes
        }
        None => Bytes::new(0)
      }
    }
    None => Bytes::new(0)
  }
}

///|
/// Get the shell input region for a specific session.
pub fn ffi_get_input_region_for(session_id_bytes : Bytes) -> Bytes {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      let terminal = session.get_terminal()
      match terminal.get_input_region() {
        Some((sr, sc, er, ec)) => {
          let sb = StringBuilder::new(size_hint=32)
          sb.write_string(sr.to_string())
          sb.write_char(',')
          sb.write_string(sc.to_string())
          sb.write_char(',')
          sb.write_string(er.to_string())
          sb.write_char(',')
          sb.write_string(ec.to_string())
          result_buf.result_bytes = @utf8.encode(sb.to_string())
          result_buf.result_bytes
        }
        None => Bytes::new(0)
      }
    }
    None => Bytes::new(0)
  }
}

///|
/// Test whether a grid cell is within the shell input region.
///
/// Returns 1 if the cell (row, col) is in the input region, 0 otherwise.
/// Respects the shell_integration feature flag.
pub fn ffi_is_in_input_region(
  session_id_bytes : Bytes,
  row_bytes : Bytes,
  col_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let row = bytes_to_int(row_bytes, -1)
  let col = bytes_to_int(col_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) =>
      if session.get_terminal().is_in_input_region(row, col) {
        1
      } else {
        0
      }
    None => 0
  }
}

///|
/// Generate arrow key sequences to move the shell cursor to (row, col).
///
/// Returns the escape sequence string to write to the PTY, or empty bytes
/// if the target is not in the input region.
pub fn ffi_cursor_move_sequence(
  session_id_bytes : Bytes,
  row_bytes : Bytes,
  col_bytes : Bytes,
) -> Bytes {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let row = bytes_to_int(row_bytes, -1)
  let col = bytes_to_int(col_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      let seq = session.get_terminal().cursor_move_sequence(row, col)
      if seq.length() == 0 {
        Bytes::new(0)
      } else {
        result_buf.result_bytes = @utf8.encode(seq)
        result_buf.result_bytes
      }
    }
    None => Bytes::new(0)
  }
}

///|
/// Set a terminal feature flag.
///
/// name: feature name (e.g., "shell_integration")
/// enabled: "1" to enable, "0" to disable
pub fn ffi_set_feature(
  session_id_bytes : Bytes,
  name_bytes : Bytes,
  enabled_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let name = bytes_to_string(name_bytes)
  let enabled = bytes_to_int(enabled_bytes, 0) != 0
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      session.get_terminal().set_feature(name, enabled)
      0
    }
    None => -1
  }
}

///|
/// Get the visible terminal grid as a JSON string.
/// Colors are FULLY RESOLVED using the theme — platform adapters receive
/// only concrete RGB values, never palette indices or "default" markers.
///
/// Supports differential updates: only cells within the dirty bounding box
/// are serialized. The response includes "dirty" rect so the receiver knows
/// which region was updated. "dirty":"all" means full grid.
///
/// After serialization, the dirty region is reset.
pub fn ffi_get_grid() -> Bytes {
  match bridge_state.sessions.active_session() {
    Some(session) => serialize_session_grid(session)
    None => @utf8.encode("{}")
  }
}

///|
/// Shared grid serialization logic — used by both ffi_get_grid and ffi_get_grid_for.
fn serialize_session_grid(session : @session.Session) -> Bytes {
  let terminal = session.get_terminal()
  let grid = terminal.get_grid()
  let cursor = terminal.get_cursor()
  let theme = bridge_state.theme
  let viewport_offset = terminal.get_viewport_offset()
  // Determine dirty region.
  // When viewport is scrolled (offset > 0), we always return the full grid
  // because dirty tracking only covers live grid writes, not viewport changes.
  let (dr_top, dr_left, dr_bottom, dr_right, is_full) = if viewport_offset > 0 {
    (0, 0, grid.rows - 1, grid.cols - 1, true)
  } else {
    match grid.get_dirty_rect() {
      Some((t, l, b, r)) => {
        let full = grid.dirty_all
        (t, l, b, r, full)
      }
      None => {
        let sb = StringBuilder::new(size_hint=128)
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
        sb.write_string("\"},\"dirty\":\"none\",\"cells\":[]}")
        result_buf.result_bytes = @utf8.encode(sb.to_string())
        return result_buf.result_bytes
      }
    }
  }
  let cells_in_rect = (dr_bottom - dr_top + 1) * (dr_right - dr_left + 1)
  let sb = StringBuilder::new(size_hint=cells_in_rect * 80 + 200)
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
  // Dirty region info
  if is_full {
    sb.write_string("\"},\"dirty\":\"all\"")
  } else {
    sb.write_string("\"},\"dirty\":[")
    sb.write_string(dr_top.to_string())
    sb.write_char(',')
    sb.write_string(dr_left.to_string())
    sb.write_char(',')
    sb.write_string(dr_bottom.to_string())
    sb.write_char(',')
    sb.write_string(dr_right.to_string())
    sb.write_char(']')
  }
  sb.write_string(",\"viewport_offset\":")
  sb.write_string(terminal.get_viewport_offset().to_string())
  sb.write_string(",\"cells\":[")
  let mut first = true
  for row in dr_top..<=dr_bottom {
    let line = match terminal.get_viewport_row(row) {
      Some(r) => r
      None => continue
    }
    for col in dr_left..<=dr_right {
      let cell = line.get(col)
      if cell.char == '\u0000' {
        continue
      }
      if first {
        first = false
      } else {
        sb.write_char(',')
      }
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
  // Reset dirty state after serialization
  grid.mark_all_clean()
  result_buf.result_bytes = @utf8.encode(sb.to_string())
  result_buf.result_bytes
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

// ========== GPU Rendering (Multi-Surface) ==========

///|
/// Ensure the shared GPU renderer and backend are initialized.
/// Called automatically when the first surface is created.
fn ensure_gpu_initialized() -> Unit {
  if bridge_state.renderer is Some(_) {
    return
  }
  let theme = bridge_state.theme
  let font_config : @font.FontConfig = {
    font_name: "Menlo",
    font_size: 26,
    atlas_size: 1024,
  }
  let font_engine = @font.FontEngine::new(config=font_config)
  // Create gpu backend first (it will init font engine in init_device)
  let gpu = @renderer.GpuBackend::new(
    config=@renderer.RendererConfig::default(),
    font=font_engine,
  )
  // init_device initializes the font engine via CoreText, giving us
  // accurate cell metrics from the actual rasterizer.
  gpu.init_device() catch {
    _ => ()
  }
  let (cw, ch) = gpu.get_cell_size()
  // Use the real metrics from the font engine (not hardcoded values)
  let cell_width = if cw > 0 { cw } else { 8 }
  let cell_height = if ch > 0 { ch } else { 16 }
  let render_config : @renderer.RendererConfig = {
    cell_width,
    cell_height,
    font_size: 26,
    dpi_scale: 2.0,
    atlas_size: 1024,
    default_fg: renderer_color(theme.fg),
    default_bg: renderer_bg_color(theme.bg, theme.bg_alpha),
  }
  bridge_state.renderer = Some(@renderer.Renderer::new(config=render_config))
  bridge_state.gpu_backend = Some(gpu)
}

///|
/// Get cell metrics from the GPU font engine.
/// Returns JSON: {"cell_width":N, "cell_height":N, "dpi_scale":F, "font_size":N}
/// Swift uses this for rendering alignment. cell_width/cell_height are in pixels.
pub fn ffi_get_cell_metrics() -> Bytes {
  ensure_gpu_initialized()
  let (cw, ch) = match bridge_state.gpu_backend {
    Some(gpu) => gpu.get_cell_size()
    None => (8, 16)
  }
  let (dpi, font_size) = match bridge_state.renderer {
    Some(r) => {
      let cfg = r.get_config()
      (cfg.dpi_scale, cfg.font_size)
    }
    None => ((2.0 : Float), 14)
  }
  let m : Map[String, Json] = {
    "cell_width": cw.to_json(),
    "cell_height": ch.to_json(),
    "dpi_scale": dpi.to_double().to_json(),
    "font_size": font_size.to_json(),
  }
  result_buf.result_bytes = @utf8.encode(m.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Convert pixel coordinates to grid cell coordinates.
/// Used by platform adapters for mouse hit-testing without needing
/// to know cell metrics directly.
///
/// Args: x_px, y_px (pixel coordinates within the terminal view),
///       view_height_px (total view height for y-axis inversion).
/// Returns: "row,col" as a string.
pub fn ffi_pixel_to_grid(
  x_px_bytes : Bytes,
  y_px_bytes : Bytes,
  view_height_px_bytes : Bytes,
) -> Bytes {
  let x_px = bytes_to_int(x_px_bytes, 0)
  let y_px = bytes_to_int(y_px_bytes, 0)
  let view_height = bytes_to_int(view_height_px_bytes, 0)
  let (cell_w, cell_h) = get_cell_size_logical_f()
  let col = Int::max((Float::from_int(x_px) / cell_w).to_int(), 0)
  // y_px is from bottom (macOS coordinate system), row 0 is at top
  let row = Int::max((Float::from_int(view_height - y_px) / cell_h).to_int(), 0)
  let s = row.to_string() + "," + col.to_string()
  result_buf.result_bytes = @utf8.encode(s)
  result_buf.result_bytes
}

///|
/// Register an already-created GPU surface with a session.
/// The C-level surface was created by Swift calling hello_tty_gpu_surface_create
/// directly (because the surface_handle is a 64-bit pointer that doesn't fit
/// in MoonBit's 32-bit Int).
///
/// surface_id: the ID returned by the C-level surface creation.
/// session_id: which session this surface belongs to.
///
/// Also ensures the GPU device/font/atlas are initialized.
pub fn ffi_gpu_register_surface(
  session_id_bytes : Bytes,
  surface_id_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let surface_id = bytes_to_int(surface_id_bytes, -1)
  ensure_gpu_initialized()
  // Ensure device is initialized
  match bridge_state.gpu_backend {
    Some(gpu) => gpu.init_device() catch { _ => return -1 }
    None => return -1
  }
  if session_id >= 0 && surface_id >= 0 {
    bridge_state.surface_map[session_id] = surface_id
  }
  0
}

///|
/// Destroy a GPU surface for a session.
pub fn ffi_gpu_surface_destroy(session_id_bytes : Bytes) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match (bridge_state.surface_map.get(session_id), bridge_state.gpu_backend) {
    (Some(sid), Some(gpu)) => {
      gpu.destroy_surface(sid)
      bridge_state.surface_map.remove(session_id) |> ignore
      0
    }
    _ => -1
  }
}

///|
/// Resize a session's GPU surface.
pub fn ffi_gpu_surface_resize(
  session_id_bytes : Bytes,
  width_bytes : Bytes,
  height_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let width = bytes_to_int(width_bytes, 0)
  let height = bytes_to_int(height_bytes, 0)
  match (bridge_state.surface_map.get(session_id), bridge_state.gpu_backend) {
    (Some(sid), Some(gpu)) =>
      try {
        gpu.resize_surface(sid, width, height)
        0
      } catch {
        _ => -1
      }
    _ => -1
  }
}

///|
/// Legacy: Initialize GPU with a single surface (backward compatibility).
pub fn ffi_gpu_init(
  surface_bytes : Bytes,
  width_bytes : Bytes,
  height_bytes : Bytes,
) -> Int {
  let surface_handle = bytes_to_int(surface_bytes, 0)
  let width = bytes_to_int(width_bytes, 0)
  let height = bytes_to_int(height_bytes, 0)
  ensure_gpu_initialized()
  match bridge_state.gpu_backend {
    Some(gpu) =>
      try {
        gpu.init(surface_handle, width, height)
        0
      } catch {
        _ => -1
      }
    None => -1
  }
}

///|
/// Render the current terminal state to the GPU (active session, legacy surface).
pub fn ffi_render_frame() -> Int {
  match
    (
      bridge_state.sessions.active_session(),
      bridge_state.renderer,
      bridge_state.gpu_backend,
    ) {
    (Some(session), Some(renderer), Some(gpu)) => {
      let commands = renderer.render(session.get_terminal())
      try {
        gpu.execute_frame(commands)
        0
      } catch {
        _ => -1
      }
    }
    _ => -1
  }
}

///|
/// Render a specific session's terminal state to the GPU on its own surface.
pub fn ffi_render_frame_for(session_id_bytes : Bytes) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let surface_id = match bridge_state.surface_map.get(session_id) {
    Some(sid) => sid
    None => return -1
  }
  match
    (
      bridge_state.sessions.get_session(session_id),
      bridge_state.renderer,
      bridge_state.gpu_backend,
    ) {
    (Some(session), Some(renderer), Some(gpu)) => {
      let terminal = session.get_terminal()
      let commands = renderer.render(terminal)
      try {
        gpu.execute_frame_on(surface_id, commands)
        0
      } catch {
        _ => -1
      }
    }
    _ => -1
  }
}

///|
/// Legacy: Resize the GPU surface.
pub fn ffi_gpu_resize(width_bytes : Bytes, height_bytes : Bytes) -> Int {
  let width = bytes_to_int(width_bytes, 0)
  let height = bytes_to_int(height_bytes, 0)
  match bridge_state.gpu_backend {
    Some(gpu) =>
      try {
        gpu.resize(width, height)
        0
      } catch {
        _ => -1
      }
    None => -1
  }
}

// ========== Tab & Panel Management (Layout-aware) ==========

///|
/// Create a new tab with a single panel.
/// Returns JSON: {"tab_id":N, "panel_id":N, "session_id":N, "fd":N}
pub fn ffi_create_tab(rows_bytes : Bytes, cols_bytes : Bytes) -> Bytes {
  let rows = bytes_to_int(rows_bytes, 24)
  let cols = bytes_to_int(cols_bytes, 80)
  let (tab_id, panel_id, master_fd) = bridge_state.layout.create_tab(rows, cols)
  // Get the session_id from the panel
  let session_id = match bridge_state.layout.focused_panel() {
    Some(info) => info.session_id
    None => -1
  }
  let m : Map[String, Json] = {
    "tab_id": tab_id.to_json(),
    "panel_id": panel_id.to_json(),
    "session_id": session_id.to_json(),
    "fd": master_fd.to_json(),
  }
  result_buf.result_bytes = @utf8.encode(m.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Close a tab and all its panels/sessions.
pub fn ffi_close_tab(tab_id_bytes : Bytes) -> Int {
  let tab_id = bytes_to_int(tab_id_bytes, -1)
  bridge_state.layout.close_tab(tab_id)
  0
}

///|
/// Switch to a tab by ID.
pub fn ffi_switch_tab(tab_id_bytes : Bytes) -> Int {
  let tab_id = bytes_to_int(tab_id_bytes, -1)
  if bridge_state.layout.switch_tab(tab_id) {
    0
  } else {
    -1
  }
}

///|
/// Switch to the next tab. Returns 0 on success.
pub fn ffi_next_tab() -> Int {
  if bridge_state.layout.next_tab() {
    0
  } else {
    -1
  }
}

///|
/// Switch to the previous tab. Returns 0 on success.
pub fn ffi_prev_tab() -> Int {
  if bridge_state.layout.prev_tab() {
    0
  } else {
    -1
  }
}

///|
/// List all tabs as JSON: [{"id":N, "title":"...", "active":true}, ...]
pub fn ffi_list_tabs() -> Bytes {
  let tabs = bridge_state.layout.list_tabs()
  let arr : Array[Json] = []
  for item in tabs {
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
/// Reorder a tab within the tab strip.
pub fn ffi_reorder_tab(tab_id_bytes : Bytes, target_index_bytes : Bytes) -> Int {
  let tab_id = bytes_to_int(tab_id_bytes, -1)
  let target_index = bytes_to_int(target_index_bytes, 0)
  if bridge_state.layout.reorder_tab(tab_id, target_index) {
    0
  } else {
    -1
  }
}

///|
/// Activate a workspace/window by ID.
pub fn ffi_activate_workspace(workspace_id_bytes : Bytes) -> Int {
  let workspace_id = bytes_to_int(workspace_id_bytes, -1)
  if bridge_state.layout.activate_workspace(workspace_id) {
    0
  } else {
    -1
  }
}

///|
/// Detach a tab into a newly created workspace.
/// Returns the new workspace id, or -1 on failure.
pub fn ffi_detach_tab_to_new_workspace(tab_id_bytes : Bytes) -> Int {
  let tab_id = bytes_to_int(tab_id_bytes, -1)
  bridge_state.layout.detach_tab_to_new_workspace(tab_id)
}

///|
/// Attach a tab into a target workspace at the requested index.
pub fn ffi_attach_tab_to_workspace(
  tab_id_bytes : Bytes,
  workspace_id_bytes : Bytes,
  target_index_bytes : Bytes,
) -> Int {
  let tab_id = bytes_to_int(tab_id_bytes, -1)
  let workspace_id = bytes_to_int(workspace_id_bytes, -1)
  let target_index = bytes_to_int(target_index_bytes, 0)
  if bridge_state.layout.attach_tab_to_workspace(
      tab_id, workspace_id, target_index,
    ) {
    0
  } else {
    -1
  }
}

///|
/// Merge a tab into the active tab by splitting the target panel.
pub fn ffi_merge_tab_into_panel(
  tab_id_bytes : Bytes,
  target_panel_id_bytes : Bytes,
  direction_bytes : Bytes,
) -> Int {
  let tab_id = bytes_to_int(tab_id_bytes, -1)
  let target_panel_id = bytes_to_int(target_panel_id_bytes, -1)
  let dir_int = bytes_to_int(direction_bytes, 0)
  let direction : @layout.SplitDirection = if dir_int == 1 {
    Horizontal
  } else {
    Vertical
  }
  if bridge_state.layout.merge_tab_into_panel(
      tab_id, target_panel_id, direction,
    ) {
    0
  } else {
    -1
  }
}

///|
/// Return all workspaces/windows and their ordered tabs as JSON.
pub fn ffi_get_workspace_snapshot() -> Bytes {
  let snapshots = bridge_state.layout.list_workspaces()
  let workspaces : Array[Json] = []
  for workspace in snapshots {
    let tabs : Array[Json] = []
    for tab in workspace.tabs {
      let tab_json : Map[String, Json] = {
        "tab_id": tab.tab_id.to_json(),
        "title": tab.title.to_json(),
        "active": tab.active.to_json(),
        "panel_count": tab.panel_count.to_json(),
        "focused_panel_id": tab.focused_panel_id.to_json(),
      }
      tabs.push(tab_json.to_json())
    }
    let workspace_json : Map[String, Json] = {
      "workspace_id": workspace.workspace_id.to_json(),
      "active": workspace.active.to_json(),
      "active_tab_id": workspace.active_tab_id.to_json(),
      "tabs": tabs.to_json(),
    }
    workspaces.push(workspace_json.to_json())
  }
  let root : Map[String, Json] = {
    "active_workspace_id": bridge_state.layout
    .get_active_workspace_id()
    .to_json(),
    "workspaces": workspaces.to_json(),
  }
  result_buf.result_bytes = @utf8.encode(root.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Split the specified panel in the given direction.
/// direction: 0=Vertical (left/right), 1=Horizontal (top/bottom)
/// Returns JSON: {"panel_id":N, "session_id":N, "fd":N, "existing_rows":N, "existing_cols":N}
/// Returns empty bytes on failure (panel too small to split).
pub fn ffi_split_panel(
  panel_id_bytes : Bytes,
  direction_bytes : Bytes,
) -> Bytes {
  let panel_id = bytes_to_int(panel_id_bytes, -1)
  let dir_int = bytes_to_int(direction_bytes, 0)
  let direction : @layout.SplitDirection = if dir_int == 1 {
    Horizontal
  } else {
    Vertical
  }
  match bridge_state.layout.split_panel(panel_id, direction) {
    Some(result) => {
      let m : Map[String, Json] = {
        "panel_id": result.new_panel_id.to_json(),
        "session_id": result.new_session_id.to_json(),
        "fd": result.master_fd.to_json(),
        "existing_rows": result.existing_rows.to_json(),
        "existing_cols": result.existing_cols.to_json(),
      }
      result_buf.result_bytes = @utf8.encode(m.to_json().stringify())
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Close a panel. Returns the session_id of the new focused panel,
/// or -1 if the tab was closed.
pub fn ffi_close_panel(panel_id_bytes : Bytes) -> Int {
  let panel_id = bytes_to_int(panel_id_bytes, -1)
  bridge_state.layout.close_panel(panel_id)
}

///|
/// Focus a panel by ID. Returns 0 on success.
pub fn ffi_focus_panel(panel_id_bytes : Bytes) -> Int {
  let panel_id = bytes_to_int(panel_id_bytes, -1)
  if bridge_state.layout.focus_panel(panel_id) {
    0
  } else {
    -1
  }
}

///|
/// Focus panel by DFS index (0-based). Returns 0 on success.
pub fn ffi_focus_panel_by_index(index_bytes : Bytes) -> Int {
  let index = bytes_to_int(index_bytes, -1)
  if bridge_state.layout.focus_panel_by_index(index) {
    0
  } else {
    -1
  }
}

///|
/// Focus the neighboring panel in a direction.
/// direction: 0=Up, 1=Down, 2=Left, 3=Right
pub fn ffi_focus_direction(direction_bytes : Bytes) -> Int {
  let dir_int = bytes_to_int(direction_bytes, -1)
  let direction : @layout.FocusDirection = match dir_int {
    0 => Up
    1 => Down
    2 => Left
    3 => Right
    _ => return -1
  }
  if bridge_state.layout.focus_direction(direction) {
    0
  } else {
    -1
  }
}

///|
/// Get the layout tree of the active tab as JSON.
/// Returns a recursive tree structure:
///   Leaf: {"type":"leaf", "panel_id":N, "session_id":N, "rows":N, "cols":N}
///   Split: {"type":"split", "direction":"vertical"|"horizontal",
///           "ratio":0.5, "first":{...}, "second":{...}}
pub fn ffi_get_layout() -> Bytes {
  match bridge_state.layout.get_active_layout() {
    Some(node) => {
      let json = layout_node_to_json(node)
      result_buf.result_bytes = @utf8.encode(json.stringify())
      result_buf.result_bytes
    }
    None => @utf8.encode("{}")
  }
}

///|
fn layout_node_to_json(node : @layout.LayoutNode) -> Json {
  match node {
    Leaf(info) => {
      let m : Map[String, Json] = {
        "type": "leaf".to_json(),
        "panel_id": info.panel_id.to_json(),
        "session_id": info.session_id.to_json(),
        "rows": info.rows.to_json(),
        "cols": info.cols.to_json(),
      }
      m.to_json()
    }
    Split(dir, first, second, ratio) => {
      let dir_str = match dir {
        Vertical => "vertical"
        Horizontal => "horizontal"
      }
      let m : Map[String, Json] = {
        "type": "split".to_json(),
        "direction": dir_str.to_json(),
        "ratio": ratio.to_double().to_json(),
        "first": layout_node_to_json(first),
        "second": layout_node_to_json(second),
      }
      m.to_json()
    }
  }
}

///|
/// Get all panels in the active tab as JSON.
/// Returns: [{"panel_id":N, "session_id":N, "rows":N, "cols":N, "focused":bool}, ...]
pub fn ffi_get_all_panels() -> Bytes {
  let panels = bridge_state.layout.get_all_panels()
  let arr : Array[Json] = []
  for p in panels {
    let m : Map[String, Json] = {
      "panel_id": p.panel_id.to_json(),
      "session_id": p.session_id.to_json(),
      "rows": p.rows.to_json(),
      "cols": p.cols.to_json(),
      "focused": p.focused.to_json(),
    }
    arr.push(m.to_json())
  }
  result_buf.result_bytes = @utf8.encode(arr.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Get the focused panel ID, or -1.
pub fn ffi_get_focused_panel_id() -> Int {
  bridge_state.layout.get_focused_panel_id()
}

///|
/// Resize the layout based on total available grid rows and columns.
/// MoonBit (LayoutManager) is the SoT for all panel dimensions.
/// Swift calls this when the window/view size changes, passing the
/// total available rows/cols computed from pixel size and cell metrics.
/// MoonBit distributes the space across panels using the layout tree ratios,
/// resizes each session's terminal grid, and returns the updated panel info.
///
/// Returns JSON: [{"panel_id":N, "session_id":N, "rows":N, "cols":N}, ...]
/// Swift uses this to ptyResize each panel's PTY.
pub fn ffi_resize_layout(
  total_rows_bytes : Bytes,
  total_cols_bytes : Bytes,
) -> Bytes {
  let total_rows = bytes_to_int(total_rows_bytes, 24)
  let total_cols = bytes_to_int(total_cols_bytes, 80)
  bridge_state.layout.resize_all(total_rows, total_cols)
  panels_to_json()
}

///|
/// Resize the layout using pixel dimensions.
/// MoonBit converts pixels → grid cells using its own cell metrics (SoT).
/// The platform adapter does NOT need to know cell dimensions for layout.
pub fn ffi_resize_layout_px(
  width_px_bytes : Bytes,
  height_px_bytes : Bytes,
) -> Bytes {
  let width_px = bytes_to_int(width_px_bytes, 640)
  let height_px = bytes_to_int(height_px_bytes, 480)
  ensure_gpu_initialized()
  let (cell_w, cell_h) = get_cell_size_logical_f()
  let total_cols = Int::max((Float::from_int(width_px) / cell_w).to_int(), 1)
  let total_rows = Int::max((Float::from_int(height_px) / cell_h).to_int(), 1)
  bridge_state.layout.resize_all(total_rows, total_cols)
  panels_to_json()
}

///|
/// Get cell size in logical points (pixels / dpi_scale) as floats.
/// Used for pixel → grid conversion. Returns floats to avoid
/// integer truncation errors (e.g. 17px / 2.0 dpi = 8.5 logical points).
fn get_cell_size_logical_f() -> (Float, Float) {
  let (cw, ch) = match bridge_state.gpu_backend {
    Some(gpu) => gpu.get_cell_size()
    None => (8, 16)
  }
  let dpi = match bridge_state.renderer {
    Some(r) => r.get_config().dpi_scale
    None => (2.0 : Float)
  }
  let logical_w = Float::from_int(cw) / dpi
  let logical_h = Float::from_int(ch) / dpi
  (
    if logical_w > (0.0 : Float) {
      logical_w
    } else {
      (8.0 : Float)
    },
    if logical_h > (0.0 : Float) {
      logical_h
    } else {
      (16.0 : Float)
    },
  )
}

///|
/// Serialize all panels in the active tab as JSON.
/// Shared by ffi_resize_layout, ffi_resize_layout_px, ffi_notify_panel_resize.
fn panels_to_json() -> Bytes {
  let panels = bridge_state.layout.get_all_panels()
  let arr : Array[Json] = []
  for p in panels {
    let m : Map[String, Json] = {
      "panel_id": p.panel_id.to_json(),
      "session_id": p.session_id.to_json(),
      "rows": p.rows.to_json(),
      "cols": p.cols.to_json(),
    }
    arr.push(m.to_json())
  }
  result_buf.result_bytes = @utf8.encode(arr.to_json().stringify())
  result_buf.result_bytes
}

///|
/// Notify that a divider has moved, giving the first child's new pixel size.
///
/// The platform adapter identifies the split by the first leaf's panel_id.
/// It passes the first child's pixel size and the total available pixel size
/// (both along the split axis). MoonBit converts pixels → cells using its
/// own cell metrics, computes the new ratio, and re-propagates dimensions.
///
/// Args (as string bytes):
///   panel_id: first leaf's panel ID
///   first_size_px: first child's pixel size along split axis
///   total_size_px: total available pixel size along split axis
/// Returns: updated panel dimensions JSON (same format as ffi_resize_layout)
pub fn ffi_notify_panel_resize(
  panel_id_bytes : Bytes,
  first_size_px_bytes : Bytes,
  total_size_px_bytes : Bytes,
) -> Bytes {
  let panel_id = bytes_to_int(panel_id_bytes, -1)
  let first_size_px = bytes_to_int(first_size_px_bytes, 0)
  let total_size_px = bytes_to_int(total_size_px_bytes, 0)
  // Convert pixel sizes to cell sizes using the renderer's cell metrics.
  // The split direction determines whether to use cell_width or cell_height,
  // but we don't need to know it here — we pass pixel-based proportional
  // sizes and let notify_panel_resize compute the ratio from them.
  // The ratio is pixel-proportional, and resize_tree will distribute cells.
  let ok = bridge_state.layout.notify_panel_resize(
    panel_id, first_size_px, total_size_px,
  )
  if ok {
    panels_to_json()
  } else {
    result_buf.result_bytes = @utf8.encode("[]")
    result_buf.result_bytes
  }
}

// ========== Session-Targeted Operations ==========

///|
/// Feed PTY output into a specific session (not just the active one).
/// Used when multiple panels are visible simultaneously.
pub fn ffi_process_output_for(session_id_bytes : Bytes, data : Bytes) -> Bytes {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      let s = bytes_to_string(data)
      let reply = session.process_output(s)
      bridge_state.layout.update_tab_title()
      result_buf.result_bytes = @utf8.encode(reply)
      result_buf.result_bytes
    }
    None => Bytes::new(0)
  }
}

///|
/// Get the grid of a specific session as JSON.
/// Same format as ffi_get_grid, but targets a specific session.
pub fn ffi_get_grid_for(session_id_bytes : Bytes) -> Bytes {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => serialize_session_grid(session)
    None => @utf8.encode("{}")
  }
}

///|
/// Handle a key on a specific session.
pub fn ffi_handle_key_for(
  session_id_bytes : Bytes,
  key_code_bytes : Bytes,
  modifiers_bytes : Bytes,
) -> Bytes {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
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
/// Resize a specific session's terminal.
pub fn ffi_resize_session(
  session_id_bytes : Bytes,
  rows_bytes : Bytes,
  cols_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let rows = bytes_to_int(rows_bytes, 24)
  let cols = bytes_to_int(cols_bytes, 80)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      session.resize(rows, cols)
      0
    }
    None => -1
  }
}

// ========== Viewport / Scrollback ==========

///|
/// Scroll a session's viewport up (back into scrollback history).
/// Returns the new viewport offset, or -1 if session not found.
pub fn ffi_scroll_viewport_up(
  session_id_bytes : Bytes,
  lines_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let lines = bytes_to_int(lines_bytes, 1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      session.get_terminal().scroll_viewport_up(lines)
      session.get_terminal().get_viewport_offset()
    }
    None => -1
  }
}

///|
/// Scroll a session's viewport down (toward live view).
/// Returns the new viewport offset, or -1 if session not found.
pub fn ffi_scroll_viewport_down(
  session_id_bytes : Bytes,
  lines_bytes : Bytes,
) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  let lines = bytes_to_int(lines_bytes, 1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      session.get_terminal().scroll_viewport_down(lines)
      session.get_terminal().get_viewport_offset()
    }
    None => -1
  }
}

///|
/// Reset a session's viewport to live view.
/// Returns 0 on success, -1 if session not found.
pub fn ffi_reset_viewport(session_id_bytes : Bytes) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => {
      session.get_terminal().reset_viewport()
      0
    }
    None => -1
  }
}

///|
/// Get a session's current viewport offset.
/// Returns offset (0=live), or -1 if session not found.
pub fn ffi_get_viewport_offset(session_id_bytes : Bytes) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => session.get_terminal().get_viewport_offset()
    None => -1
  }
}

///|
/// Get a session's scrollback length (total lines in history).
/// Returns length, or -1 if session not found.
pub fn ffi_get_scrollback_length(session_id_bytes : Bytes) -> Int {
  let session_id = bytes_to_int(session_id_bytes, -1)
  match bridge_state.sessions.get_session(session_id) {
    Some(session) => session.get_terminal().get_scrollback().length()
    None => -1
  }
}

// ========== Input Classification ==========

///|
/// Classify a key event — SoT for input routing decisions.
/// Returns:
///   0=DirectToPty, 1=ForwardToIme, 2=ClipboardCopy, 3=ClipboardPaste,
///   4=ClipboardCut, 5=SelectAll, 6=FindInTerminal,
///   10=SplitRight, 11=SplitDown, 12=NextSplit, 13=PrevSplit,
///   14=NewTab, 15=ClosePanel, 16=NextTab, 17=PrevTab,
///   20+N=GotoTab(N) (N=-1 encoded as 19 for "last tab"),
///   30+dir=FocusDirection(dir)
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
    ClipboardCut => 4
    SelectAll => 5
    FindInTerminal => 6
    SplitRight => 10
    SplitDown => 11
    NextSplit => 12
    PrevSplit => 13
    NewTab => 14
    ClosePanel => 15
    NextTab => 16
    PrevTab => 17
    GotoTab(n) =>
      // n=-1 means "last tab", encoded as 19 (= 20 + (-1))
      // n=0..7 → 20..27
      20 + n
    FocusDirection(dir) => 30 + dir
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
  bridge_state.layout.destroy_all()
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
    if negative {
      -result
    } else {
      result
    }
  } else {
    default_
  }
}

///|
/// Encode a theme RgbaColor to JSON as [r, g, b] (0-255).
fn rgba_to_json(color : @theme.RgbaColor) -> Json {
  [color.r.to_int(), color.g.to_int(), color.b.to_int(), color.a.to_int()].to_json()
}

///|
/// Convert theme RgbaColor to renderer RgbaColor, preserving alpha.
fn renderer_color(c : @theme.RgbaColor) -> @renderer.RgbaColor {
  @renderer.RgbaColor::new(c.r, c.g, c.b, c.a)
}

///|
/// Convert theme RgbaColor to renderer RgbaColor with bg_alpha applied.
fn renderer_bg_color(
  c : @theme.RgbaColor,
  alpha : Float,
) -> @renderer.RgbaColor {
  let a = (alpha * 255.0).to_int()
  let clamped = if a < 0 { 0 } else if a > 255 { 255 } else { a }
  @renderer.RgbaColor::new(c.r, c.g, c.b, clamped.to_byte())
}
