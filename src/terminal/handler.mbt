///|
/// The Terminal is the top-level state object.
/// It holds the screen set, modes, and processes parsed events from the VT parser.
pub struct Terminal {
  screen : ScreenSet
  mut modes : TermModes
  /// Tab stops (column indices).
  tab_stops : Array[Bool]
  /// Terminal title (set via OSC 0/2).
  mut title : String
  /// Terminal dimensions.
  mut rows : Int
  mut cols : Int
}

///|
/// Create a new terminal with the given dimensions.
pub fn Terminal::new(
  rows? : Int = 24,
  cols? : Int = 80,
  max_scrollback? : Int = 10000,
) -> Terminal {
  let tab_stops : Array[Bool] = Array::make(cols, false)
  // Set default tab stops every 8 columns
  for i in 0..<cols {
    if i % 8 == 0 {
      tab_stops[i] = true
    }
  }
  {
    screen: ScreenSet::new(rows, cols, max_scrollback~),
    modes: TermModes::default(),
    tab_stops,
    title: "",
    rows,
    cols,
  }
}

///|
/// Process a single parser event, updating terminal state.
pub fn Terminal::handle_event(
  self : Terminal,
  event : @vt_parser.ParserEvent,
) -> Unit {
  match event {
    Nop => ()
    PrintChar(c) => self.print_char(c)
    Utf8Char(c) => self.print_char(c)
    Control(byte) => self.handle_control(byte)
    CsiSequence(cmd) => self.handle_csi(cmd)
    EscSequence(cmd) => self.handle_esc(cmd)
    OscSequence(cmd) => self.handle_osc(cmd)
    DcsSequence(_data) => () // DCS sequences are not widely used; stub for now
  }
}

///|
/// Process multiple parser events.
pub fn Terminal::handle_events(
  self : Terminal,
  events : Array[@vt_parser.ParserEvent],
) -> Unit {
  for i in 0..<events.length() {
    self.handle_event(events[i])
  }
}

///|
/// Print a character at the cursor position.
///
/// Handles wide characters (CJK, fullwidth, emoji) that occupy 2 cells:
///   - The first cell holds the character with width=2
///   - The second cell is a continuation cell with width=0 and char='\u0000'
///
/// When overwriting a wide character or its continuation cell, the other
/// half is cleared to prevent rendering artifacts.
fn Terminal::print_char(self : Terminal, c : Char) -> Unit {
  let grid = self.screen.active_grid()
  let cursor = self.screen.active_cursor()
  let width = char_width(c)
  // Zero-width characters (combining marks, etc.) — don't advance cursor
  if width == 0 {
    // For now, ignore zero-width characters.
    // A full implementation would attach them to the previous cell as
    // combining characters, but that requires grapheme cluster support.
    return
  }
  // Handle pending wrap (auto-wrap at right margin)
  if cursor.wrap_pending {
    if self.modes.auto_wrap {
      cursor.col = 0
      if cursor.row == grid.scroll_bottom {
        self.screen.scroll_up(1)
      } else if cursor.row < self.rows - 1 {
        cursor.row += 1
      }
      grid.lines[cursor.row].wrapped = true
    }
    cursor.wrap_pending = false
  }
  // Wide character that doesn't fit on the current line:
  // If the cursor is at the last column and the character is 2 cells wide,
  // we need to wrap first (leave the last column blank).
  if width == 2 && cursor.col >= self.cols - 1 {
    if self.modes.auto_wrap {
      // Fill the remaining cell with a space to avoid artifacts
      grid.set_cell_with_width(cursor.row, cursor.col, ' ', cursor.pen, 1)
      cursor.col = 0
      if cursor.row == grid.scroll_bottom {
        self.screen.scroll_up(1)
      } else if cursor.row < self.rows - 1 {
        cursor.row += 1
      }
      grid.lines[cursor.row].wrapped = true
    } else {
      // No auto-wrap: just place the character at the last column as 1-width
      // (truncated — this matches standard terminal behavior)
      grid.set_cell_with_width(cursor.row, cursor.col, c, cursor.pen, 1)
      return
    }
  }
  // Insert mode: shift characters right
  if self.modes.insert_mode {
    grid.insert_cells(cursor.row, cursor.col, width)
  }
  // Clear any wide character that we're overwriting.
  // If the cell under the cursor is a continuation cell (width=0), the
  // preceding cell is the head of a wide character — clear it.
  // If the cell under the cursor is a wide character head (width=2),
  // its continuation cell needs clearing too.
  grid.clear_wide_char_at(cursor.row, cursor.col)
  // Write the character
  grid.set_cell_with_width(cursor.row, cursor.col, c, cursor.pen, width)
  // For wide characters, set continuation cell
  if width == 2 && cursor.col + 1 < self.cols {
    grid.set_cell_with_width(
      cursor.row, cursor.col + 1, '\u0000', cursor.pen, 0,
    )
  }
  // Advance cursor
  let new_col = cursor.col + width
  if new_col >= self.cols {
    cursor.col = self.cols - 1
    cursor.wrap_pending = true
  } else {
    cursor.col = new_col
  }
}

