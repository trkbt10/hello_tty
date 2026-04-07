///|
/// The Platform layer manages native windowing, input, and clipboard.
/// It wraps the FFI calls to the platform-specific adapter.
pub struct Platform {
  mut initialized : Bool
  mut window : WindowHandle?
  /// Event buffer for poll_event FFI calls.
  event_buf : FixedArray[Int]
}

///|
pub fn Platform::new() -> Platform {
  { initialized: false, window: None, event_buf: FixedArray::make(8, 0) }
}

///|
/// Initialize the platform windowing system.
pub fn Platform::init(self : Platform) -> Unit raise PlatformError {
  let ret = @ffi.platform_init()
  if ret < 0 {
    raise InitFailed("Failed to initialize platform windowing system")
  }
  self.initialized = true
}

///|
/// Create a window with the given pixel dimensions.
pub fn Platform::create_window(
  self : Platform,
  width : Int,
  height : Int,
) -> WindowHandle raise PlatformError {
  let id = @ffi.platform_create_window(width, height)
  if id < 0 {
    raise WindowCreationFailed("Failed to create platform window")
  }
  let handle : WindowHandle = { id, }
  self.window = Some(handle)
  handle
}

///|
/// Set the window title.
pub fn Platform::set_title(self : Platform, title : String) -> Unit {
  match self.window {
    Some(w) => {
      let bytes = @utf8.encode(title)
      @ffi.platform_set_title(w.id, bytes, bytes.length())
    }
    None => ()
  }
}

///|
/// Poll for platform events (non-blocking).
pub fn Platform::poll_event(self : Platform) -> PlatformEvent {
  match self.window {
    None => None
    Some(w) => {
      // Clear event buffer
      for i in 0..<self.event_buf.length() {
        self.event_buf[i] = 0
      }
      let event_type = @ffi.platform_poll_event(w.id, self.event_buf)
      match event_type {
        0 => None
        1 => KeyPress(key_code=self.event_buf[0], modifiers=self.event_buf[1])
        2 => Resize(width=self.event_buf[0], height=self.event_buf[1])
        3 => CloseRequested
        4 => FocusGained
        5 => FocusLost
        6 =>
          MouseEvent(
            x=self.event_buf[0],
            y=self.event_buf[1],
            button=self.event_buf[2],
            kind=self.event_buf[3],
          )
        _ => Error("Unknown platform event type: " + event_type.to_string())
      }
    }
  }
}

///|
/// Request a window redraw.
pub fn Platform::request_redraw(self : Platform) -> Unit {
  match self.window {
    Some(w) => @ffi.platform_request_redraw(w.id)
    None => ()
  }
}

///|
/// Get the DPI scale factor.
pub fn Platform::get_dpi_scale(self : Platform) -> Float {
  match self.window {
    Some(w) => Float::from_int(@ffi.platform_get_dpi_scale(w.id)) / 100.0
    None => 1.0
  }
}

///|
/// Get the Vulkan surface handle for GPU rendering.
pub fn Platform::get_vulkan_surface(self : Platform) -> Int {
  match self.window {
    Some(w) => @ffi.platform_get_vulkan_surface(w.id)
    None => 0
  }
}

///|
/// Copy text to the system clipboard.
pub fn Platform::clipboard_set(
  self : Platform,
  text : String,
) -> Unit raise PlatformError {
  ignore(self)
  let bytes = @utf8.encode(text)
  let ret = @ffi.platform_clipboard_set(bytes, bytes.length())
  if ret < 0 {
    raise ClipboardError("Failed to set clipboard text")
  }
}

///|
/// Get text from the system clipboard.
pub fn Platform::clipboard_get(self : Platform) -> String raise PlatformError {
  ignore(self)
  let buf : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  let len = @ffi.platform_clipboard_get(buf, 65536)
  if len < 0 {
    raise ClipboardError("Failed to get clipboard text")
  }
  // Read directly from FixedArray into string
  let sb = StringBuilder::new()
  for i in 0..<len {
    sb.write_char(buf[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Destroy the window and shut down the platform.
pub fn Platform::shutdown(self : Platform) -> Unit {
  match self.window {
    Some(w) => {
      @ffi.platform_destroy_window(w.id)
      self.window = None
    }
    None => ()
  }
  if self.initialized {
    @ffi.platform_shutdown()
    self.initialized = false
  }
}
