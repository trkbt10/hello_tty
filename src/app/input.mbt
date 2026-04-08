///|
/// Translate a platform key event into the byte sequence that should
/// be sent to the PTY (shell).
///
/// This handles:
/// - Normal ASCII keys
/// - Ctrl+key combinations (Ctrl+C = 0x03, Ctrl+D = 0x04, etc.)
/// - Arrow keys (with application cursor key mode support)
/// - Function keys
/// - Special keys (Home, End, Insert, Delete, Page Up/Down)
pub fn translate_key_input(
  key_code : Int,
  modifiers : Int,
  cursor_keys_application : Bool,
) -> String {
  let ctrl = modifiers.land(@platform.mod_ctrl) != 0
  let shift = modifiers.land(@platform.mod_shift) != 0
  let alt = modifiers.land(@platform.mod_alt) != 0
  // Ctrl+key → control code
  // Case 1: Platform gives us the letter (key_code 0x40-0x7E)
  if ctrl && key_code >= 0x40 && key_code <= 0x7E {
    let ctrl_code = key_code.land(0x1F)
    return ctrl_code.unsafe_to_char().to_string()
  }
  // Case 2: Platform gives us the raw control code (key_code 0x00-0x1F)
  if ctrl && key_code >= 0x00 && key_code <= 0x1F {
    return key_code.unsafe_to_char().to_string()
  }
  // Alt wraps the key in ESC prefix
  if alt && key_code >= 0x20 && key_code <= 0x7E {
    return "\u001b" + key_code.unsafe_to_char().to_string()
  }
  // Arrow keys
  // Using common key code constants (platform adapter should normalize these)
  match key_code {
    // Up arrow
    0xF700 => if cursor_keys_application { "\u001bOA" } else { "\u001b[A" }
    // Down arrow
    0xF701 => if cursor_keys_application { "\u001bOB" } else { "\u001b[B" }
    // Right arrow
    0xF703 => if cursor_keys_application { "\u001bOC" } else { "\u001b[C" }
    // Left arrow
    0xF702 => if cursor_keys_application { "\u001bOD" } else { "\u001b[D" }
    // Home
    0xF729 => if shift { "\u001b[1;2H" } else { "\u001b[H" }
    // End
    0xF72B => if shift { "\u001b[1;2F" } else { "\u001b[F" }
    // Insert
    0xF727 => "\u001b[2~"
    // Delete
    0xF728 => "\u001b[3~"
    // Page Up
    0xF72C => "\u001b[5~"
    // Page Down
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
    // Enter/Return
    0x0D => "\r"
    // Escape
    0x1B => "\u001b"
    // Backspace
    0x08 | 0x7F => "\u007f"
    // Normal printable ASCII
    _ =>
      if key_code >= 0x20 && key_code <= 0x7E {
        key_code.unsafe_to_char().to_string()
      } else {
        "" // Unknown key — produce nothing
      }
  }
}
