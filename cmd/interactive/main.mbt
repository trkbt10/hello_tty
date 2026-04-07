///|
/// Interactive terminal test — pure C PTY session.
///
/// forkpty + exec を完全にC側で実行（MoonBitのGCはfork-unsafe）。
/// MoonBit側はmaster fdに対するpoll/read/writeと、
/// VTパーサー + ターミナルステート更新のみ行う。
///
/// Ctrl+D or exit で終了。

fn main {
  // raw mode
  let old_termios = @ffi.enable_raw_mode()
  let raw_mode = old_termios >= 0
  // PTYセッション開始（C側でfork+exec）
  let shell = @utf8.encode("/bin/sh\x00") // null terminated
  let result : FixedArray[Int] = FixedArray::make(2, 0)
  let ret = @ffi.pty_session_start(shell, 24, 80, result)
  if ret < 0 {
    if raw_mode {
      @ffi.restore_mode(old_termios)
    }
    println("Failed to start PTY session")
    return
  }
  let master_fd = result[0]
  let child_pid = result[1]
  debug("session started: master_fd=" + master_fd.to_string() + " pid=" + child_pid.to_string())
  // VTパーサーとターミナル
  let parser = @vt_parser.Parser::new()
  let terminal = @terminal.Terminal::new(rows=24, cols=80)
  // メインループ
  let read_buf : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  let mut running = true
  let mut stdin_open = true
  while running {
    // 1. PTYからの出力
    let poll_result = @ffi.pty_session_poll(master_fd, 20)
    if poll_result > 0 {
      let n = @ffi.pty_session_read(master_fd, read_buf, 4096)
      if n > 0 {
        // stdoutに書く
        let out = fixed_to_bytes(read_buf, n)
        @ffi.write_stdout(out, out.length()) |> ignore
        // VTパーサーに通す
        let s = fixed_to_string(read_buf, n)
        let events = parser.feed_str(s)
        terminal.handle_events(events)
      } else if n == 0 {
        running = false
      }
    } else if poll_result == -2 {
      // PTY EOF
      running = false
    }
    // 2. stdinからの入力
    if stdin_open {
      let stdin_ready = @ffi.poll_stdin(5)
      if stdin_ready > 0 {
        let stdin_buf : FixedArray[Byte] = FixedArray::make(256, b'\x00')
        let n = @ffi.read_stdin(stdin_buf, 256)
        if n > 0 {
          // \n → \r 変換 (ターミナルではEnter = CR)
          for i in 0..<n {
            if stdin_buf[i] == b'\x0a' {
              stdin_buf[i] = b'\x0d'
            }
          }
          let input = fixed_to_bytes(stdin_buf, n)
          @ffi.pty_session_write(master_fd, input, input.length()) |> ignore
        } else if n == 0 {
          stdin_open = false
        }
      }
    }
  }
  // フラッシュ
  for _i in 0..<50 {
    let p = @ffi.pty_session_poll(master_fd, 20)
    if p <= 0 {
      break
    }
    let n = @ffi.pty_session_read(master_fd, read_buf, 4096)
    if n <= 0 {
      break
    }
    let out = fixed_to_bytes(read_buf, n)
    @ffi.write_stdout(out, out.length()) |> ignore
    let s = fixed_to_string(read_buf, n)
    let events = parser.feed_str(s)
    terminal.handle_events(events)
  }
  // クリーンアップ
  @ffi.pty_session_close(master_fd)
  if raw_mode {
    @ffi.restore_mode(old_termios)
  }
  // ターミナル状態
  let cursor = terminal.get_cursor()
  let grid = terminal.get_grid()
  println("")
  println("[interactive] session ended")
  println(
    "  cursor=(" + cursor.row.to_string() + "," + cursor.col.to_string() + ")",
  )
  println("  grid content:")
  for row in 0..<grid.rows {
    let line = grid.lines[row]
    let buf = StringBuilder::new()
    let mut has = false
    for col in 0..<grid.cols {
      let cell = line.get(col)
      if cell.char != '\u0000' {
        buf.write_char(cell.char)
        has = true
      }
    }
    if has {
      println("    [" + row.to_string() + "] " + buf.to_string())
    }
  }
}

///|
fn debug(msg : String) -> Unit {
  let s = "[debug] " + msg + "\n"
  let b = @utf8.encode(s)
  @ffi.debug_log(b, b.length()) |> ignore
}

///|
fn fixed_to_string(buf : FixedArray[Byte], n : Int) -> String {
  let sb = StringBuilder::new()
  for i in 0..<n {
    sb.write_char(buf[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
fn fixed_to_bytes(buf : FixedArray[Byte], n : Int) -> Bytes {
  let arr : Array[Byte] = Array::new(capacity=n)
  for i in 0..<n {
    arr.push(buf[i])
  }
  Bytes::from_array(arr)
}
