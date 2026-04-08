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
  // ---- Panel operations ----
  /// Split the focused panel to the right.
  SplitRight
  /// Split the focused panel downward.
  SplitDown
  /// Close the focused panel, or close the tab if last panel.
  ClosePanel
  /// Move focus to the neighboring panel in a direction.
  /// 0=Up, 1=Down, 2=Left, 3=Right
  FocusDirection(Int)
  /// Focus next split pane (by creation order).
  NextSplit
  /// Focus previous split pane (by creation order).
  PrevSplit
  // ---- Tab operations ----
  /// Create a new tab.
  NewTab
  /// Switch to the next tab.
  NextTab
  /// Switch to the previous tab.
  PrevTab
  /// Go to tab by 0-based index. Index -1 means "last tab".
  GotoTab(Int)
  /// Cut selected text to clipboard (copy + clear selection).
  ClipboardCut
  /// Select all text in the current terminal.
  SelectAll
  /// Open find-in-terminal search bar.
  FindInTerminal
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

///|
/// A key combination used as the lookup key in the keybinding table.
/// Composed of a key code (Unicode scalar or function key code) and
/// a modifier bitmask (shift|ctrl|alt|super).
pub(all) struct KeyCombo {
  key_code : Int
  modifiers : Int
} derive(Show, Eq, Hash)
