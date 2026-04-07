///|
/// Font engine — the single source of truth for glyph management.
///
/// Owns:
///   - Font metrics (cell size, ascent, descent) via FFI + mizchi/font
///   - Glyph atlas (packing, cache lookup)
///   - Rasterization requests (via platform FFI)
///
/// Does NOT own GPU state. Returns bitmap data for the renderer to upload.
pub struct FontEngine {
  config : FontConfig
  atlas : TextureAtlas
  mut metrics : FontMetrics
  max_glyph_buf : Int
  mut initialized : Bool
}

///|
pub fn FontEngine::new(config~ : FontConfig = FontConfig::default()) -> FontEngine {
  {
    config,
    atlas: TextureAtlas::new(config.atlas_size, config.atlas_size),
    metrics: { cell_width: 8, cell_height: 16, ascent: 12, descent: 4 },
    max_glyph_buf: 65536,
    initialized: false,
  }
}

///|
/// Initialize the font engine via platform FFI.
/// Reads font metrics and prepares the atlas.
pub fn FontEngine::init(self : FontEngine) -> Unit!FontError {
  let font_name = @utf8.encode(self.config.font_name)
  let font_ret = @ffi.font_init(font_name, font_name.length(), self.config.font_size)
  if font_ret < 0 {
    raise FontInitFailed("Font engine initialization failed")
  }
  let metrics_buf : FixedArray[Int] = FixedArray::make(4, 0)
  let m_ret = @ffi.font_get_metrics(metrics_buf)
  if m_ret == 0 {
    self.metrics = {
      cell_width: metrics_buf[0],
      cell_height: metrics_buf[1],
      ascent: metrics_buf[2],
      descent: metrics_buf[3],
    }
  }
  self.initialized = true
}

///|
/// Get font metrics.
pub fn FontEngine::get_metrics(self : FontEngine) -> FontMetrics {
  self.metrics
}

///|
/// Get the texture atlas (for renderer to query atlas dimensions).
pub fn FontEngine::get_atlas(self : FontEngine) -> TextureAtlas {
  self.atlas
}

///|
/// Ensure a glyph is in the atlas. Returns RasterizedGlyph with
/// bitmap data if newly rasterized (is_new=true), or cached info
/// if already present (is_new=false, bitmap empty).
///
/// The caller (renderer) is responsible for uploading the bitmap
/// to the GPU via gpu_atlas_upload when is_new=true.
pub fn FontEngine::ensure_glyph(
  self : FontEngine,
  key : GlyphKey,
) -> RasterizedGlyph? {
  // Check cache first
  match self.atlas.lookup(key) {
    Some(cached) =>
      return Some({
        cached,
        bitmap: FixedArray::make(0, b'\x00'),
        bitmap_width: 0,
        bitmap_height: 0,
        is_new: false,
      })
    None => ()
  }
  // Rasterize via FFI
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
  // Allocate space in atlas
  let cached = self.atlas.allocate(
    key, glyph_w, glyph_h, bearing_x, bearing_y, advance,
  )
  match cached {
    None => None
    Some(glyph) => {
      // Convert A8 → RGBA
      let rgba_size = glyph_w * glyph_h * 4
      let rgba_buf : FixedArray[Byte] = FixedArray::make(rgba_size, b'\x00')
      for i in 0..<bitmap_size {
        let alpha = bitmap_buf[i]
        let base = i * 4
        rgba_buf[base] = b'\xFF'
        rgba_buf[base + 1] = b'\xFF'
        rgba_buf[base + 2] = b'\xFF'
        rgba_buf[base + 3] = alpha
      }
      Some({
        cached: glyph,
        bitmap: rgba_buf,
        bitmap_width: glyph_w,
        bitmap_height: glyph_h,
        is_new: true,
      })
    }
  }
}

///|
pub fn FontEngine::shutdown(self : FontEngine) -> Unit {
  if self.initialized {
    @ffi.font_shutdown()
    self.initialized = false
  }
}

///|
pub(all) suberror FontError {
  FontInitFailed(String)
  FontRasterizeError(String)
}