///|
/// Handle a C0/C1 control code.
fn Terminal::handle_control(self : Terminal, byte : Byte) -> Unit {
  let b = byte.to_int()
  let grid = self.screen.active_grid()
  let cursor = self.screen.active_cursor()
  match b {
    0x07 => () // BEL — bell (could emit to platform layer)
    0x08 =>
      // BS — backspace
      if cursor.col > 0 {
        cursor.col -= 1
        cursor.wrap_pending = false
      }
    0x09 => {
      // HT — horizontal tab
      let mut next_col = cursor.col + 1
      while next_col < self.cols {
        if self.tab_stops[next_col] {
          break
        }
        next_col += 1
      }
      cursor.col = next_col.clamp(min=0, max=self.cols - 1)
      cursor.wrap_pending = false
    }
    0x0A | 0x0B | 0x0C => {
      // LF, VT, FF — line feed
      if cursor.row == grid.scroll_bottom {
        self.screen.scroll_up(1)
      } else if cursor.row < self.rows - 1 {
        cursor.row += 1
      }
      if self.modes.linefeed_mode {
        cursor.col = 0
      }
      cursor.wrap_pending = false
    }
    0x0D => {
      // CR — carriage return
      cursor.col = 0
      cursor.wrap_pending = false
    }
    0x0E =>
      // SO — shift out (activate G1 charset)
      cursor.active_charset = 1
    0x0F =>
      // SI — shift in (activate G0 charset)
      cursor.active_charset = 0
    _ => () // Other C0 controls ignored
  }
}

