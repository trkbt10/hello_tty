///|
/// The App orchestrates all layers of the terminal emulator.
///
/// ## Multi-process architecture
///
/// Since MoonBit is single-threaded, the architecture uses separate processes
/// connected via IPC (Unix sockets from trkbt10/subprocess):
///
/// 1. **Main process**: Owns the platform window, renderer, terminal state,
///    and VT parser. Handles input events and rendering.
///
/// 2. **PTY reader subprocess**: Owns the PTY master fd. Reads PTY output
///    and sends it to the main process via IPC. Receives keyboard input
///    from the main process and writes it to the PTY.
///
/// This separation prevents PTY I/O from blocking the render loop.
pub struct App {
  config : AppConfig
  terminal : @terminal.Terminal
  parser : @vt_parser.Parser
  renderer : @renderer.Renderer
  platform : @platform.Platform
  mut state : AppState
  /// Process manager for subprocess lifecycle.
  process_manager : @managed.ProcessManager
}

///|
/// Create a new terminal emulator application.
pub fn App::new(config? : AppConfig = AppConfig::default()) -> App {
  let terminal = @terminal.Terminal::new(
    rows=config.rows,
    cols=config.cols,
    max_scrollback=config.max_scrollback,
  )
  let parser = @vt_parser.Parser::new()
  let renderer = @renderer.Renderer::new(config=config.renderer_config)
  let platform = @platform.Platform::new()
  let process_manager = @managed.ProcessManager::new()
  {
    config,
    terminal,
    parser,
    renderer,
    platform,
    state: Starting,
    process_manager,
  }
}

///|
/// Feed raw PTY output bytes into the parser and terminal.
pub fn App::process_pty_output(self : App, data : String) -> Unit {
  let events = self.parser.feed_str(data)
  self.terminal.handle_events(events)
}

///|
/// Handle a platform input event.
/// Returns the bytes to send to the PTY (if any).
pub fn App::handle_platform_event(
  self : App,
  event : @platform.PlatformEvent,
) -> String {
  match event {
    None => ""
    KeyPress(key_code~, modifiers~) => {
      let modes = self.terminal.get_modes()
      translate_key_input(key_code, modifiers, modes.cursor_keys_application)
    }
    Resize(width~, height~) => {
      let (rows, cols) = self.renderer.calculate_grid_size(width, height)
      self.terminal.resize(rows, cols)
      // Return a resize notification that the caller should send to PTY
      ""
    }
    CloseRequested => {
      self.state = ShuttingDown
      ""
    }
    FocusGained => {
      let modes = self.terminal.get_modes()
      if modes.focus_tracking {
        "\u001b[I" // Focus in
      } else {
        ""
      }
    }
    FocusLost => {
      let modes = self.terminal.get_modes()
      if modes.focus_tracking {
        "\u001b[O" // Focus out
      } else {
        ""
      }
    }
    MouseEvent(..) =>
      // Mouse event translation (TODO: implement mouse protocol)
      ""
    Error(_msg) => ""
  }
}

///|
/// Produce render commands for the current frame.
pub fn App::render(self : App) -> Array[@renderer.RenderCommand] {
  self.renderer.render(self.terminal)
}

///|
/// Update the window title from the terminal's OSC-set title.
pub fn App::sync_title(self : App) -> Unit {
  let title = self.terminal.get_title()
  self.platform.set_title(title)
}

///|
/// Resize the terminal and notify the PTY.
pub fn App::resize(self : App, rows : Int, cols : Int) -> Unit {
  self.terminal.resize(rows, cols)
}

///|
/// Get the current application state.
pub fn App::get_state(self : App) -> AppState {
  self.state
}

///|
/// Check if the application should keep running.
pub fn App::is_running(self : App) -> Bool {
  self.state == Running
}

///|
/// Transition to the Running state.
pub fn App::start(self : App) -> Unit {
  self.state = Running
}

///|
/// Begin graceful shutdown.
pub fn App::shutdown(self : App) -> Unit {
  self.state = ShuttingDown
  self.platform.shutdown()
  self.state = Stopped
}

///|
/// Get the terminal (for external inspection or testing).
pub fn App::get_terminal(self : App) -> @terminal.Terminal {
  self.terminal
}

///|
/// Get the platform (for window management).
pub fn App::get_platform(self : App) -> @platform.Platform {
  self.platform
}

///|
/// Get the process manager.
pub fn App::get_process_manager(self : App) -> @managed.ProcessManager {
  self.process_manager
}
