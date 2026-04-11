///|
/// hello_tty — Linux standalone terminal emulator.
///
/// Uses LayoutManager + SessionManager directly (same backend as the
/// macOS Swift adapter via bridge). Direct PTY I/O via pty_fork_exec +
/// pty_poll_read — no subprocess needed.
///
/// Feature parity with the Swift adapter:
///   - Multi-tab, multi-panel (split) support
///   - Key classification: Cmd+D/Shift+D split, Cmd+T new tab, Cmd+W close,
///     Ctrl+Shift+C/V clipboard (Linux convention)
///   - Per-panel GPU rendering via wgpu-native
///   - Config loading from ~/.config/hello_tty/config.toml
///   - DPI-aware rendering
///   - Mouse: scroll (viewport), click (panel focus)
///   - Focus tracking, window title sync

// ========== Debug logging (stderr, unbuffered) ==========

///|
fn dbg(msg : String) -> Unit {
  let bytes = @utf8.encode(msg)
  @spawn_ffi.debug_log(bytes, bytes.length())
}

// ========== Selection state ==========

///|
/// Text selection state for mouse drag selection.
struct SelectionState {
  /// Whether a selection is active.
  mut active : Bool
  /// Anchor point (where mouse was pressed). Grid coordinates.
  mut anchor_row : Int
  mut anchor_col : Int
  /// Current end point (where mouse is now). Grid coordinates.
  mut end_row : Int
  mut end_col : Int
  /// Which panel the selection is in.
  mut panel_id : Int
}

///|
let g_selection : SelectionState = {
  active: false,
  anchor_row: 0,
  anchor_col: 0,
  end_row: 0,
  end_col: 0,
  panel_id: -1,
}

// ========== PTY read buffer (shared, avoids per-frame allocation) ==========

///|
let pty_read_buf : FixedArray[Byte] = FixedArray::make(65536, b'\x00')

// ========== Entry point ==========

///|
fn main {
  println("hello_tty — MoonBit Terminal Emulator")
  let config = load_config()
  let theme = config.resolve_theme()
  let term_cfg = config.terminal
  // Session / Layout
  let sessions = @session.SessionManager::new()
  let layout = @layout.LayoutManager::new(sessions)
  // Platform
  let platform = @platform.Platform::new()
  let platform_ok = try {
    platform.init()
    true
  } catch {
    _ => {
      println("Platform init failed — running headless demo.")
      false
    }
  }
  if platform_ok {
    run_windowed(config, theme, term_cfg, sessions, layout, platform)
  } else {
    run_headless(sessions, layout, theme, term_cfg)
  }
  // Cleanup
  layout.destroy_all()
  platform.shutdown()
  println("Goodbye.")
}

// ========== Config ==========

///|
fn load_config() -> @config.Config {
  match @sys.get_env_var("HOME") {
    Some(h) => {
      let path = h + "/.config/hello_tty/config.toml"
      if @fs.path_exists(path) {
        let toml = try { @fs.read_file_to_string(path) } catch {
          _ => return @config.Config::default()
        }
        println("Config: " + path)
        @config.Config::from_toml(toml)
      } else {
        @config.Config::default()
      }
    }
    None => @config.Config::default()
  }
}

// ========== Windowed mode ==========