///|
/// Handle a CSI (Control Sequence Introducer) command.
fn Terminal::handle_csi(self : Terminal, cmd : @vt_parser.CsiCommand) -> Unit {
  let grid = self.screen.active_grid()
  let cursor = self.screen.active_cursor()
  let final_byte = cmd.final_byte.to_int()
  // Check for private mode marker '?' in intermediates
  let is_private = cmd.intermediates.length() > 0 &&
    cmd.intermediates[0].to_int() == 0x3F
  // Helper: get param with default value
  fn param(index : Int, default_ : Int) -> Int {
    if index < cmd.params.length() && cmd.params[index] != 0 {
      cmd.params[index]
    } else {
      default_
    }
  }
  match final_byte {
    0x41 => {
      // CUU — Cursor Up
      let n = param(0, 1)
      cursor.move_by(-n, 0, self.rows, self.cols)
    }
    0x42 => {
      // CUD — Cursor Down
      let n = param(0, 1)
      cursor.move_by(n, 0, self.rows, self.cols)
    }
    0x43 => {
      // CUF — Cursor Forward
      let n = param(0, 1)
      cursor.move_by(0, n, self.rows, self.cols)
    }
    0x44 => {
      // CUB — Cursor Back
      let n = param(0, 1)
      cursor.move_by(0, -n, self.rows, self.cols)
    }
    0x45 => {
      // CNL — Cursor Next Line
      let n = param(0, 1)
      cursor.move_by(n, 0, self.rows, self.cols)
      cursor.col = 0
    }
    0x46 => {
      // CPL — Cursor Previous Line
      let n = param(0, 1)
      cursor.move_by(-n, 0, self.rows, self.cols)
      cursor.col = 0
    }
    0x47 => {
      // CHA — Cursor Horizontal Absolute
      let n = param(0, 1)
      cursor.col = (n - 1).clamp(min=0, max=self.cols - 1)
      cursor.wrap_pending = false
    }
    0x48 => {
      // CUP — Cursor Position
      let row = param(0, 1)
      let col = param(1, 1)
      cursor.move_to(row - 1, col - 1, self.rows, self.cols)
    }
    0x49 => {
      // CHT — Cursor Forward Tabulation
      let n = param(0, 1)
      for _i in 0..<n {
        let mut next_col = cursor.col + 1
        while next_col < self.cols {
          if self.tab_stops[next_col] {
            break
          }
          next_col += 1
        }
        cursor.col = next_col.clamp(min=0, max=self.cols - 1)
      }
      cursor.wrap_pending = false
    }
    0x4A => {
      // ED — Erase in Display
      let mode = param(0, 0)
      match mode {
        0 => {
          // Erase from cursor to end of screen
          grid.clear_cells(cursor.row, cursor.col, self.cols)
          grid.clear_rows(cursor.row + 1, self.rows)
        }
        1 => {
          // Erase from start of screen to cursor
          grid.clear_rows(0, cursor.row)
          grid.clear_cells(cursor.row, 0, cursor.col + 1)
        }
        2 => grid.clear() // Erase entire screen
        3 => {
          // Erase entire screen and scrollback
          grid.clear()
          self.screen.scrollback.clear()
        }
        _ => ()
      }
    }
    0x4B => {
      // EL — Erase in Line
      let mode = param(0, 0)
      match mode {
        0 => grid.clear_cells(cursor.row, cursor.col, self.cols)
        1 => grid.clear_cells(cursor.row, 0, cursor.col + 1)
        2 => grid.clear_cells(cursor.row, 0, self.cols)
        _ => ()
      }
    }
    0x4C => {
      // IL — Insert Lines
      let n = param(0, 1)
      grid.insert_lines(cursor.row, n)
    }
    0x4D => {
      // DL — Delete Lines
      let n = param(0, 1)
      grid.delete_lines(cursor.row, n)
    }
    0x50 => {
      // DCH — Delete Characters
      let n = param(0, 1)
      grid.delete_cells(cursor.row, cursor.col, n)
    }
    0x53 => {
      // SU — Scroll Up
      let n = param(0, 1)
      self.screen.scroll_up(n)
    }
    0x54 => {
      // SD — Scroll Down
      let n = param(0, 1)
      self.screen.scroll_down(n)
    }
    0x58 => {
      // ECH — Erase Characters
      let n = param(0, 1)
      let end = (cursor.col + n).clamp(min=0, max=self.cols)
      grid.clear_cells(cursor.row, cursor.col, end)
    }
    0x60 => {
      // HPA — Horizontal Position Absolute
      let n = param(0, 1)
      cursor.col = (n - 1).clamp(min=0, max=self.cols - 1)
      cursor.wrap_pending = false
    }
    0x64 => {
      // VPA — Vertical Position Absolute
      let n = param(0, 1)
      cursor.row = (n - 1).clamp(min=0, max=self.rows - 1)
      cursor.wrap_pending = false
    }
    0x66 => {
      // HVP — Horizontal and Vertical Position (same as CUP)
      let row = param(0, 1)
      let col = param(1, 1)
      cursor.move_to(row - 1, col - 1, self.rows, self.cols)
    }
    0x68 =>
      // SM / DECSET — Set Mode
      if is_private {
        self.set_private_mode(cmd.params, true)
      } else {
        self.set_ansi_mode(cmd.params, true)
      }
    0x6C =>
      // RM / DECRST — Reset Mode
      if is_private {
        self.set_private_mode(cmd.params, false)
      } else {
        self.set_ansi_mode(cmd.params, false)
      }
    0x6D =>
      // SGR — Select Graphic Rendition
      self.handle_sgr(cmd.params)
    0x72 => {
      // DECSTBM — Set Scrolling Region
      let top = param(0, 1)
      let bottom = param(1, self.rows)
      grid.set_scroll_region(top - 1, bottom - 1)
      cursor.move_to(0, 0, self.rows, self.cols)
    }
    0x73 =>
      // DECSC / Save Cursor (via CSI s)
      cursor.save()
    0x75 =>
      // DECRC / Restore Cursor (via CSI u)
      cursor.restore()
    0x40 => {
      // ICH — Insert Characters
      let n = param(0, 1)
      grid.insert_cells(cursor.row, cursor.col, n)
    }
    _ => () // Unknown CSI sequence — ignore
  }
}

