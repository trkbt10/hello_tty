///|
/// Linux adapter — PTY I/O: non-blocking read, byte conversion, session reaping.

///|
let pty_read_buf : FixedArray[Byte] = FixedArray::make(65536, b'\x00')

///|
pub fn set_all_nonblocking(
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
pub fn poll_all_ptys(
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
        let ready = @pty_ffi.pty_poll_read(fd, 0)
        if ready == 1 {
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
            if n < 65536 { keep_reading = false }
          }
        } else if ready < 0 {
          session.mark_dead()
        }
      }
      None => ()
    }
  }
  reap_dead_sessions(sessions, layout)
}

///|
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
          layout.close_panel(p.panel_id) |> ignore
        }
      None => ()
    }
  }
}

///|
pub fn write_to_focused_pty(
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
pub fn write_raw_byte_to_pty(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  byte_val : Int,
) -> Unit {
  match get_focused_session(sessions, layout) {
    Some(session) => {
      let fd = session.get_master_fd()
      if fd >= 0 {
        let fa : FixedArray[Byte] = [byte_val.to_byte()]
        let buf = Bytes::from_fixedarray(fa)
        @pty_ffi.pty_write(fd, buf, 1) |> ignore
      }
    }
    None => ()
  }
}

///|
pub fn scroll_focused(
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
pub fn reset_viewport_if_scrolled(
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