///|
fn run_windowed(
  config : @config.Config,
  theme : @theme.Theme,
  term_cfg : @config.TerminalConfig,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  platform : @platform.Platform,
) -> Unit {
  // Renderer config with DPI from platform
  let dpi = platform.get_dpi_scale()
  let renderer_config : @renderer.RendererConfig = {
    cell_width: 8,
    cell_height: 16,
    font_size: config.renderer.font_size,
    dpi_scale: if dpi > 0.0 { dpi } else { 1.0 },
    atlas_size: config.renderer.atlas_size,
  }
  let renderer = @renderer.Renderer::new(config=renderer_config)
  let (win_w, win_h) = renderer.calculate_window_size(
    term_cfg.rows, term_cfg.cols,
  )
  // Window
  let _win = platform.create_window(win_w, win_h) catch {
    _ => { dbg("[main] window creation failed"); return }
  }
  platform.set_title("hello_tty")
  // GPU backend — use empty font_name to trigger FreeType auto-detection
  let font_config : @font.FontConfig = {
    font_name: "", // Empty = FreeType searches common monospace paths
    font_size: renderer_config.font_size,
    atlas_size: renderer_config.atlas_size,
  }
  let gpu = @renderer.GpuBackend::new(
    config=renderer_config,
    font=@font.FontEngine::new(config=font_config),
  )
  let surface_handle = platform.get_vulkan_surface()
  let gpu_ok = try { gpu.init(surface_handle, win_w, win_h); true } catch {
    @renderer.InitFailed(msg) => { dbg("GPU init failed: " + msg); false }
    @renderer.FontError(msg) => { dbg("GPU font error: " + msg); false }
    @renderer.RenderError(msg) => { dbg("GPU render error: " + msg); false }
    _ => { dbg("GPU init failed (unknown)"); false }
  }
  // Create first tab (this spawns a PTY via SessionManager)
  let (_tab_id, _panel_id, _master_fd) = layout.create_tab(
    term_cfg.rows, term_cfg.cols,
  )
  // Set all master fds to non-blocking
  set_all_nonblocking(sessions, layout)
  // Main event loop
  let mut running = true
  let mut cur_w = win_w
  let mut cur_h = win_h
  let mut frame_count = 0
  while running {
    // 1. Poll all PTY fds for output
    poll_all_ptys(sessions, layout)
    // 2. Drain platform events
    let mut has_events = true
    while has_events {
      let ev = platform.poll_event()
      match ev {
        @platform.None => has_events = false
        @platform.CloseRequested => { running = false; has_events = false }
        @platform.KeyPress(key_code~, modifiers~) =>
          running = handle_key(
            key_code, modifiers, sessions, layout, platform, renderer,
            term_cfg,
          )
        @platform.Resize(width~, height~) => {
          cur_w = width
          cur_h = height
          handle_resize(width, height, gpu, gpu_ok, renderer, layout)
        }
        @platform.FocusGained =>
          handle_focus(true, sessions, layout)
        @platform.FocusLost =>
          handle_focus(false, sessions, layout)
        @platform.MouseEvent(x~, y~, button~, kind~) =>
          handle_mouse(
            x, y, button, kind, sessions, layout, renderer, cur_w, cur_h,
          )
        _ => ()
      }
    }
    // 3. Render all visible panels via viewport subdivision
    if gpu_ok {
      render_all_panels(
        sessions, layout, renderer, gpu, theme, cur_w, cur_h,
      )
      frame_count += 1
    }
    // 4. Sync title
    match get_focused_session(sessions, layout) {
      Some(session) => platform.set_title(session.get_title())
      None => ()
    }
    // 5. Check if all sessions dead
    if sessions.count() == 0 {
      running = false
    }
  }
  if gpu_ok { gpu.shutdown() }
}

// ========== PTY I/O ==========

