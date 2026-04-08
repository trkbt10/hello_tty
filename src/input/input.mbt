///|
/// Classify a key event — the single source of truth for input routing.
///
/// Platform adapters call this to determine what to do with a key event.
/// The result tells the adapter whether to:
///   - Send directly to PTY (special keys, ctrl+key)
///   - Forward to IME for composition (printable characters)
///   - Handle as a UI action (split, tab, clipboard, etc.)
///
/// Classification order:
///   1. IME composing → ForwardToIme (all keys go to IME)
///   2. Cmd+key → keymap table lookup (configurable actions)
///   3. Ctrl+key → DirectToPty (terminal control characters)
///   4. Function keys → DirectToPty (escape sequences)
///   5. Everything else → ForwardToIme (printable text via IME)
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
  // If IME has marked text, ALL keys go to IME
  // (including backspace to delete composed chars)
  if has_marked_text {
    return ForwardToIme
  }
  let is_super = modifiers.land(mod_super) != 0
  let is_ctrl = modifiers.land(mod_ctrl) != 0
  // ---- Cmd+key: look up in the keybinding table ----
  if is_super {
    // Build the lookup modifiers — only include the modifiers that the
    // keymap cares about (super is always set, plus shift/alt/ctrl).
    match global_keymap.lookup(key_code, modifiers) {
      Some(action) => return action
      None => ()
    }
  }
  // ---- Ctrl+key → directly to PTY ----
  // Terminal control characters: Ctrl+C=SIGINT, Ctrl+D=EOF, etc.
  // These must never be intercepted by the app — always sent to PTY.
  if is_ctrl {
    return DirectToPty
  }
  // ---- Function keys (arrows, F1-F12, Home, End, etc.) → directly to PTY ----
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
///   - Ctrl+key (both letter form 0x40-0x7E and raw control code 0x00-0x1F)
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
  // Case 1: Platform gives us the letter (key_code 0x40-0x7E).
  //   e.g., Ctrl+C as key_code=0x63 ('c') → compute 0x63 & 0x1F = 0x03.
  if ctrl && key_code >= 0x40 && key_code <= 0x7E {
    let ctrl_code = key_code.land(0x1F)
    return ctrl_code.unsafe_to_char().to_string()
  }
  // Case 2: Platform gives us the raw control code directly (key_code 0x00-0x1F).
  //   e.g., macOS charactersIgnoringModifiers with Ctrl held returns 0x03 for Ctrl+C.
  //   Just pass it through — it's already the correct byte.
  if ctrl && key_code >= 0x00 && key_code <= 0x1F {
    return key_code.unsafe_to_char().to_string()
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
