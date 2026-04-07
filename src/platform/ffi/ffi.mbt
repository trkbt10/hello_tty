///|
/// Initialize the platform windowing system.
/// Returns 0 on success, -1 on failure.
pub extern "C" fn platform_init() -> Int = "hello_tty_platform_init"

///|
/// Create a new window with the given dimensions.
/// Returns a window handle (>0) or -1 on failure.
pub extern "C" fn platform_create_window(width : Int, height : Int) -> Int = "hello_tty_platform_create_window"

///|
/// Set the window title.
#borrow(title)
pub extern "C" fn platform_set_title(
  window : Int,
  title : Bytes,
  title_len : Int,
) = "hello_tty_platform_set_title"

///|
/// Poll for platform events.
/// Returns event type encoded as Int:
///   0 = no event
///   1 = key press (key code in event_buf[0], modifiers in event_buf[1])
///   2 = window resize (width in event_buf[0], height in event_buf[1])
///   3 = window close
///   4 = focus gained
///   5 = focus lost
///   6 = mouse event
///  -1 = error
#borrow(event_buf)
pub extern "C" fn platform_poll_event(
  window : Int,
  event_buf : FixedArray[Int],
) -> Int = "hello_tty_platform_poll_event"

///|
/// Request the window to redraw.
pub extern "C" fn platform_request_redraw(window : Int) = "hello_tty_platform_request_redraw"

///|
/// Get the Vulkan surface for the window.
/// Returns a VkSurfaceKHR handle (as opaque Int) or 0 on failure.
pub extern "C" fn platform_get_vulkan_surface(window : Int) -> Int = "hello_tty_platform_get_vulkan_surface"

///|
/// Get the DPI scale factor for the window.
/// Returns scale * 100 (e.g., 200 for 2x Retina).
pub extern "C" fn platform_get_dpi_scale(window : Int) -> Int = "hello_tty_platform_get_dpi_scale"

///|
/// Destroy a window.
pub extern "C" fn platform_destroy_window(window : Int) = "hello_tty_platform_destroy_window"

///|
/// Shut down the platform windowing system.
pub extern "C" fn platform_shutdown() = "hello_tty_platform_shutdown"

///|
/// Copy text to the system clipboard.
#borrow(text)
pub extern "C" fn platform_clipboard_set(text : Bytes, len : Int) -> Int = "hello_tty_platform_clipboard_set"

///|
/// Get text from the system clipboard.
/// Writes into buf, returns length of text, or -1 on error.
#borrow(buf)
pub extern "C" fn platform_clipboard_get(
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "hello_tty_platform_clipboard_get"
