///|
/// Entry point for the hello_tty Linux standalone terminal emulator.
///
/// This is a thin wrapper that delegates to the Linux adapter (adapters/linux/).
/// The adapter provides: event loop, PTY I/O, input handling, GPU rendering,
/// text selection, and layout utilities — mirroring adapters/macos/ structure.
fn main {
  println("hello_tty — MoonBit Terminal Emulator")
  let config = @linux.load_config()
  let theme = config.resolve_theme()
  let term_cfg = config.terminal
  let sessions = @session.SessionManager::new()
  let layout = @layout.LayoutManager::new(sessions)
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
    @linux.run_windowed(config, theme, term_cfg, sessions, layout, platform)
  } else {
    @linux.run_headless(sessions, layout, theme, term_cfg)
  }
  layout.destroy_all()
  platform.shutdown()
  println("Goodbye.")
}
