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
