///|
/// The GpuBackend executes RenderCommands on the GPU via Vulkan.
///
/// It owns the font engine and manages glyph rasterization into the atlas.
/// The render loop is:
///   1. App builds RenderCommand array from terminal state
///   2. GpuBackend::execute() processes each command via Vulkan FFI
pub struct GpuBackend {
  config : RendererConfig
  atlas : TextureAtlas
  /// Font metrics from the font engine.
  mut cell_width : Int
  mut cell_height : Int
  mut font_ascent : Int
  mut font_descent : Int
  /// Maximum rasterization buffer size per glyph (256x256 should be enough).
  max_glyph_buf : Int
  /// Whether the GPU has been initialized.
  mut initialized : Bool
}

///|
pub suberror GpuError {
  InitFailed(String)
  FontError(String)
  RenderError(String)
}

///|
/// Create a new GpuBackend. Does NOT initialize GPU resources —
/// call init() after the platform window/surface is available.
pub fn GpuBackend::new(
  config? : RendererConfig = RendererConfig::default(),
) -> GpuBackend {
  {
    config,
    atlas: TextureAtlas::new(config.atlas_size, config.atlas_size),
    cell_width: config.cell_width,
    cell_height: config.cell_height,
    font_ascent: 0,
    font_descent: 0,
    max_glyph_buf: 65536, // 256x256
    initialized: false,
  }
}

///|
/// Initialize the GPU backend with a Vulkan surface and font engine.
/// surface_handle: VkSurfaceKHR (as Int, or 0 for headless).
/// width, height: initial framebuffer size in pixels.
pub fn GpuBackend::init(
  self : GpuBackend,
  surface_handle : Int,
  width : Int,
  height : Int,
) -> Unit raise GpuError {
  // Initialize GPU (surface handle fits in 32 bits for now)
  let ret = @ffi.gpu_init(surface_handle, 0, width, height)
  if ret < 0 {
    raise InitFailed("Vulkan initialization failed")
  }
  // Initialize font engine with system default monospace font
  let empty_path = Bytes::new(0)
  let font_ret = @ffi.font_init(empty_path, 0, self.config.font_size)
  if font_ret < 0 {
    raise FontError("Font engine initialization failed")
  }
  // Read font metrics to update cell dimensions
  let metrics_buf : FixedArray[Int] = FixedArray::make(4, 0)
  let m_ret = @ffi.font_get_metrics(metrics_buf)
  if m_ret == 0 {
    self.cell_width = metrics_buf[0]
    self.cell_height = metrics_buf[1]
    self.font_ascent = metrics_buf[2]
    self.font_descent = metrics_buf[3]
  }
  // Create atlas texture on GPU
  let atlas_ret = @ffi.gpu_atlas_create(
    self.config.atlas_size,
    self.config.atlas_size,
  )
  if atlas_ret < 0 {
    raise InitFailed("Atlas texture creation failed")
  }
  self.initialized = true
}

///|
/// Resize the swapchain after a window resize.
pub fn GpuBackend::resize(
  self : GpuBackend,
  width : Int,
  height : Int,
) -> Unit raise GpuError {
  ignore(self)
  let ret = @ffi.gpu_resize(width, height)
  if ret < 0 {
    raise RenderError("Swapchain resize failed")
  }
}

///|
/// Rasterize a glyph if not already in the atlas, and return its CachedGlyph.
fn GpuBackend::ensure_glyph(self : GpuBackend, key : GlyphKey) -> CachedGlyph? {
  // Check cache first
  match self.atlas.lookup(key) {
    Some(cached) => return Some(cached)
    None => ()
  }
  // Rasterize the glyph via font FFI
  let metrics_buf : FixedArray[Int] = FixedArray::make(5, 0)
  let bitmap_buf : FixedArray[Byte] = FixedArray::make(self.max_glyph_buf, b'\x00')
  let bold_flag = if key.bold { 1 } else { 0 }
  let italic_flag = if key.italic { 1 } else { 0 }
  let bitmap_size = @ffi.font_rasterize(
    key.codepoint,
    bold_flag,
    italic_flag,
    metrics_buf,
    bitmap_buf,
    self.max_glyph_buf,
  )
  if bitmap_size < 0 {
    return None
  }
  let glyph_w = metrics_buf[0]
  let glyph_h = metrics_buf[1]
  let bearing_x = metrics_buf[2]
  let bearing_y = metrics_buf[3]
  let advance = metrics_buf[4]
  // Allocate space in the atlas
  let cached = self.atlas.allocate(key, glyph_w, glyph_h, bearing_x, bearing_y, advance)
  match cached {
    None => return None
    Some(glyph) => {
      // Convert A8 bitmap to RGBA for GPU upload
      let rgba_size = glyph_w * glyph_h * 4
      let rgba_buf : FixedArray[Byte] = FixedArray::make(rgba_size, b'\x00')
      for i in 0..<bitmap_size {
        let alpha = bitmap_buf[i]
        let base = i * 4
        rgba_buf[base] = b'\xFF' // R
        rgba_buf[base + 1] = b'\xFF' // G
        rgba_buf[base + 2] = b'\xFF' // B
        rgba_buf[base + 3] = alpha // A
      }
      // Upload to GPU atlas texture
      let _upload_ret = @ffi.gpu_atlas_upload(
        glyph.atlas_x,
        glyph.atlas_y,
        glyph_w,
        glyph_h,
        rgba_buf,
        rgba_size,
      )
      Some(glyph)
    }
  }
}

