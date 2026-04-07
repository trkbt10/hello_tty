///|
/// Entry point for the hello_tty terminal emulator.
///
/// The main process:
///   1. Initializes the platform (window, Vulkan surface)
///   2. Initializes the GPU backend (Vulkan, font engine)
///   3. Creates an IPC server socket
///   4. Spawns the PTY reader subprocess
///   5. Runs the main event loop:
///      a. Poll IPC for PTY output -> parse -> update terminal
///      b. Poll platform for keyboard/mouse/resize events -> send to PTY via IPC
///      c. Render terminal state to GPU
fn main {
  println("hello_tty — MoonBit Terminal Emulator")
  // Create application with default config
  let config = @app.AppConfig::default()
  let app = @app.App::new(config~)
  let renderer_config = config.renderer_config
  // Calculate initial window size in pixels
  let gpu_renderer = @renderer.Renderer::new(config=renderer_config)
  let (win_width, win_height) = gpu_renderer.calculate_window_size(
    config.rows,
    config.cols,
  )
  // Initialize the platform
  let platform = app.get_platform()
  let platform_ok = try {
    platform.init()
    true
  } catch {
    _ => {
      println("Platform init failed")
      println("Running in headless mode (demo).")
      false
    }
  }
  if platform_ok {
    run_windowed(app, config, renderer_config, gpu_renderer, platform, win_width, win_height)
  } else {
    run_headless(app)
  }
  app.shutdown()
  println("Goodbye.")
}

///|
/// Run in windowed mode with platform window, GPU rendering, and PTY subprocess.
fn run_windowed(
  app : @app.App,
  config : @app.AppConfig,
  renderer_config : @renderer.RendererConfig,
  gpu_renderer : @renderer.Renderer,
  platform : @platform.Platform,
  win_width : Int,
  win_height : Int,
) -> Unit {
  // Create window
  let _window = try {
    platform.create_window(win_width, win_height)
  } catch {
    _ => {
      println("Window creation failed")
      return
    }
  }
  platform.set_title("hello_tty")
  // Initialize GPU backend
  let gpu = @renderer.GpuBackend::new(config=renderer_config)
  let surface = platform.get_vulkan_surface()
  let gpu_ok = try {
    gpu.init(surface, win_width, win_height)
    true
  } catch {
    _ => {
      println("GPU init failed")
      false
    }
  }
  // Set up IPC for PTY reader subprocess
  let pid = @app.current_pid()
  let socket_path = "/tmp/hello_tty_" + pid.to_string() + ".sock"
  let server = try {
    @socket.Server::new(socket_path)
  } catch {
    _ => {
      println("IPC server creation failed")
      return
    }
  }
  // Spawn PTY reader subprocess
  let pty_reader_path = find_pty_reader_binary()
  let child_pid = try {
    @app.spawn_pty_reader(
      pty_reader_path,
      socket_path,
      config.shell,
      config.rows,
      config.cols,
    )
  } catch {
    _ => {
      println("Failed to spawn PTY reader")
      server.close()
      return
    }
  }
  // Accept IPC connection from PTY reader
  let conn = try {
    server.poll_accept(timeout_ms=5000)
  } catch {
    _ => None
  }
  match conn {
    None => {
      println("PTY reader did not connect in time")
      @app.kill_child(child_pid)
      server.close()
      return
    }
    Some(ipc_conn) => {
      app.start()
      // Main event loop
      run_event_loop(app, gpu, gpu_ok, gpu_renderer, platform, ipc_conn)
      // Shutdown IPC
      try {
        ipc_conn.send(@app.IpcMessage::Shutdown.serialize())
      } catch {
        _ => ()
      }
      ipc_conn.close()
    }
  }
  // Cleanup
  @app.kill_child(child_pid)
  server.close()
  if gpu_ok {
    gpu.shutdown()
  }
}

///|
/// The main event loop: poll IPC, poll platform, render.
fn run_event_loop(
  app : @app.App,
  gpu : @renderer.GpuBackend,
  gpu_ok : Bool,
  gpu_renderer : @renderer.Renderer,
  platform : @platform.Platform,
  ipc_conn : @socket.Connection,
) -> Unit {
  ignore(platform)
  while app.is_running() {
    // 1. Poll IPC for PTY output (non-blocking)
    let ipc_ready = try {
      ipc_conn.poll(timeout_ms=1)
    } catch {
      _ => false
    }
    if ipc_ready {
      let msg_str = try {
        ipc_conn.recv()
      } catch {
        _ => None
      }
      match msg_str {
        None => break // PTY reader disconnected
        Some(s) => {
          let msg = @app.IpcMessage::deserialize(s)
          match msg {
            Some(PtyOutput(data)) => app.process_pty_output(data)
            Some(Shutdown) => break
            _ => ()
          }
        }
      }
    }
    // 2. Poll platform for events
    let event = platform.poll_event()
    match event {
      None => ()
      _ => {
        let pty_input = app.handle_platform_event(event)
        if pty_input.length() > 0 {
          let msg = @app.IpcMessage::KeyInput(pty_input)
          try {
            ipc_conn.send(msg.serialize())
          } catch {
            _ => break
          }
        }
        // Handle resize — notify PTY reader
        if event is @platform.Resize(width~, height~) {
          let (rows, cols) = gpu_renderer.calculate_grid_size(width, height)
          let resize_msg = @app.IpcMessage::Resize(rows~, cols~)
          try {
            ipc_conn.send(resize_msg.serialize())
          } catch {
            _ => ()
          }
        }
        // Handle close
        if event is @platform.CloseRequested {
          break
        }
      }
    }
    // 3. Render
    if gpu_ok {
      let commands = app.render()
      try {
        gpu.execute_frame(commands)
      } catch {
        _ => () // Swapchain error — will recover
      }
    }
    // 4. Sync title
    app.sync_title()
  }
}

///|
/// Run in headless mode — process a sample escape sequence for testing.
fn run_headless(app : @app.App) -> Unit {
  let sample = "\u001b[31mHello\u001b[0m, \u001b[1;32mTerminal\u001b[0m!\r\n"
  app.process_pty_output(sample)
  let commands = app.render()
  println("Render commands: " + commands.length().to_string())
  let terminal = app.get_terminal()
  let grid = terminal.get_grid()
  let cursor = terminal.get_cursor()
  println(
    "Cursor: row=" + cursor.row.to_string() + " col=" + cursor.col.to_string(),
  )
  let buf = StringBuilder::new()
  for col in 0..<grid.cols {
    let cell = grid.get_cell(0, col)
    if cell.char != '\u0000' {
      buf.write_char(cell.char)
    }
  }
  println("Row 0: " + buf.to_string())
  println("Title: " + terminal.get_title())
}

///|
/// Find the pty_reader binary path relative to the main binary.
fn find_pty_reader_binary() -> String {
  let args = @env.args()
  if args.length() > 0 {
    let main_path = args[0]
    // Find last '/' and replace the binary name
    let mut last_slash = -1
    let mut idx = 0
    for c in main_path {
      if c == '/' {
        last_slash = idx
      }
      idx += 1
    }
    if last_slash >= 0 {
      return main_path[0:last_slash + 1].to_string() + "pty_reader"
    }
  }
  "./pty_reader"
}
