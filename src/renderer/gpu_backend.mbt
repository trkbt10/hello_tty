///|
/// The GpuBackend executes RenderCommands on the GPU via wgpu.
///
/// Consumes @font.FontEngine for glyph management.
/// The render loop is:
///   1. Renderer builds RenderCommand array from terminal state
///   2. GpuBackend::execute_frame() processes commands via GPU FFI
pub struct GpuBackend {
  config : RendererConfig
  /// Font engine (SoT for glyph management) — injected dependency.
  font : @font.FontEngine
  mut initialized : Bool
}

///|
pub suberror GpuError {
  InitFailed(String)
  FontError(String)
  RenderError(String)
}

///|
pub fn GpuBackend::new(
  config~ : RendererConfig = RendererConfig::default(),
  font~ : @font.FontEngine = @font.FontEngine::new(),
) -> GpuBackend {
  { config, font, initialized: false }
}

///|
/// Initialize the GPU backend.
/// surface_handle: platform-specific (CAMetalLayer* as Int, or 0 if already initialized).
/// width, height: framebuffer size in pixels.
pub fn GpuBackend::init(
  self : GpuBackend,
  surface_handle : Int,
  width : Int,
  height : Int,
) -> Unit!GpuError {
  let ret = @ffi.gpu_init(surface_handle, 0, width, height)
  if ret < 0 {
    raise InitFailed("GPU initialization failed")
  }
  // Delegate font initialization to FontEngine
  try {
    self.font.init!()
  } catch {
    @font.FontInitFailed(msg) => raise FontError(msg)
    _ => raise FontError("Font initialization failed")
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

// ensure_glyph is now in @font.FontEngine

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
///
/// Two-pass rendering:
///   Pass 1 — Background: full-cell quads with bg color, UV=(0,0) (no texture)
///   Pass 2 — Glyphs: bearing-positioned quads with fg color, atlas UV
///
/// This ensures:
///   - Background fills the entire cell regardless of glyph size
///   - Glyphs are rendered at their natural size without stretching
///   - Baseline alignment via bearing_y relative to cell ascent
fn GpuBackend::draw_cell_quads(
  self : GpuBackend,
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
  // Pass 1: Backgrounds — one quad per cell
  // Glyph quads are at most one per cell with a glyph
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
    // Skip continuation cells (width=0) — the wide cell's quad already covers them
    if cell.cell_cols == 0 { continue }
    let cell_x = Float::from_int(cell.col) * cw
    let cell_y = Float::from_int(cell.row) * ch
    let cell_w = cw * Float::from_int(cell.cell_cols) // 2*cw for wide chars
    let bg_r = Float::from_int(cell.bg.r.to_int()) / 255.0
    let bg_g = Float::from_int(cell.bg.g.to_int()) / 255.0
    let bg_b = Float::from_int(cell.bg.b.to_int()) / 255.0
    let bg_a = Float::from_int(cell.bg.a.to_int()) / 255.0
    let fg_r = Float::from_int(cell.fg.r.to_int()) / 255.0
    let fg_g = Float::from_int(cell.fg.g.to_int()) / 255.0
    let fg_b = Float::from_int(cell.fg.b.to_int()) / 255.0
    let fg_a = Float::from_int(cell.fg.a.to_int()) / 255.0
    // Background quad: full cell width (may span multiple columns), no texture
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
    // Glyph quad (if present): positioned using bearing
    match cell.glyph {
      Some(key) =>
        match self.font.ensure_glyph(key) {
          Some(rg) => {
            // Upload bitmap to GPU if newly rasterized
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
            let g = rg.cached
            // Glyph position within cell:
            //   x = cell_x + bearing_x
            //   y = cell_y + (ascent - bearing_y)   ← baseline-relative
            let gx0 = cell_x + Float::from_int(g.bearing_x)
            let gy0 = cell_y + (ascent - Float::from_int(g.bearing_y))
            let gx1 = gx0 + Float::from_int(g.width)
            let gy1 = gy0 + Float::from_int(g.height)
            let u0 = Float::from_int(g.atlas_x) / atlas_w
            let v0 = Float::from_int(g.atlas_y) / atlas_h
            let u1 = Float::from_int(g.atlas_x + g.width) / atlas_w
            let v1 = Float::from_int(g.atlas_y + g.height) / atlas_h
            // For glyph pass: fg color as foreground, bg with alpha=0
            // so the shader mixes: mix(transparent, fg, glyph_alpha)
            emit_quad(
              fg_verts,
              fg_vi,
              gx0,
              gy0,
              gx1,
              gy1,
              u0,
              v0,
              u1,
              v1,
              fg_r,
              fg_g,
              fg_b,
              fg_a,
              0.0,
              0.0,
              0.0,
              0.0,
            )
            fg_vi += 6 * floats_per_vertex
            fg_count += 6
          }
          None => ()
        }
      None => ()
    }
  }
  // Submit background pass
  let bg_count = cells.length() * 6
  let _ret1 = @ffi.gpu_draw_cells(bg_verts, bg_count)
  // Submit glyph pass
  if fg_count > 0 {
    let _ret2 = @ffi.gpu_draw_cells(fg_verts, fg_count)
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
  let f = 12 // floats per vertex
  let mut vi = offset
  // Vertex 0: top-left
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
  // Vertex 1: top-right
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
  // Vertex 2: bottom-left
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
  // Vertex 3: top-right (second triangle)
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
  // Vertex 4: bottom-right
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
  // Vertex 5: bottom-left (second triangle)
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
/// Draw the cursor as a colored quad.
fn GpuBackend::draw_cursor_quad(self : GpuBackend, cursor : CursorQuad) -> Unit {
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
    x, y, w, h,
    cursor.color.r, cursor.color.g, cursor.color.b, cursor.color.a,
    style_int,
  )
}

///|
/// Get the cell dimensions from the font engine.
pub fn GpuBackend::get_cell_size(self : GpuBackend) -> (Int, Int) {
  let m = self.font.get_metrics()
  (m.cell_width, m.cell_height)
}

///|
/// Shut down the GPU backend and font engine.
pub fn GpuBackend::shutdown(self : GpuBackend) -> Unit {
  if self.initialized {
    self.font.shutdown()
    @ffi.gpu_shutdown()
    self.initialized = false
  }
}
