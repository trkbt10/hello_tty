///|
/// Result of classifying a key event.
/// This is the single source of truth for "what should happen with this key."
/// Platform adapters (Swift, GTK) query this and act accordingly.
pub(all) enum KeyClassification {
  /// Send the key directly to the PTY as an escape sequence.
  /// The adapter should call translate_key_input and write the result.
  DirectToPty
  /// Forward to the platform's IME / input method for composition.
  /// The adapter should pass the raw event to inputContext.
  ForwardToIme
  /// Copy selected text to clipboard.
  ClipboardCopy
  /// Paste clipboard text to PTY.
  ClipboardPaste
} derive(Show, Eq)

///|
/// Modifier key bitmask constants.
pub let mod_shift : Int = 1

///|
pub let mod_ctrl : Int = 2

///|
pub let mod_alt : Int = 4

///|
pub let mod_super : Int = 8
