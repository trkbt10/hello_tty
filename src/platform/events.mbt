///|
/// Platform events delivered to the application layer.
pub(all) enum PlatformEvent {
  /// No event available.
  None
  /// A key was pressed. key_code is platform-specific, modifiers are bitflags.
  KeyPress(key_code~ : Int, modifiers~ : Int)
  /// The window was resized to new pixel dimensions.
  Resize(width~ : Int, height~ : Int)
  /// The window close button was pressed.
  CloseRequested
  /// The window gained keyboard focus.
  FocusGained
  /// The window lost keyboard focus.
  FocusLost
  /// A mouse event occurred.
  MouseEvent(x~ : Int, y~ : Int, button~ : Int, kind~ : Int)
  /// An error occurred.
  Error(String)
} derive(Show)
