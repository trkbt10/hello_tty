///|
/// Classify a key event — the single source of truth for input routing.
///
/// Platform adapters call this to determine what to do with a key event.
/// The result tells the adapter whether to:
///   - Send directly to PTY (special keys, ctrl+key)
///   - Forward to IME for composition (printable characters)
///   - Handle as clipboard operation (cmd+c/v)
///
/// Parameters:
///   key_code: Unicode scalar value (or function key code 0xF700+)
///   modifiers: Bitmask (1=shift, 2=ctrl, 4=alt, 8=super/cmd)
///   has_marked_text: Whether IME is currently composing
pub fn classify_key(
  key_code : Int,
  modifiers : Int,
  has_marked_text : Bool,
) -> KeyClassification {
  let is_super = modifiers.land(mod_super) != 0
  let is_ctrl = modifiers.land(mod_ctrl) != 0
  // Cmd+C → copy, Cmd+V → paste
  if is_super {
    if key_code == 0x63 {
      // 'c'
      return ClipboardCopy
    }
    if key_code == 0x76 {
      // 'v'
      return ClipboardPaste
    }
  }
  // If IME has marked text, ALL keys go to IME
  // (including backspace to delete composed chars)
  if has_marked_text {
    return ForwardToIme
  }
  // Ctrl+key → directly to PTY
  if is_ctrl {
    return DirectToPty
  }
  // Function keys (arrows, F1-F12, Home, End, etc.) → directly to PTY
  if key_code >= 0xF700 && key_code <= 0xF8FF {
    return DirectToPty
  }
  // Everything else → IME handles it
  // IME will either compose or call insertText for direct input.
  // Enter (0x0D), Backspace (0x7F), Tab (0x09) etc. go through IME
  // and come back via doCommand(by:) / insertText.
  ForwardToIme
}

///|
/// Translate a key event into the escape sequence to send to the PTY.
///
/// This is the authoritative mapping from key codes to terminal escape
/// sequences (CSI, SS3, etc.). Handles:
///   - Normal ASCII keys
///   - Ctrl+key (Ctrl+C = 0x03, etc.)
///   - Alt+key (ESC prefix)
///   - Arrow keys (with application cursor key mode)
///   - Function keys (F1-F12)
///   - Special keys (Home, End, Insert, Delete, Page Up/Down)
pub fn translate_key_input(
  key_code : Int,
  modifiers : Int,
  cursor_keys_application : Bool,
) -> String {
  let ctrl = modifiers.land(mod_ctrl) != 0
  let shift = modifiers.land(mod_shift) != 0
  let alt = modifiers.land(mod_alt) != 0
  // Ctrl+key → control code
  if ctrl && key_code >= 0x40 && key_code <= 0x7E {
    let ctrl_code = key_code.land(0x1F)
    return ctrl_code.unsafe_to_char().to_string()
  }
  // Alt → ESC prefix
  if alt && key_code >= 0x20 && key_code <= 0x7E {
    return "\u001b" + key_code.unsafe_to_char().to_string()
  }
  match key_code {
    // Arrow keys
    0xF700 => if cursor_keys_application { "\u001bOA" } else { "\u001b[A" }
    0xF701 => if cursor_keys_application { "\u001bOB" } else { "\u001b[B" }
    0xF703 => if cursor_keys_application { "\u001bOC" } else { "\u001b[C" }
    0xF702 => if cursor_keys_application { "\u001bOD" } else { "\u001b[D" }
    // Home / End
    0xF729 => if shift { "\u001b[1;2H" } else { "\u001b[H" }
    0xF72B => if shift { "\u001b[1;2F" } else { "\u001b[F" }
    // Insert / Delete / Page Up / Page Down
    0xF727 => "\u001b[2~"
    0xF728 => "\u001b[3~"
    0xF72C => "\u001b[5~"
    0xF72D => "\u001b[6~"
    // F1-F12
    0xF704 => "\u001bOP"
    0xF705 => "\u001bOQ"
    0xF706 => "\u001bOR"
    0xF707 => "\u001bOS"
    0xF708 => "\u001b[15~"
    0xF709 => "\u001b[17~"
    0xF70A => "\u001b[18~"
    0xF70B => "\u001b[19~"
    0xF70C => "\u001b[20~"
    0xF70D => "\u001b[21~"
    0xF70E => "\u001b[23~"
    0xF70F => "\u001b[24~"
    // Tab
    0x09 => if shift { "\u001b[Z" } else { "\t" }
    // Enter
    0x0D => "\r"
    // Escape
    0x1B => "\u001b"
    // Backspace
    0x08 | 0x7F => "\u007f"
    // Printable ASCII
    _ =>
      if key_code >= 0x20 && key_code <= 0x7E {
        key_code.unsafe_to_char().to_string()
      } else {
        ""
      }
  }
}
