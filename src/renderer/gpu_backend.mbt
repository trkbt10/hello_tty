///|
/// The GpuBackend manages GPU rendering across multiple surfaces.
///
/// Multi-surface architecture:
///   - Device-level resources (pipelines, atlas, font engine) are shared.
///   - Each panel has its own surface_id for independent swapchain/framebuffer.
///   - GpuBackend is a singleton that holds shared state and routes
///     render calls to the correct surface.
///
/// The render loop is:
///   1. Renderer builds RenderCommand array from terminal state
///   2. GpuBackend::execute_frame_on(surface_id, commands) renders to a specific surface
pub struct GpuBackend {
  config : RendererConfig
  /// Font engine (SoT for glyph management) — shared across all surfaces.
  font : @font.FontEngine
  mut device_initialized : Bool
}

///|
pub suberror GpuError {
  InitFailed(String)
  FontError(String)
  RenderError(String)
}

///|
pub fn GpuBackend::new(
  config? : RendererConfig = RendererConfig::default(),
  font? : @font.FontEngine = @font.FontEngine::new(),
) -> GpuBackend {
  { config, font, device_initialized: false }
}

///|
/// Initialize shared GPU resources: device, pipelines, font engine, atlas.
/// Must be called once before creating any surfaces.
pub fn GpuBackend::init_device(self : GpuBackend) -> Unit raise GpuError {
  if self.device_initialized {
    return
  }
  let ret = @ffi.gpu_init_device()
  if ret < 0 {
    raise InitFailed("GPU device initialization failed")
  }
  // Font engine
  self.font.init() catch {
    @font.FontInitFailed(msg) => raise FontError(msg)
    _ => raise FontError("Font initialization failed")
  }
  // Atlas texture
  let atlas_ret = @ffi.gpu_atlas_create(
    self.config.atlas_size,
    self.config.atlas_size,
  )
  if atlas_ret < 0 {
    raise InitFailed("Atlas texture creation failed")
  }
  self.device_initialized = true
}

///|
/// Create a new GPU surface for a panel.
/// surface_handle: platform-specific (CAMetalLayer* as Int).
/// Returns surface_id (>= 0) on success.
pub fn GpuBackend::create_surface(
  self : GpuBackend,
  surface_handle : Int,
  width : Int,
  height : Int,
) -> Int raise GpuError {
  if !self.device_initialized {
    self.init_device()
  }
  let sid = @ffi.gpu_surface_create(surface_handle, 0, width, height)
  if sid < 0 {
    raise InitFailed("GPU surface creation failed")
  }
  sid
}

///|
/// Destroy a GPU surface by ID.
pub fn GpuBackend::destroy_surface(
  _self : GpuBackend,
  surface_id : Int,
) -> Unit {
  @ffi.gpu_surface_destroy(surface_id)
}

///|
/// Resize a surface's swapchain.
pub fn GpuBackend::resize_surface(
  _self : GpuBackend,
  surface_id : Int,
  width : Int,
  height : Int,
) -> Unit raise GpuError {
  let ret = @ffi.gpu_surface_resize(surface_id, width, height)
  if ret < 0 {
    raise RenderError("Swapchain resize failed")
  }
}

///|
/// Execute a complete frame on a specific surface.
pub fn GpuBackend::execute_frame_on(
  self : GpuBackend,
  surface_id : Int,
  commands : Array[RenderCommand],
) -> Unit raise GpuError {
  if !self.device_initialized {
    raise RenderError("GpuBackend device not initialized")
  }
  // Set clear color from first Clear command
  for i in 0..<commands.length() {
    if commands[i] is Clear(color) {
      @ffi.gpu_frame_clear(surface_id, color.r, color.g, color.b, color.a)
      break
    }
  }
  // Begin frame
  let begin_ret = @ffi.gpu_frame_begin(surface_id)
  if begin_ret < 0 {
    raise RenderError("Swapchain out of date")
  }
  // Process draw commands
  for i in 0..<commands.length() {
    match commands[i] {
      Clear(_) => ()
      DrawCells(cells) => self.draw_cell_quads_on(surface_id, cells)
      DrawCursor(cursor) => self.draw_cursor_quad_on(surface_id, cursor)
      Present => ()
    }
  }
  // End frame and present
  let end_ret = @ffi.gpu_frame_end(surface_id)
  if end_ret < 0 {
    raise RenderError("Frame presentation failed")
  }
}