///|
/// Set all active session master fds to non-blocking.
fn set_all_nonblocking(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> Unit {
  let panels = layout.get_all_panels()
  for i in 0..<panels.length() {
    let p = panels[i]
    match sessions.get_session(p.session_id) {
      Some(session) => {
        let fd = session.get_master_fd()
        if fd >= 0 { @pty_ffi.pty_set_nonblocking(fd) |> ignore }
      }
      None => ()
    }
  }
}

///|
/// Poll all active PTY fds and feed output into sessions.
fn poll_all_ptys(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> Unit {
  let panels = layout.get_all_panels()
  for i in 0..<panels.length() {
    let p = panels[i]
    match sessions.get_session(p.session_id) {
      Some(session) => {
        let fd = session.get_master_fd()
        if fd < 0 { continue }
        // Non-blocking poll
        let ready = @pty_ffi.pty_poll_read(fd, 0)
        if ready == 1 {
          // Drain available data
          let mut keep_reading = true
          while keep_reading {
            let n = @pty_ffi.pty_read(fd, pty_read_buf, 65536)
            if n > 0 {
              let data = fixedarray_bytes_to_string(pty_read_buf, n)
              let reply = session.process_output(data)
              if reply.length() > 0 {
                let reply_bytes = @utf8.encode(reply)
                @pty_ffi.pty_write(fd, reply_bytes, reply_bytes.length())
                |> ignore
              }
            }
            // If we got less than buffer size, no more data pending
            if n < 65536 { keep_reading = false }
          }
        } else if ready < 0 {
          // EOF or error — session's PTY closed
          session.mark_dead()
        }
      }
      None => ()
    }
  }
  // Reap dead sessions
  reap_dead_sessions(sessions, layout)
}

///|
/// Convert FixedArray[Byte] to a String (UTF-8, lossy).
fn fixedarray_bytes_to_string(buf : FixedArray[Byte], len : Int) -> String {
  let sb = StringBuilder::new(size_hint=len)
  let mut i = 0
  while i < len {
    let b0 = buf[i].to_int()
    if b0 < 0x80 {
      sb.write_char(b0.unsafe_to_char())
      i += 1
    } else if b0 < 0xC0 {
      sb.write_char('\u{FFFD}')
      i += 1
    } else if b0 < 0xE0 {
      if i + 1 < len {
        let cp = (b0.land(0x1F)).lsl(6).lor(buf[i + 1].to_int().land(0x3F))
        sb.write_char(cp.unsafe_to_char())
        i += 2
      } else {
        sb.write_char('\u{FFFD}')
        i += 1
      }
    } else if b0 < 0xF0 {
      if i + 2 < len {
        let cp = (b0.land(0x0F)).lsl(12).lor(
          (buf[i + 1].to_int().land(0x3F)).lsl(6),
        ).lor(buf[i + 2].to_int().land(0x3F))
        sb.write_char(cp.unsafe_to_char())
        i += 3
      } else {
        sb.write_char('\u{FFFD}')
        i += 1
      }
    } else if b0 < 0xF8 {
      if i + 3 < len {
        let cp = (b0.land(0x07)).lsl(18).lor(
          (buf[i + 1].to_int().land(0x3F)).lsl(12),
        ).lor((buf[i + 2].to_int().land(0x3F)).lsl(6)).lor(
          buf[i + 3].to_int().land(0x3F),
        )
        sb.write_char(cp.unsafe_to_char())
        i += 4
      } else {
        sb.write_char('\u{FFFD}')
        i += 1
      }
    } else {
      sb.write_char('\u{FFFD}')
      i += 1
    }
  }
  sb.to_string()
}

///|
/// Reap sessions whose child processes have exited.
fn reap_dead_sessions(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> Unit {
  let panels = layout.get_all_panels()
  for i in 0..<panels.length() {
    let p = panels[i]
    match sessions.get_session(p.session_id) {
      Some(session) =>
        if !session.is_alive() ||
          (session.get_child_pid() > 0 &&
          @pty_ffi.pty_is_pid_alive(session.get_child_pid()) == 0) {
          // Close the panel (this destroys session via LayoutManager)
          layout.close_panel(p.panel_id) |> ignore
        }
      None => ()
    }
  }
}

// ========== Key handling ==========

///|
/// Handle a key event. Returns false if the application should quit.
fn handle_key(
  key_code : Int,
  modifiers : Int,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  platform : @platform.Platform,
  renderer : @renderer.Renderer,
  term_cfg : @config.TerminalConfig,
) -> Bool {
  // Linux clipboard: Ctrl+Shift+C/V
  let ctrl = modifiers.land(@input.mod_ctrl) != 0
  let shift = modifiers.land(@input.mod_shift) != 0
  if ctrl && shift {
    match key_code {
      0x63 | 0x43 => {
        // Ctrl+Shift+C — copy selection to clipboard
        let text = extract_selection_text(sessions, layout)
        if text.length() > 0 {
          try { platform.clipboard_set(text) } catch { _ => () }
        }
        return true
      }
      0x76 | 0x56 => {
        // Ctrl+Shift+V — paste
        let text = try { platform.clipboard_get() } catch { _ => "" }
        if text.length() > 0 {
          write_to_focused_pty(sessions, layout, text)
        }
        return true
      }
      _ => ()
    }
  }
  // Key classification via input module (handles Super+key for tab/panel ops)
  let classification = @input.classify_key(key_code, modifiers, false)
  match classification {
    DirectToPty => {
      // Scroll interception: Shift+PageUp/Down
      if shift && key_code == 0xF72C {
        scroll_focused(sessions, layout, true)
        return true
      }
      if shift && key_code == 0xF72D {
        scroll_focused(sessions, layout, false)
        return true
      }
      // Reset viewport on any key while scrolled
      reset_viewport_if_scrolled(sessions, layout)
      // Translate and send to PTY
      let modes = get_focused_modes(sessions, layout)
      let seq = @input.translate_key_input(
        key_code, modifiers, modes.cursor_keys_application,
      )
      if seq.length() > 0 {
        write_to_focused_pty(sessions, layout, seq)
      }
    }
    ForwardToIme => {
      // Platform IME (X11 XmbLookupString / Wayland text-input-v3) delivers
      // composed text as raw UTF-8 bytes in individual KeyPress events:
      //   key_code = byte value (0x00-0xFF), modifiers = 0
      // For non-ASCII bytes (>= 0x80), translate_key_input returns empty,
      // so we must send the raw byte directly to the PTY.
      reset_viewport_if_scrolled(sessions, layout)
      if key_code >= 0x80 && key_code <= 0xFF && modifiers == 0 {
        // Raw UTF-8 byte from IME composition — write directly to PTY
        write_raw_byte_to_pty(sessions, layout, key_code)
      } else {
        // ASCII or control key — translate normally
        let modes = get_focused_modes(sessions, layout)
        let seq = @input.translate_key_input(
          key_code, modifiers, modes.cursor_keys_application,
        )
        if seq.length() > 0 {
          write_to_focused_pty(sessions, layout, seq)
        }
      }
    }
    ClipboardCopy => {
      let text = extract_selection_text(sessions, layout)
      if text.length() > 0 {
        try { platform.clipboard_set(text) } catch { _ => () }
      }
    }
    ClipboardPaste => {
      let text = try { platform.clipboard_get() } catch { _ => "" }
      if text.length() > 0 {
        write_to_focused_pty(sessions, layout, text)
      }
    }
    ClipboardCut => ()
    SelectAll => ()
    FindInTerminal => ()
    NewTab => {
      let (_tid, _pid, _fd) = layout.create_tab(
        term_cfg.rows, term_cfg.cols,
      )
      set_all_nonblocking(sessions, layout)
    }
    SplitRight => {
      let panel_id = layout.get_focused_panel_id()
      if panel_id >= 0 {
        match layout.split_panel(panel_id, Vertical) {
          Some(_) => set_all_nonblocking(sessions, layout)
          None => ()
        }
      }
    }
    SplitDown => {
      let panel_id = layout.get_focused_panel_id()
      if panel_id >= 0 {
        match layout.split_panel(panel_id, Horizontal) {
          Some(_) => set_all_nonblocking(sessions, layout)
          None => ()
        }
      }
    }
    ClosePanel => {
      let panel_id = layout.get_focused_panel_id()
      if panel_id >= 0 {
        layout.close_panel(panel_id) |> ignore
      }
      // If no panels left, quit
      if sessions.count() == 0 {
        return false
      }
    }
    NextTab => { layout.next_tab() |> ignore }
    PrevTab => { layout.prev_tab() |> ignore }
    GotoTab(index) => {
      let tabs = layout.list_tabs()
      if index == -1 {
        // Last tab
        if tabs.length() > 0 {
          let (tid, _, _) = tabs[tabs.length() - 1]
          layout.switch_tab(tid) |> ignore
        }
      } else if index >= 0 && index < tabs.length() {
        let (tid, _, _) = tabs[index]
        layout.switch_tab(tid) |> ignore
      }
    }
    NextSplit => {
      // Cycle focus to next panel
      let panels = layout.get_all_panels()
      let cur = layout.get_focused_panel_id()
      let mut found = false
      for i in 0..<panels.length() {
        if panels[i].panel_id == cur {
          let next = (i + 1) % panels.length()
          layout.focus_panel(panels[next].panel_id) |> ignore
          found = true
          break
        }
      }
      if !found && panels.length() > 0 {
        layout.focus_panel(panels[0].panel_id) |> ignore
      }
    }
    PrevSplit => {
      let panels = layout.get_all_panels()
      let cur = layout.get_focused_panel_id()
      for i in 0..<panels.length() {
        if panels[i].panel_id == cur {
          let prev = if i == 0 { panels.length() - 1 } else { i - 1 }
          layout.focus_panel(panels[prev].panel_id) |> ignore
          break
        }
      }
    }
    FocusDirection(dir) => {
      let fd : @layout.FocusDirection = match dir {
        0 => Up
        1 => Down
        2 => Left
        _ => Right
      }
      layout.focus_direction(fd) |> ignore
    }
  }
  true
}

// ========== Resize ==========

///|
fn handle_resize(
  width : Int,
  height : Int,
  gpu : @renderer.GpuBackend,
  gpu_ok : Bool,
  renderer : @renderer.Renderer,
  layout : @layout.LayoutManager,
) -> Unit {
  // Resize GPU surface
  if gpu_ok {
    gpu.resize(width, height) catch { _ => () }
  }
  // Resize all panels via layout
  let (rows, cols) = renderer.calculate_grid_size(width, height)
  layout.resize_all(rows, cols)
}

// ========== Focus ==========

///|
fn handle_focus(
  gained : Bool,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> Unit {
  match get_focused_session(sessions, layout) {
    Some(session) => {
      let modes = session.get_terminal().get_modes()
      if modes.focus_tracking {
        let seq = if gained { "\u001b[I" } else { "\u001b[O" }
        let bytes = @utf8.encode(seq)
        let fd = session.get_master_fd()
        if fd >= 0 {
          @pty_ffi.pty_write(fd, bytes, bytes.length()) |> ignore
        }
      }
    }
    None => ()
  }
}

// ========== Mouse ==========

///|
fn handle_mouse(
  x : Int,
  y : Int,
  button : Int,
  kind : Int,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  renderer : @renderer.Renderer,
  win_w : Int,
  win_h : Int,
) -> Unit {
  if button == -2 {
    // Scroll wheel
    if kind > 0 {
      scroll_focused(sessions, layout, true)
    } else if kind < 0 {
      scroll_focused(sessions, layout, false)
    }
    return
  }
  let rects = compute_panel_rects(layout, win_w, win_h)
  // Find which panel the mouse is over
  let mut hit_panel_id = -1
  let mut hit_rect : PanelRect = { panel_id: -1, session_id: -1, x: 0, y: 0, w: 0, h: 0 }
  for i in 0..<rects.length() {
    let r = rects[i]
    if x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h {
      hit_panel_id = r.panel_id
      hit_rect = r
      break
    }
  }
  if hit_panel_id < 0 { return }
  let cfg = renderer.get_config()
  let cw = if cfg.cell_width > 0 { cfg.cell_width } else { 8 }
  let ch = if cfg.cell_height > 0 { cfg.cell_height } else { 16 }
  if button == 0 {
    // Left button press — start selection + focus panel
    layout.focus_panel(hit_panel_id) |> ignore
    let col = (x - hit_rect.x) / cw
    let row = (y - hit_rect.y) / ch
    g_selection.active = true
    g_selection.panel_id = hit_panel_id
    g_selection.anchor_row = row
    g_selection.anchor_col = col
    g_selection.end_row = row
    g_selection.end_col = col
  } else if button == -1 {
    // Mouse motion (drag) — update selection end
    if g_selection.active && g_selection.panel_id == hit_panel_id {
      g_selection.end_row = (y - hit_rect.y) / ch
      g_selection.end_col = (x - hit_rect.x) / cw
    }
  } else if button == 0x100 {
    // Left button release — finalize selection
    if g_selection.active {
      g_selection.end_row = (y - hit_rect.y) / ch
      g_selection.end_col = (x - hit_rect.x) / cw
    }
  }
  ignore(sessions)
}

// ========== Multi-panel rendering ==========

///|
/// Render all visible panels to the GPU surface using viewport subdivision.
/// Each panel gets its own viewport/scissor rect within the single window surface.
fn render_all_panels(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  renderer : @renderer.Renderer,
  gpu : @renderer.GpuBackend,
  theme : @theme.Theme,
  win_w : Int,
  win_h : Int,
) -> Unit {
  let rects = compute_panel_rects(layout, win_w, win_h)
  if rects.length() == 0 { return }
  let focused_id = layout.get_focused_panel_id()
  // Begin frame (clears with background color)
  if !gpu.frame_begin(0, theme.bg) { return }
  // Render each panel in its viewport
  for i in 0..<rects.length() {
    let rect = rects[i]
    if rect.w <= 0 || rect.h <= 0 { continue }
    match sessions.get_session(rect.session_id) {
      Some(session) => {
        // Set viewport to this panel's pixel bounds
        gpu.set_viewport(0, rect.x, rect.y, rect.w, rect.h)
        // Build render commands for this panel's terminal
        let commands = renderer.render(session.get_terminal(), theme)
        // Execute draw commands (cells + cursor) within the viewport
        for j in 0..<commands.length() {
          match commands[j] {
            @renderer.Clear(_) => () // Already cleared whole surface
            @renderer.DrawCells(cells) =>
              gpu.draw_cell_quads_on(0, cells)
            @renderer.DrawCursor(cursor) =>
              if rect.panel_id == focused_id {
                gpu.draw_cursor_quad_on(0, cursor)
              }
            @renderer.Present => ()
          }
        }
      }
      None => ()
    }
  }
  // End frame and present
  gpu.frame_end(0) |> ignore
}

// ========== Panel pixel bounds (layout tree → screen rectangles) ==========

///|
/// A panel's pixel bounds within the window.
struct PanelRect {
  panel_id : Int
  session_id : Int
  x : Int
  y : Int
  w : Int
  h : Int
}

///|
/// Compute pixel bounds for all visible panels from the layout tree.
fn compute_panel_rects(
  layout : @layout.LayoutManager,
  win_w : Int,
  win_h : Int,
) -> Array[PanelRect] {
  let rects : Array[PanelRect] = []
  match layout.get_active_layout() {
    Some(node) => layout_node_to_rects(node, 0, 0, win_w, win_h, rects)
    None => ()
  }
  rects
}

///|
fn layout_node_to_rects(
  node : @layout.LayoutNode,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  out : Array[PanelRect],
) -> Unit {
  match node {
    Leaf(info) =>
      out.push({ panel_id: info.panel_id, session_id: info.session_id, x, y, w, h })
    Split(dir, first, second, ratio) => {
      match dir {
        Vertical => {
          let first_w = (Float::from_int(w) * ratio).to_int()
          let second_w = w - first_w
          layout_node_to_rects(first, x, y, first_w, h, out)
          layout_node_to_rects(second, x + first_w, y, second_w, h, out)
        }
        Horizontal => {
          let first_h = (Float::from_int(h) * ratio).to_int()
          let second_h = h - first_h
          layout_node_to_rects(first, x, y, w, first_h, out)
          layout_node_to_rects(second, x, y + first_h, w, second_h, out)
        }
      }
    }
  }
}

// ========== Selection text extraction ==========

///|
/// Extract text from the terminal grid within the current selection bounds.
fn extract_selection_text(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> String {
  if !g_selection.active { return "" }
  // Find the session for the selected panel
  let panels = layout.get_all_panels()
  let mut session_id = -1
  for i in 0..<panels.length() {
    if panels[i].panel_id == g_selection.panel_id {
      session_id = panels[i].session_id
      break
    }
  }
  match sessions.get_session(session_id) {
    Some(session) => {
      let grid = session.get_terminal().get_grid()
      // Normalize selection: ensure start <= end
      let mut r1 = g_selection.anchor_row
      let mut c1 = g_selection.anchor_col
      let mut r2 = g_selection.end_row
      let mut c2 = g_selection.end_col
      if r1 > r2 || (r1 == r2 && c1 > c2) {
        let tr = r1
        let tc = c1
        r1 = r2
        c1 = c2
        r2 = tr
        c2 = tc
      }
      // Clamp to grid bounds
      r1 = Int::max(0, Int::min(r1, grid.rows - 1))
      r2 = Int::max(0, Int::min(r2, grid.rows - 1))
      c1 = Int::max(0, Int::min(c1, grid.cols - 1))
      c2 = Int::max(0, Int::min(c2, grid.cols - 1))
      let sb = StringBuilder::new()
      for row in r1..=r2 {
        let col_start = if row == r1 { c1 } else { 0 }
        let col_end = if row == r2 { c2 } else { grid.cols - 1 }
        let mut last_non_space = col_start - 1
        for col in col_start..=col_end {
          let cell = grid.get_cell(row, col)
          if cell.char != '\u0000' && cell.char != ' ' {
            last_non_space = col
          }
        }
        for col in col_start..=Int::max(col_start, last_non_space) {
          let cell = grid.get_cell(row, col)
          if cell.char != '\u0000' {
            sb.write_char(cell.char)
          } else {
            sb.write_char(' ')
          }
        }
        if row < r2 { sb.write_char('\n') }
      }
      sb.to_string()
    }
    None => ""
  }
}

// ========== Helpers ==========

///|
fn get_focused_session(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> @session.Session? {
  match layout.focused_panel() {
    Some(info) => sessions.get_session(info.session_id)
    None => sessions.active_session()
  }
}

///|
fn get_focused_modes(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> @terminal.TermModes {
  match get_focused_session(sessions, layout) {
    Some(s) => s.get_terminal().get_modes()
    None => @terminal.TermModes::default()
  }
}

///|
/// Write a single raw byte to the focused session's PTY.
/// Used for IME-composed UTF-8 bytes (key_code >= 0x80) that come as
/// individual KeyPress events from X11 XmbLookupString / Wayland text-input.
fn write_raw_byte_to_pty(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  byte_val : Int,
) -> Unit {
  match get_focused_session(sessions, layout) {
    Some(session) => {
      let fd = session.get_master_fd()
      if fd >= 0 {
        // Construct a single-byte Bytes directly via FixedArray
        let fa : FixedArray[Byte] = [byte_val.to_byte()]
        let buf = Bytes::from_fixedarray(fa)
        @pty_ffi.pty_write(fd, buf, 1) |> ignore
      }
    }
    None => ()
  }
}

///|
fn write_to_focused_pty(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  text : String,
) -> Unit {
  match get_focused_session(sessions, layout) {
    Some(session) => {
      let fd = session.get_master_fd()
      if fd >= 0 {
        let bytes = @utf8.encode(text)
        @pty_ffi.pty_write(fd, bytes, bytes.length()) |> ignore
      }
    }
    None => ()
  }
}

///|
fn scroll_focused(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  up : Bool,
) -> Unit {
  match get_focused_session(sessions, layout) {
    Some(session) => {
      let lines = session.get_terminal().rows / 2
      if up {
        session.get_terminal().scroll_viewport_up(lines)
      } else {
        session.get_terminal().scroll_viewport_down(lines)
      }
    }
    None => ()
  }
}

///|
fn reset_viewport_if_scrolled(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> Unit {
  match get_focused_session(sessions, layout) {
    Some(session) =>
      if session.get_terminal().get_viewport_offset() > 0 {
        session.get_terminal().reset_viewport()
      }
    None => ()
  }
}

// ========== Headless mode ==========

///|
fn run_headless(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  theme : @theme.Theme,
  term_cfg : @config.TerminalConfig,
) -> Unit {
  // Create a tab
  let _ = layout.create_tab(term_cfg.rows, term_cfg.cols)
  // Feed sample data into the active session
  match sessions.active_session() {
    Some(session) => {
      let sample = "\u001b[31mHello\u001b[0m, \u001b[1;32mTerminal\u001b[0m!\r\n"
      let _ = session.process_output(sample)
      let renderer = @renderer.Renderer::new()
      let commands = renderer.render(session.get_terminal(), theme)
      println("Render commands: " + commands.length().to_string())
      let terminal = session.get_terminal()
      let grid = terminal.get_grid()
      let cursor = terminal.get_cursor()
      println(
        "Cursor: row=" + cursor.row.to_string() + " col=" + cursor.col.to_string(),
      )
      let buf = StringBuilder::new()
      for col in 0..<grid.cols {
        let cell = grid.get_cell(0, col)
        if cell.char != '\u0000' { buf.write_char(cell.char) }
      }
      println("Row 0: " + buf.to_string())
      println("Title: " + terminal.get_title())
      // Test tab operations
      let tab_count_before = layout.tab_count()
      let _ = layout.create_tab(term_cfg.rows, term_cfg.cols)
      println(
        "Tabs: " + tab_count_before.to_string() + " -> " + layout.tab_count().to_string(),
      )
      // Test split
      let panel_id = layout.get_focused_panel_id()
      match layout.split_panel(panel_id, Vertical) {
        Some(result) =>
          println(
            "Split OK: new panel=" + result.new_panel_id.to_string() +
            " session=" + result.new_session_id.to_string(),
          )
        None => println("Split: too small")
      }
      println("Panels: " + layout.get_all_panels().length().to_string())
    }
    None => println("No session created")
  }
}
