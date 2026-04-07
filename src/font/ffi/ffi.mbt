///|
/// Font rasterization FFI — platform-specific font engine.
/// CoreText on macOS, FreeType on Linux.

///|
#borrow(font_path)
pub extern "C" fn font_init(
  font_path : Bytes,
  font_path_len : Int,
  font_size : Int,
) -> Int = "hello_tty_font_init"

///|
#borrow(metrics_out)
#borrow(bitmap_out)
pub extern "C" fn font_rasterize(
  codepoint : Int,
  bold : Int,
  italic : Int,
  metrics_out : FixedArray[Int],
  bitmap_out : FixedArray[Byte],
  bitmap_max_len : Int,
) -> Int = "hello_tty_font_rasterize"

///|
#borrow(metrics_out)
pub extern "C" fn font_get_metrics(
  metrics_out : FixedArray[Int],
) -> Int = "hello_tty_font_get_metrics"

///|
pub extern "C" fn font_shutdown() = "hello_tty_font_shutdown"