///|
/// Legacy: execute_frame on a default surface (backward compatibility).
/// Uses legacy global surface (surface_id from hello_tty_gpu_init).
pub fn GpuBackend::execute_frame(
  self : GpuBackend,
  commands : Array[RenderCommand],
) -> Unit raise GpuError {
  // Legacy path: use surface_id 0 (the legacy global surface)
  self.execute_frame_on(0, commands)
}

///|
/// Legacy: init device + create surface via old API.
pub fn GpuBackend::init(
  self : GpuBackend,
  surface_handle : Int,
  width : Int,
  height : Int,
) -> Unit raise GpuError {
  if !self.device_initialized {
    // Use legacy init which creates device + surface 0
    let ret = @ffi.gpu_init(surface_handle, 0, width, height)
    if ret < 0 {
      raise InitFailed("GPU initialization failed")
    }
    self.font.init() catch {
      @font.FontInitFailed(msg) => raise FontError(msg)
      _ => raise FontError("Font initialization failed")
    }
    let atlas_ret = @ffi.gpu_atlas_create(
      self.config.atlas_size,
      self.config.atlas_size,
    )
    if atlas_ret < 0 {
      raise InitFailed("Atlas texture creation failed")
    }
    self.device_initialized = true
  }
}

///|
/// Legacy: resize surface 0.
pub fn GpuBackend::resize(
  _self : GpuBackend,
  width : Int,
  height : Int,
) -> Unit raise GpuError {
  let ret = @ffi.gpu_resize(width, height)
  if ret < 0 {
    raise RenderError("Swapchain resize failed")
  }
}