///|
/// Handle SGR (Select Graphic Rendition) parameters.
fn Terminal::handle_sgr(self : Terminal, params : Array[Int]) -> Unit {
  let cursor = self.screen.active_cursor()
  let pen = cursor.pen
  if params.length() == 0 {
    // SGR with no params = reset
    pen.fg = Default
    pen.bg = Default
    pen.attrs.clear()
    return
  }
  let mut i = 0
  while i < params.length() {
    let p = params[i]
    match p {
      0 => {
        pen.fg = Default
        pen.bg = Default
        pen.attrs.clear()
      }
      1 => pen.attrs.set(attr_bold)
      2 => pen.attrs.set(attr_dim)
      3 => pen.attrs.set(attr_italic)
      4 => pen.attrs.set(attr_underline)
      5 => pen.attrs.set(attr_blink)
      7 => pen.attrs.set(attr_inverse)
      8 => pen.attrs.set(attr_hidden)
      9 => pen.attrs.set(attr_strikethrough)
      21 => pen.attrs.set(attr_double_underline)
      22 => {
        pen.attrs.unset(attr_bold)
        pen.attrs.unset(attr_dim)
      }
      23 => pen.attrs.unset(attr_italic)
      24 => {
        pen.attrs.unset(attr_underline)
        pen.attrs.unset(attr_double_underline)
        pen.attrs.unset(attr_curly_underline)
      }
      25 => pen.attrs.unset(attr_blink)
      27 => pen.attrs.unset(attr_inverse)
      28 => pen.attrs.unset(attr_hidden)
      29 => pen.attrs.unset(attr_strikethrough)
      // Standard foreground colors 30-37
      30 | 31 | 32 | 33 | 34 | 35 | 36 | 37 => pen.fg = Indexed(p - 30)
      38 => {
        // Extended foreground color
        i += 1
        if i < params.length() {
          match params[i] {
            5 => {
              // 256-color
              i += 1
              if i < params.length() {
                pen.fg = Palette(params[i])
              }
            }
            2 =>
              // RGB
              if i + 3 < params.length() {
                pen.fg = Rgb(
                  params[i + 1].to_byte(),
                  params[i + 2].to_byte(),
                  params[i + 3].to_byte(),
                )
                i += 3
              }
            _ => ()
          }
        }
      }
      39 => pen.fg = Default // Default foreground
      // Standard background colors 40-47
      40 | 41 | 42 | 43 | 44 | 45 | 46 | 47 => pen.bg = Indexed(p - 40)
      48 => {
        // Extended background color
        i += 1
        if i < params.length() {
          match params[i] {
            5 => {
              i += 1
              if i < params.length() {
                pen.bg = Palette(params[i])
              }
            }
            2 =>
              if i + 3 < params.length() {
                pen.bg = Rgb(
                  params[i + 1].to_byte(),
                  params[i + 2].to_byte(),
                  params[i + 3].to_byte(),
                )
                i += 3
              }
            _ => ()
          }
        }
      }
      49 => pen.bg = Default // Default background
      // Bright foreground colors 90-97
      90 | 91 | 92 | 93 | 94 | 95 | 96 | 97 => pen.fg = Indexed(p - 90 + 8)
      // Bright background colors 100-107
      100 | 101 | 102 | 103 | 104 | 105 | 106 | 107 =>
        pen.bg = Indexed(p - 100 + 8)
      _ => () // Unknown SGR parameter
    }
    i += 1
  }
}

