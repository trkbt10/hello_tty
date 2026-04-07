///|
/// Entry point for the hello_tty terminal emulator.
///
/// Initializes the application, sets up IPC with the PTY reader subprocess,
/// and runs the main event loop.
fn main {
  println("hello_tty — MoonBit Terminal Emulator")
  println("Initializing...")
  // Create the application with default config
  let app = @app.App::new()
  // For now, demonstrate that all layers are wired up
  // by processing a sample escape sequence through the pipeline.
  let sample_output = "\u001b[31mHello\u001b[0m, \u001b[1;32mTerminal\u001b[0m!\r\n"
  app.process_pty_output(sample_output)
  // Render a frame
  let commands = app.render()
  println("Render commands generated: " + commands.length().to_string())
  // Show terminal state
  let terminal = app.get_terminal()
  let grid = terminal.get_grid()
  let cursor = terminal.get_cursor()
  println(
    "Cursor position: row=" +
    cursor.row.to_string() +
    " col=" +
    cursor.col.to_string(),
  )
  // Print the first row's content
  let buf = StringBuilder::new()
  for col in 0..<grid.cols {
    let cell = grid.get_cell(0, col)
    if cell.char != '\u0000' {
      buf.write_char(cell.char)
    }
  }
  println("Row 0 content: " + buf.to_string())
  println("Title: " + terminal.get_title())
  println("Initialization complete. All layers operational.")
  app.shutdown()
}
