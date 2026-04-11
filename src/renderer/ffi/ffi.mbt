///|
/// GPU rendering FFI — wgpu backend (multi-surface).
///
/// Device-level resources (instance, adapter, device, queue, pipelines, atlas)
/// are shared. Each surface (one per panel) has its own swapchain and frame state.
/// surface_id is an opaque integer handle returned by gpu_surface_create.

///|
/// Initialize the GPU device (shared resources). No surface needed.
pub extern "C" fn gpu_init_device() -> Int = "hello_tty_gpu_init_device_mbt"

///|
/// Create a new GPU surface from a platform handle.
/// Returns surface_id (>= 0) on success, -1 on failure.
pub extern "C" fn gpu_surface_create(
  surface_handle_lo : Int,
  surface_handle_hi : Int,
  width : Int,
  height : Int,
) -> Int = "hello_tty_gpu_surface_create_i32"

///|
/// Destroy a surface by ID.
pub extern "C" fn gpu_surface_destroy(surface_id : Int) = "hello_tty_gpu_surface_destroy"

///|
/// Resize a surface's swapchain.
pub extern "C" fn gpu_surface_resize(
  surface_id : Int,
  width : Int,
  height : Int,
) -> Int = "hello_tty_gpu_surface_resize"

///|
/// Shutdown the GPU device and all surfaces.
pub extern "C" fn gpu_shutdown() = "hello_tty_gpu_shutdown"

///|
/// Create or recreate the shared glyph atlas texture.
pub extern "C" fn gpu_atlas_create(width : Int, height : Int) -> Int = "hello_tty_gpu_atlas_create"

///|
/// Upload a region of RGBA pixel data into the shared atlas texture.
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
/// Set the clear color for the next frame on a surface.
pub extern "C" fn gpu_frame_clear(
  surface_id : Int,
  r : Byte,
  g : Byte,
  b : Byte,
  a : Byte,
) = "hello_tty_gpu_frame_clear"

///|
/// Begin a new frame on a surface.
pub extern "C" fn gpu_frame_begin(surface_id : Int) -> Int = "hello_tty_gpu_frame_begin"

///|
/// Set viewport and scissor rect for sub-region rendering (multi-panel).
/// Coordinates are in pixels relative to the surface.
/// Also updates the uniform buffer so the vertex shader maps positions
/// relative to the panel's own coordinate space.
pub extern "C" fn gpu_set_viewport(
  surface_id : Int,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) = "hello_tty_gpu_set_viewport"

///|
/// Upload cell quad vertex data and draw on a surface.
#borrow(vertices)
pub extern "C" fn gpu_draw_cells(
  surface_id : Int,
  vertices : FixedArray[Float],
  vertex_count : Int,
) -> Int = "hello_tty_gpu_draw_cells_fa"

///|
/// Draw the cursor quad on a surface.
pub extern "C" fn gpu_draw_cursor(
  surface_id : Int,
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
/// End the frame on a surface and present.
pub extern "C" fn gpu_frame_end(surface_id : Int) -> Int = "hello_tty_gpu_frame_end"

///|
/// Legacy: init device + create surface 0 (for backward compatibility).
pub extern "C" fn gpu_init(
  surface_handle_lo : Int,
  surface_handle_hi : Int,
  width : Int,
  height : Int,
) -> Int = "hello_tty_gpu_init_i32"

///|
/// Legacy: resize surface 0.
pub extern "C" fn gpu_resize(width : Int, height : Int) -> Int = "hello_tty_gpu_resize"
