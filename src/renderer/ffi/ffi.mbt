///|
/// Initialize the GPU backend (Vulkan instance, device, swapchain).
/// surface_handle: platform-specific surface handle (or 0 for headless).
/// Returns 0 on success, -1 on failure.
pub extern "C" fn gpu_init(
  surface_handle_lo : Int,
  surface_handle_hi : Int,
  width : Int,
  height : Int,
) -> Int = "hello_tty_gpu_init_i32"

///|
/// Resize the swapchain after a window resize.
pub extern "C" fn gpu_resize(width : Int, height : Int) -> Int = "hello_tty_gpu_resize"

///|
/// Destroy all GPU resources.
pub extern "C" fn gpu_shutdown() = "hello_tty_gpu_shutdown"

///|
/// Create or recreate the glyph atlas texture on the GPU.
pub extern "C" fn gpu_atlas_create(width : Int, height : Int) -> Int = "hello_tty_gpu_atlas_create"

///|
/// Upload a rectangular region of RGBA pixel data into the atlas texture.
#borrow(data)
pub extern "C" fn gpu_atlas_upload(
  x : Int,
  y : Int,
  region_w : Int,
  region_h : Int,
  data : FixedArray[Byte],
  data_len : Int,
) -> Int = "hello_tty_gpu_atlas_upload"

///|
/// Initialize the font engine.
/// font_path: UTF-8 path to .ttf/.otf, or pass empty bytes + len=0 for system default.
#borrow(font_path)
pub extern "C" fn font_init(
  font_path : Bytes,
  font_path_len : Int,
  font_size : Int,
) -> Int = "hello_tty_font_init"

///|
/// Rasterize a single glyph.
/// metrics_out: [width, height, bearing_x, bearing_y, advance]
/// bitmap_out: pre-allocated buffer for grayscale (A8) bitmap data.
/// Returns actual bitmap size in bytes, or -1 on failure.
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
/// Get font metrics.
/// metrics_out: [cell_width, cell_height, ascent, descent]
#borrow(metrics_out)
pub extern "C" fn font_get_metrics(metrics_out : FixedArray[Int]) -> Int = "hello_tty_font_get_metrics"

///|
/// Shut down the font engine.
pub extern "C" fn font_shutdown() = "hello_tty_font_shutdown"

///|
/// Begin a new frame. Acquires the next swapchain image.
pub extern "C" fn gpu_frame_begin() -> Int = "hello_tty_gpu_frame_begin"

///|
/// Set the clear color for the frame.
pub extern "C" fn gpu_frame_clear(r : Byte, g : Byte, b : Byte, a : Byte) = "hello_tty_gpu_frame_clear"

///|
/// Upload and draw cell quad vertices.
/// vertices: packed float array, 12 floats per vertex.
/// vertex_count: number of vertices (multiple of 6 for quads).
#borrow(vertices)
pub extern "C" fn gpu_draw_cells(
  vertices : FixedArray[Float],
  vertex_count : Int,
) -> Int = "hello_tty_gpu_draw_cells_fa"

///|
/// Draw the cursor.
pub extern "C" fn gpu_draw_cursor(
  x : Float,
  y : Float,
  w : Float,
  h : Float,
  r : Byte,
  g : Byte,
  b : Byte,
  a : Byte,
  style : Int,
) = "hello_tty_gpu_draw_cursor"

///|
/// End the frame and present.
pub extern "C" fn gpu_frame_end() -> Int = "hello_tty_gpu_frame_end"
