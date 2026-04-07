///|
/// Keyboard modifier flags.
pub let mod_shift : Int = 1

///|
pub let mod_ctrl : Int = 2

///|
pub let mod_alt : Int = 4

///|
pub let mod_super : Int = 8

///|
/// Platform error type.
pub suberror PlatformError {
  InitFailed(String)
  WindowCreationFailed(String)
  ClipboardError(String)
}

///|
/// A window handle wrapping the platform-specific identifier.
pub struct WindowHandle {
  id : Int
} derive(Show)