///|
/// Build and submit vertex data for cell quads on a specific surface.
/// Public for multi-panel viewport rendering where the caller manages
/// frame begin/end and viewport setup.
pub fn GpuBackend::draw_cell_quads_on(
  self : GpuBackend,
  surface_id : Int,
  cells : Array[CellQuad],
) -> Unit {
  if cells.length() == 0 {
    return
  }
  let metrics = self.font.get_metrics()
  let cw = Float::from_int(metrics.cell_width)
  let ch = Float::from_int(metrics.cell_height)
  let atlas_w = Float::from_int(self.config.atlas_size)
  let atlas_h = Float::from_int(self.config.atlas_size)
  let ascent = Float::from_int(metrics.ascent)
  let floats_per_vertex = 12
  let max_bg_verts = cells.length() * 6
  let max_fg_verts = cells.length() * 6
  let bg_verts : FixedArray[Float] = FixedArray::make(
    max_bg_verts * floats_per_vertex,
    0.0,
  )
  let fg_verts : FixedArray[Float] = FixedArray::make(
    max_fg_verts * floats_per_vertex,
    0.0,
  )
  let mut bg_vi = 0
  let mut fg_vi = 0
  let mut fg_count = 0
  for i in 0..<cells.length() {
    let cell = cells[i]
    if cell.cell_cols == 0 {
      continue
    }
    let cell_x = Float::from_int(cell.col) * cw
    let cell_y = Float::from_int(cell.row) * ch
    let cell_w = cw * Float::from_int(cell.cell_cols)
    let bg_r = Float::from_int(cell.bg.r.to_int()) / 255.0
    let bg_g = Float::from_int(cell.bg.g.to_int()) / 255.0
    let bg_b = Float::from_int(cell.bg.b.to_int()) / 255.0
    let bg_a = Float::from_int(cell.bg.a.to_int()) / 255.0
    let fg_r = Float::from_int(cell.fg.r.to_int()) / 255.0
    let fg_g = Float::from_int(cell.fg.g.to_int()) / 255.0
    let fg_b = Float::from_int(cell.fg.b.to_int()) / 255.0
    let fg_a = Float::from_int(cell.fg.a.to_int()) / 255.0
    emit_quad(
      bg_verts,
      bg_vi,
      cell_x,
      cell_y,
      cell_x + cell_w,
      cell_y + ch,
      0.0,
      0.0,
      0.0,
      0.0,
      bg_r,
      bg_g,
      bg_b,
      bg_a,
      bg_r,
      bg_g,
      bg_b,
      bg_a,
    )
    bg_vi += 6 * floats_per_vertex
    match cell.glyph {
      Some(key) =>
        match self.font.ensure_glyph(key) {
          Some(rg) => {
            if rg.is_new && rg.bitmap_width > 0 && rg.bitmap_height > 0 {
              let _upload = @ffi.gpu_atlas_upload(
                rg.cached.atlas_x,
                rg.cached.atlas_y,
                rg.bitmap_width,
                rg.bitmap_height,
                rg.bitmap,
                rg.bitmap_width * rg.bitmap_height * 4,
              )
            }
            let glyph = rg.cached
            let gx0 = cell_x + Float::from_int(glyph.bearing_x)
            let gy0 = cell_y + (ascent - Float::from_int(glyph.bearing_y))
            let gx1 = gx0 + Float::from_int(glyph.width)
            let gy1 = gy0 + Float::from_int(glyph.height)
            let u0 = Float::from_int(glyph.atlas_x) / atlas_w
            let v0 = Float::from_int(glyph.atlas_y) / atlas_h
            let u1 = Float::from_int(glyph.atlas_x + glyph.width) / atlas_w
            let v1 = Float::from_int(glyph.atlas_y + glyph.height) / atlas_h
            emit_quad(
              fg_verts, fg_vi, gx0, gy0, gx1, gy1, u0, v0, u1, v1, fg_r, fg_g, fg_b,
              fg_a, 0.0, 0.0, 0.0, 0.0,
            )
            fg_vi += 6 * floats_per_vertex
            fg_count += 6
          }
          None => ()
        }
      None => ()
    }
  }
  let bg_count = cells.length() * 6
  let _ret1 = @ffi.gpu_draw_cells(surface_id, bg_verts, bg_count)
  if fg_count > 0 {
    let _ret2 = @ffi.gpu_draw_cells(surface_id, fg_verts, fg_count)
  }
}

