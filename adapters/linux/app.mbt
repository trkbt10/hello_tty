///|
/// Linux adapter — application lifecycle and main event loop.
///
/// Mirrors adapters/macos structure: platform init, window creation,
/// GPU setup, PTY management, event dispatch, and shutdown.

// ========== Debug logging (stderr, unbuffered) ==========

///|
pub fn dbg(msg : String) -> Unit {
  let bytes = @utf8.encode(msg)
  @spawn_ffi.debug_log(bytes, bytes.length())
}

// ========== Config ==========

///|
pub fn load_config() -> @config.Config {
  match @sys.get_env_var("HOME") {
    Some(h) => {
      let path = h + "/.config/hello_tty/config.toml"
      if @fs.path_exists(path) {
        let toml = try { @fs.read_file_to_string(path) } catch {
          _ => return @config.Config::default()
        }
        dbg("Config: " + path)
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
pub fn run_windowed(
  config : @config.Config,
  theme : @theme.Theme,
  term_cfg : @config.TerminalConfig,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  platform : @platform.Platform,
) -> Unit {
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
    _ => { dbg("window creation failed"); return }
  }
  platform.set_title("hello_tty")
  // GPU backend — empty font_name triggers FreeType auto-detection on Linux
  let font_config : @font.FontConfig = {
    font_name: "",
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
  // Create first tab
  let _ = layout.create_tab(term_cfg.rows, term_cfg.cols)
  set_all_nonblocking(sessions, layout)
  // Event loop
  let mut running = true
  let mut cur_w = win_w
  let mut cur_h = win_h
  while running {
    poll_all_ptys(sessions, layout)
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
        @platform.FocusGained => handle_focus(true, sessions, layout)
        @platform.FocusLost => handle_focus(false, sessions, layout)
        @platform.MouseEvent(x~, y~, button~, kind~) =>
          handle_mouse(
            x, y, button, kind, sessions, layout, renderer, cur_w, cur_h,
          )
        _ => ()
      }
    }
    if gpu_ok {
      render_all_panels(sessions, layout, renderer, gpu, theme, cur_w, cur_h)
    }
    match get_focused_session(sessions, layout) {
      Some(session) => platform.set_title(session.get_title())
      None => ()
    }
    if sessions.count() == 0 { running = false }
  }
  if gpu_ok { gpu.shutdown() }
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
  if gpu_ok { gpu.resize(width, height) catch { _ => () } }
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
        if fd >= 0 { @pty_ffi.pty_write(fd, bytes, bytes.length()) |> ignore }
      }
    }
    None => ()
  }
}

// ========== Headless mode ==========

///|
pub fn run_headless(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  theme : @theme.Theme,
  term_cfg : @config.TerminalConfig,
) -> Unit {
  let _ = layout.create_tab(term_cfg.rows, term_cfg.cols)
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
      let tab_count_before = layout.tab_count()
      let _ = layout.create_tab(term_cfg.rows, term_cfg.cols)
      println(
        "Tabs: " + tab_count_before.to_string() + " -> " + layout.tab_count().to_string(),
      )
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

// ========== Helpers ==========

///|
pub fn get_focused_session(
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