///|
/// Execute a sequence of render commands on the GPU.
pub fn GpuBackend::execute(
  self : GpuBackend,
  commands : Array[RenderCommand],
) -> Unit raise GpuError {
  if !self.initialized {
    raise RenderError("GpuBackend not initialized")
  }
  for i in 0..<commands.length() {
    match commands[i] {
      Clear(color) => @ffi.gpu_frame_clear(color.r, color.g, color.b, color.a)
      DrawCells(cells) => self.draw_cell_quads(cells)
      DrawCursor(cursor) => self.draw_cursor_quad(cursor)
      Present => {
        let begin_ret = @ffi.gpu_frame_begin()
        if begin_ret < 0 {
          // Swapchain out of date — caller should resize
          raise RenderError("Swapchain out of date")
        }
        // Re-execute the commands within the frame
        // (Clear was already set, cells/cursor were built)
        let end_ret = @ffi.gpu_frame_end()
        if end_ret < 0 {
          raise RenderError("Frame presentation failed")
        }
      }
    }
  }
}

///|
/// Execute a complete frame: begin, process all commands, end.
pub fn GpuBackend::execute_frame(
  self : GpuBackend,
  commands : Array[RenderCommand],
) -> Unit raise GpuError {
  if !self.initialized {
    raise RenderError("GpuBackend not initialized")
  }
  // Set clear color from first Clear command
  for i in 0..<commands.length() {
    if commands[i] is Clear(color) {
      @ffi.gpu_frame_clear(color.r, color.g, color.b, color.a)
      break
    }
  }
  // Begin frame
  let begin_ret = @ffi.gpu_frame_begin()
  if begin_ret < 0 {
    raise RenderError("Swapchain out of date")
  }
  // Process draw commands
  for i in 0..<commands.length() {
    match commands[i] {
      Clear(_) => () // Already handled
      DrawCells(cells) => self.draw_cell_quads(cells)
      DrawCursor(cursor) => self.draw_cursor_quad(cursor)
      Present => () // Handled at end
    }
  }
  // End frame and present
  let end_ret = @ffi.gpu_frame_end()
  if end_ret < 0 {
    raise RenderError("Frame presentation failed")
  }
}