///|
/// Handle DECSET/DECRST private mode changes.
fn Terminal::set_private_mode(
  self : Terminal,
  params : Array[Int],
  enable : Bool,
) -> Unit {
  for i in 0..<params.length() {
    match params[i] {
      1 => self.modes.cursor_keys_application = enable // DECCKM
      3 => {
        // DECCOLM — 132/80 column mode
        self.modes.column_132 = enable
        // Switching column mode clears the screen and resets cursor
        self.screen.active_grid().clear()
        self.screen.active_cursor().move_to(0, 0, self.rows, self.cols)
      }
      4 => self.modes.smooth_scroll = enable // DECSCLM
      5 => self.modes.reverse_video = enable // DECSCNM
      6 => {
        // DECOM — Origin mode
        self.modes.origin_mode = enable
        self.screen.active_cursor().move_to(0, 0, self.rows, self.cols)
      }
      7 => self.modes.auto_wrap = enable // DECAWM
      8 => self.modes.auto_repeat = enable // DECARM
      25 => {
        // DECTCEM — Show/hide cursor
        self.modes.cursor_visible = enable
        self.screen.active_cursor().visible = enable
      }
      47 | 1047 => {
        // Alternate screen buffer (without save/restore cursor)
        if enable {
          self.screen.switch_to_alternate()
        } else {
          self.screen.switch_to_primary()
        }
        self.modes.alternate_screen = enable
      }
      1048 =>
        // Save/restore cursor
        if enable {
          self.screen.active_cursor().save()
        } else {
          self.screen.active_cursor().restore()
        }
      1049 => {
        // Alternate screen buffer with save/restore cursor
        if enable {
          self.screen.active_cursor().save()
          self.screen.switch_to_alternate()
        } else {
          self.screen.switch_to_primary()
          self.screen.active_cursor().restore()
        }
        self.modes.alternate_screen = enable
      }
      1000 | 1002 | 1003 => self.modes.mouse_tracking = enable
      1006 => self.modes.mouse_sgr_mode = enable
      1004 => self.modes.focus_tracking = enable
      2004 => self.modes.bracketed_paste = enable
      _ => () // Unknown private mode
    }
  }
}

///|
/// Handle ANSI mode set/reset (SM/RM without '?').
fn Terminal::set_ansi_mode(
  self : Terminal,
  params : Array[Int],
  enable : Bool,
) -> Unit {
  for i in 0..<params.length() {
    match params[i] {
      4 => self.modes.insert_mode = enable // IRM
      20 => self.modes.linefeed_mode = enable // LNM
      _ => ()
    }
  }
}

///|
/// Handle an ESC sequence.
fn Terminal::handle_esc(self : Terminal, cmd : @vt_parser.EscCommand) -> Unit {
  let final_byte = cmd.final_byte.to_int()
  let cursor = self.screen.active_cursor()
  if cmd.intermediates.length() == 0 {
    match final_byte {
      0x37 => cursor.save() // DECSC — Save Cursor
      0x38 => cursor.restore() // DECRC — Restore Cursor
      0x44 => {
        // IND — Index (move cursor down, scroll if at bottom)
        let grid = self.screen.active_grid()
        if cursor.row == grid.scroll_bottom {
          self.screen.scroll_up(1)
        } else if cursor.row < self.rows - 1 {
          cursor.row += 1
        }
      }
      0x45 => {
        // NEL — Next Line
        let grid = self.screen.active_grid()
        cursor.col = 0
        if cursor.row == grid.scroll_bottom {
          self.screen.scroll_up(1)
        } else if cursor.row < self.rows - 1 {
          cursor.row += 1
        }
      }
      0x48 =>
        // HTS — Horizontal Tab Set
        if cursor.col < self.cols {
          self.tab_stops[cursor.col] = true
        }
      0x4D => {
        // RI — Reverse Index (move cursor up, scroll down if at top)
        let grid = self.screen.active_grid()
        if cursor.row == grid.scroll_top {
          self.screen.scroll_down(1)
        } else if cursor.row > 0 {
          cursor.row -= 1
        }
      }
      0x63 =>
        // RIS — Full Reset
        self.reset()
      _ => ()
    }
  } else if cmd.intermediates.length() == 1 {
    let intermediate = cmd.intermediates[0].to_int()
    if intermediate == 0x28 {
      // G0 charset designation
      match final_byte {
        0x42 => cursor.charset_g0 = Ascii // ASCII
        0x30 => cursor.charset_g0 = DecSpecialGraphics // DEC Special Graphics
        0x41 => cursor.charset_g0 = Uk // UK
        _ => ()
      }
    } else if intermediate == 0x29 {
      // G1 charset designation
      match final_byte {
        0x42 => cursor.charset_g1 = Ascii
        0x30 => cursor.charset_g1 = DecSpecialGraphics
        0x41 => cursor.charset_g1 = Uk
        _ => ()
      }
    } else if intermediate == 0x23 {
      // DEC specific
      match final_byte {
        0x38 => {
          // DECALN — Screen Alignment Pattern (fill with 'E')
          let grid = self.screen.active_grid()
          for r in 0..<self.rows {
            for c in 0..<self.cols {
              grid.set_cell(r, c, 'E', Cell::empty())
            }
          }
        }
        _ => ()
      }
    }
  }
}

