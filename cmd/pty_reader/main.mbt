///|
/// PTY Reader subprocess.
///
/// This is a separate process that:
///   1. Connects to the main process via IPC (Unix socket)
///   2. Forks a child shell via PTY
///   3. Reads PTY output in a loop and sends it to the main process
///   4. Receives keyboard input from the main process and writes it to the PTY
///
/// Communication protocol uses IpcMessage serialization over
/// trkbt10/subprocess IPC sockets (length-prefixed framing).
///
/// Usage: pty_reader <socket_path> [shell] [rows] [cols]

fn main {
  let args = @env.args()
  // args[0] = program name, args[1] = socket_path, etc.
  if args.length() < 2 {
    println("Usage: pty_reader <socket_path> [shell] [rows] [cols]")
    return
  }
  let socket_path = args[1]
  let shell = if args.length() >= 3 { args[2] } else { "/bin/zsh" }
  let rows = if args.length() >= 4 {
    parse_int_or(args[3], 24)
  } else {
    24
  }
  let cols = if args.length() >= 5 {
    parse_int_or(args[4], 80)
  } else {
    80
  }
  // Connect to the main process via IPC socket
  let conn = try {
    @socket.Connection::connect(socket_path)
  } catch {
    err => {
      println("pty_reader: failed to connect to " + socket_path)
      return
    }
  }
  // Fork the child shell via PTY
  let child = try {
    @pty.fork_with_shell(shell~, rows~, cols~)
  } catch {
    err => {
      println("pty_reader: fork_with_shell failed")
      conn.close()
      return
    }
  }
  // Set PTY master to non-blocking for polling
  try {
    child.set_nonblocking()
  } catch {
    _ => ()
  }
  // Main loop: multiplex PTY reads and IPC receives
  let mut running = true
  while running {
    // Check for PTY output (non-blocking poll with short timeout)
    let pty_readable = try {
      child.poll_read(timeout_ms=10)
    } catch {
      _ => false
    }
    if pty_readable {
      let data = try {
        child.read()
      } catch {
        _ => Bytes::new(0)
      }
      if data.length() > 0 {
        // Convert bytes to string and send via IPC
        let s = bytes_to_string(data)
        let msg = @app.IpcMessage::PtyOutput(s)
        try {
          conn.send(msg.serialize())
        } catch {
          _ => {
            running = false
          }
        }
      } else if data.length() == 0 {
        // EOF from PTY — child process exited
        running = false
      }
    }
    // Check for IPC messages from main process (non-blocking)
    let ipc_readable = try {
      conn.poll(timeout_ms=0)
    } catch {
      _ => false
    }
    if ipc_readable {
      let msg_str = try {
        conn.recv()
      } catch {
        _ => None
      }
      match msg_str {
        None => {
          // Main process disconnected
          running = false
        }
        Some(s) => {
          let msg = @app.IpcMessage::deserialize(s)
          match msg {
            Some(KeyInput(input)) => {
              // Write keyboard input to PTY
              try {
                child.write_string(input)
              } catch {
                _ => {
                  running = false
                }
              }
            }
            Some(Resize(rows~, cols~)) => {
              // Resize PTY
              try {
                child.resize(rows, cols)
              } catch {
                _ => ()
              }
            }
            Some(Shutdown) => {
              running = false
            }
            _ => ()
          }
        }
      }
    }
  }
  // Cleanup
  child.close()
  try {
    conn.send(@app.IpcMessage::Shutdown.serialize())
  } catch {
    _ => ()
  }
  conn.close()
}

///|
fn bytes_to_string(data : Bytes) -> String {
  let buf = StringBuilder::new()
  for i in 0..<data.length() {
    buf.write_char(data[i].to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
fn parse_int_or(s : String, default_ : Int) -> Int {
  let mut result = 0
  let mut has_digit = false
  for c in s {
    let code = c.to_int()
    if code >= 0x30 && code <= 0x39 {
      result = result * 10 + (code - 0x30)
      has_digit = true
    } else {
      return default_
    }
  }
  if has_digit {
    result
  } else {
    default_
  }
}