///|
/// Build and submit vertex data for cell quads.
fn GpuBackend::draw_cell_quads(
  self : GpuBackend,
  cells : Array[CellQuad],
) -> Unit {
  if cells.length() == 0 {
    return
  }
  let cw = Float::from_int(self.cell_width)
  let ch = Float::from_int(self.cell_height)
  let atlas_w = Float::from_int(self.config.atlas_size)
  let atlas_h = Float::from_int(self.config.atlas_size)
  // Each cell generates 6 vertices (2 triangles)
  // Vertex format: [x, y, u, v, fg_r, fg_g, fg_b, fg_a, bg_r, bg_g, bg_b, bg_a]
  let vertex_count = cells.length() * 6
  let floats_per_vertex = 12
  let total_floats = vertex_count * floats_per_vertex
  let vertices : FixedArray[Float] = FixedArray::make(total_floats, 0.0)
  let mut vi = 0 // vertex index into float array
  for i in 0..<cells.length() {
    let cell = cells[i]
    let x0 = Float::from_int(cell.col) * cw
    let y0 = Float::from_int(cell.row) * ch
    let x1 = x0 + cw
    let y1 = y0 + ch
    // Resolve texture coords from glyph atlas
    let mut u0 : Float = 0.0
    let mut v0 : Float = 0.0
    let mut u1 : Float = 0.0
    let mut v1 : Float = 0.0
    match cell.glyph {
      Some(key) => {
        let cached = self.ensure_glyph(key)
        match cached {
          Some(g) => {
            u0 = Float::from_int(g.atlas_x) / atlas_w
            v0 = Float::from_int(g.atlas_y) / atlas_h
            u1 = Float::from_int(g.atlas_x + g.width) / atlas_w
            v1 = Float::from_int(g.atlas_y + g.height) / atlas_h
          }
          None => ()
        }
      }
      None => ()
    }
    let fg_r = Float::from_int(cell.fg.r.to_int()) / 255.0
    let fg_g = Float::from_int(cell.fg.g.to_int()) / 255.0
    let fg_b = Float::from_int(cell.fg.b.to_int()) / 255.0
    let fg_a = Float::from_int(cell.fg.a.to_int()) / 255.0
    let bg_r = Float::from_int(cell.bg.r.to_int()) / 255.0
    let bg_g = Float::from_int(cell.bg.g.to_int()) / 255.0
    let bg_b = Float::from_int(cell.bg.b.to_int()) / 255.0
    let bg_a = Float::from_int(cell.bg.a.to_int()) / 255.0
    // Triangle 1: top-left, top-right, bottom-left
    // Vertex 0: top-left
    vertices[vi] = x0
    vertices[vi + 1] = y0
    vertices[vi + 2] = u0
    vertices[vi + 3] = v0
    vertices[vi + 4] = fg_r
    vertices[vi + 5] = fg_g
    vertices[vi + 6] = fg_b
    vertices[vi + 7] = fg_a
    vertices[vi + 8] = bg_r
    vertices[vi + 9] = bg_g
    vertices[vi + 10] = bg_b
    vertices[vi + 11] = bg_a
    vi += floats_per_vertex
    // Vertex 1: top-right
    vertices[vi] = x1
    vertices[vi + 1] = y0
    vertices[vi + 2] = u1
    vertices[vi + 3] = v0
    vertices[vi + 4] = fg_r
    vertices[vi + 5] = fg_g
    vertices[vi + 6] = fg_b
    vertices[vi + 7] = fg_a
    vertices[vi + 8] = bg_r
    vertices[vi + 9] = bg_g
    vertices[vi + 10] = bg_b
    vertices[vi + 11] = bg_a
    vi += floats_per_vertex
    // Vertex 2: bottom-left
    vertices[vi] = x0
    vertices[vi + 1] = y1
    vertices[vi + 2] = u0
    vertices[vi + 3] = v1
    vertices[vi + 4] = fg_r
    vertices[vi + 5] = fg_g
    vertices[vi + 6] = fg_b
    vertices[vi + 7] = fg_a
    vertices[vi + 8] = bg_r
    vertices[vi + 9] = bg_g
    vertices[vi + 10] = bg_b
    vertices[vi + 11] = bg_a
    vi += floats_per_vertex
    // Triangle 2: top-right, bottom-right, bottom-left
    // Vertex 3: top-right
    vertices[vi] = x1
    vertices[vi + 1] = y0
    vertices[vi + 2] = u1
    vertices[vi + 3] = v0
    vertices[vi + 4] = fg_r
    vertices[vi + 5] = fg_g
    vertices[vi + 6] = fg_b
    vertices[vi + 7] = fg_a
    vertices[vi + 8] = bg_r
    vertices[vi + 9] = bg_g
    vertices[vi + 10] = bg_b
    vertices[vi + 11] = bg_a
    vi += floats_per_vertex
    // Vertex 4: bottom-right
    vertices[vi] = x1
    vertices[vi + 1] = y1
    vertices[vi + 2] = u1
    vertices[vi + 3] = v1
    vertices[vi + 4] = fg_r
    vertices[vi + 5] = fg_g
    vertices[vi + 6] = fg_b
    vertices[vi + 7] = fg_a
    vertices[vi + 8] = bg_r
    vertices[vi + 9] = bg_g
    vertices[vi + 10] = bg_b
    vertices[vi + 11] = bg_a
    vi += floats_per_vertex
    // Vertex 5: bottom-left
    vertices[vi] = x0
    vertices[vi + 1] = y1
    vertices[vi + 2] = u0
    vertices[vi + 3] = v1
    vertices[vi + 4] = fg_r
    vertices[vi + 5] = fg_g
    vertices[vi + 6] = fg_b
    vertices[vi + 7] = fg_a
    vertices[vi + 8] = bg_r
    vertices[vi + 9] = bg_g
    vertices[vi + 10] = bg_b
    vertices[vi + 11] = bg_a
    vi += floats_per_vertex
  }
  let _ret = @ffi.gpu_draw_cells(vertices, vertex_count)
}

///|
/// Draw the cursor as a colored quad.
fn GpuBackend::draw_cursor_quad(self : GpuBackend, cursor : CursorQuad) -> Unit {
  if !cursor.visible {
    return
  }
  let x = Float::from_int(cursor.col * self.cell_width)
  let y = Float::from_int(cursor.row * self.cell_height)
  let w = Float::from_int(self.cell_width)
  let h = Float::from_int(self.cell_height)
  let style_int = match cursor.style {
    @terminal.Block => 0
    @terminal.Underline => 1
    @terminal.Bar => 2
  }
  @ffi.gpu_draw_cursor(
    x, y, w, h,
    cursor.color.r, cursor.color.g, cursor.color.b, cursor.color.a,
    style_int,
  )
}

///|
/// Get the cell dimensions from the font engine.
pub fn GpuBackend::get_cell_size(self : GpuBackend) -> (Int, Int) {
  (self.cell_width, self.cell_height)
}

///|
/// Shut down the GPU backend and font engine.
pub fn GpuBackend::shutdown(self : GpuBackend) -> Unit {
  if self.initialized {
    @ffi.font_shutdown()
    @ffi.gpu_shutdown()
    self.initialized = false
  }
}
