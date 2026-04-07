///|
/// GPU rendering FFI — wgpu backend.
/// Font FFI is in src/font/ffi/.

///|
pub extern "C" fn gpu_init(
  surface_handle_lo : Int,
  surface_handle_hi : Int,
  width : Int,
  height : Int,
) -> Int = "hello_tty_gpu_init_i32"

///|
pub extern "C" fn gpu_resize(width : Int, height : Int) -> Int = "hello_tty_gpu_resize"

///|
pub extern "C" fn gpu_shutdown() = "hello_tty_gpu_shutdown"

///|
pub extern "C" fn gpu_atlas_create(width : Int, height : Int) -> Int = "hello_tty_gpu_atlas_create"

///|
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
pub extern "C" fn gpu_frame_begin() -> Int = "hello_tty_gpu_frame_begin"

///|
pub extern "C" fn gpu_frame_clear(r : Byte, g : Byte, b : Byte, a : Byte) = "hello_tty_gpu_frame_clear"

///|
#borrow(vertices)
pub extern "C" fn gpu_draw_cells(
  vertices : FixedArray[Float],
  vertex_count : Int,
) -> Int = "hello_tty_gpu_draw_cells_fa"

///|
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
pub extern "C" fn gpu_frame_end() -> Int = "hello_tty_gpu_frame_end"