///|
/// Handle an OSC (Operating System Command) sequence.
fn Terminal::handle_osc(self : Terminal, cmd : @vt_parser.OscCommand) -> Unit {
  // Parse the OSC command number from the data
  // Format: <number> ; <data>
  let data = cmd.data
  let mut num = 0
  let mut i = 0
  // Parse the number
  while i < data.length() {
    let b = data[i].to_int()
    if b >= 0x30 && b <= 0x39 {
      num = num * 10 + (b - 0x30)
      i += 1
    } else if b == 0x3B {
      // ';' separator
      i += 1
      break
    } else {
      break
    }
  }
  // Extract the string data after the separator
  let buf = StringBuilder::new()
  while i < data.length() {
    buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  let text = buf.to_string()
  match num {
    0 | 2 => self.title = text // Set window title
    1 => () // Set icon name (usually ignored)
    _ => () // Other OSC commands
  }
}

///|
/// Full terminal reset.
pub fn Terminal::reset(self : Terminal) -> Unit {
  self.screen.switch_to_primary()
  self.screen.primary.clear()
  self.screen.alternate.clear()
  self.screen.primary.reset_scroll_region()
  self.screen.alternate.reset_scroll_region()
  self.screen.scrollback.clear()
  self.screen.primary_cursor.move_to(0, 0, self.rows, self.cols)
  self.screen.alternate_cursor.move_to(0, 0, self.rows, self.cols)
  self.modes = TermModes::default()
  // Reset tab stops
  for i in 0..<self.cols {
    self.tab_stops[i] = i % 8 == 0
  }
  self.title = ""
}

///|
/// Resize the terminal.
pub fn Terminal::resize(
  self : Terminal,
  new_rows : Int,
  new_cols : Int,
) -> Unit {
  self.screen.resize(new_rows, new_cols)
  self.rows = new_rows
  self.cols = new_cols
  // Resize tab stops
  let old_len = self.tab_stops.length()
  if new_cols > old_len {
    for i in 0..<(new_cols - old_len) {
      self.tab_stops.push((old_len + i) % 8 == 0)
    }
  } else if new_cols < old_len {
    for _i in 0..<(old_len - new_cols) {
      self.tab_stops.pop() |> ignore
    }
  }
}

///|
/// Get the terminal title.
pub fn Terminal::get_title(self : Terminal) -> String {
  self.title
}

///|
/// Get the active screen's grid for rendering.
pub fn Terminal::get_grid(self : Terminal) -> Grid {
  self.screen.active_grid()
}

///|
/// Get the active cursor for rendering.
pub fn Terminal::get_cursor(self : Terminal) -> Cursor {
  self.screen.active_cursor()
}

///|
/// Get the terminal modes.
pub fn Terminal::get_modes(self : Terminal) -> TermModes {
  self.modes
}

///|
/// Get the scrollback buffer.
pub fn Terminal::get_scrollback(self : Terminal) -> Scrollback {
  self.screen.scrollback
}