///|
/// Emit a 6-vertex quad into a float array at the given offset.
fn emit_quad(
  verts : FixedArray[Float],
  offset : Int,
  x0 : Float,
  y0 : Float,
  x1 : Float,
  y1 : Float,
  u0 : Float,
  v0 : Float,
  u1 : Float,
  v1 : Float,
  fg_r : Float,
  fg_g : Float,
  fg_b : Float,
  fg_a : Float,
  bg_r : Float,
  bg_g : Float,
  bg_b : Float,
  bg_a : Float,
) -> Unit {
  let f = 12
  let mut vi = offset
  verts[vi] = x0
  verts[vi + 1] = y0
  verts[vi + 2] = u0
  verts[vi + 3] = v0
  verts[vi + 4] = fg_r
  verts[vi + 5] = fg_g
  verts[vi + 6] = fg_b
  verts[vi + 7] = fg_a
  verts[vi + 8] = bg_r
  verts[vi + 9] = bg_g
  verts[vi + 10] = bg_b
  verts[vi + 11] = bg_a
  vi += f
  verts[vi] = x1
  verts[vi + 1] = y0
  verts[vi + 2] = u1
  verts[vi + 3] = v0
  verts[vi + 4] = fg_r
  verts[vi + 5] = fg_g
  verts[vi + 6] = fg_b
  verts[vi + 7] = fg_a
  verts[vi + 8] = bg_r
  verts[vi + 9] = bg_g
  verts[vi + 10] = bg_b
  verts[vi + 11] = bg_a
  vi += f
  verts[vi] = x0
  verts[vi + 1] = y1
  verts[vi + 2] = u0
  verts[vi + 3] = v1
  verts[vi + 4] = fg_r
  verts[vi + 5] = fg_g
  verts[vi + 6] = fg_b
  verts[vi + 7] = fg_a
  verts[vi + 8] = bg_r
  verts[vi + 9] = bg_g
  verts[vi + 10] = bg_b
  verts[vi + 11] = bg_a
  vi += f
  verts[vi] = x1
  verts[vi + 1] = y0
  verts[vi + 2] = u1
  verts[vi + 3] = v0
  verts[vi + 4] = fg_r
  verts[vi + 5] = fg_g
  verts[vi + 6] = fg_b
  verts[vi + 7] = fg_a
  verts[vi + 8] = bg_r
  verts[vi + 9] = bg_g
  verts[vi + 10] = bg_b
  verts[vi + 11] = bg_a
  vi += f
  verts[vi] = x1
  verts[vi + 1] = y1
  verts[vi + 2] = u1
  verts[vi + 3] = v1
  verts[vi + 4] = fg_r
  verts[vi + 5] = fg_g
  verts[vi + 6] = fg_b
  verts[vi + 7] = fg_a
  verts[vi + 8] = bg_r
  verts[vi + 9] = bg_g
  verts[vi + 10] = bg_b
  verts[vi + 11] = bg_a
  vi += f
  verts[vi] = x0
  verts[vi + 1] = y1
  verts[vi + 2] = u0
  verts[vi + 3] = v1
  verts[vi + 4] = fg_r
  verts[vi + 5] = fg_g
  verts[vi + 6] = fg_b
  verts[vi + 7] = fg_a
  verts[vi + 8] = bg_r
  verts[vi + 9] = bg_g
  verts[vi + 10] = bg_b
  verts[vi + 11] = bg_a
}

///|
/// Draw the cursor as a colored quad on a specific surface.
pub fn GpuBackend::draw_cursor_quad_on(
  self : GpuBackend,
  surface_id : Int,
  cursor : CursorQuad,
) -> Unit {
  if !cursor.visible {
    return
  }
  let m = self.font.get_metrics()
  let x = Float::from_int(cursor.col * m.cell_width)
  let y = Float::from_int(cursor.row * m.cell_height)
  let w = Float::from_int(m.cell_width)
  let h = Float::from_int(m.cell_height)
  let style_int = match cursor.style {
    @terminal.Block => 0
    @terminal.Underline => 1
    @terminal.Bar => 2
  }
  @ffi.gpu_draw_cursor(
    surface_id,
    x,
    y,
    w,
    h,
    cursor.color.r,
    cursor.color.g,
    cursor.color.b,
    cursor.color.a,
    style_int,
  )
}

///|
/// Begin a frame on a specific surface (for multi-panel rendering).
/// The caller manages viewport setup and draw calls between begin/end.
pub fn GpuBackend::frame_begin(
  _self : GpuBackend,
  surface_id : Int,
  clear_color : @theme.RgbaColor,
) -> Bool {
  @ffi.gpu_frame_clear(
    surface_id, clear_color.r, clear_color.g, clear_color.b, clear_color.a,
  )
  @ffi.gpu_frame_begin(surface_id) == 0
}

///|
/// Set the viewport for sub-region rendering within a frame.
pub fn GpuBackend::set_viewport(
  _self : GpuBackend,
  surface_id : Int,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) -> Unit {
  @ffi.gpu_set_viewport(surface_id, x, y, width, height)
}

///|
/// End a frame and present.
pub fn GpuBackend::frame_end(
  _self : GpuBackend,
  surface_id : Int,
) -> Bool {
  @ffi.gpu_frame_end(surface_id) == 0
}

///|
pub fn GpuBackend::get_cell_size(self : GpuBackend) -> (Int, Int) {
  let m = self.font.get_metrics()
  (m.cell_width, m.cell_height)
}

///|
pub fn GpuBackend::shutdown(self : GpuBackend) -> Unit {
  if self.device_initialized {
    self.font.shutdown()
    @ffi.gpu_shutdown()
    self.device_initialized = false
  }
}
