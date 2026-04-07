///|
/// Texture atlas for glyph caching.
/// Organizes rasterized glyphs into a single texture to minimize
/// GPU texture binding calls during rendering.
///
/// Uses a simple row-based packing strategy:
/// Glyphs are placed left-to-right in rows of equal height.
/// When a row is full, a new row starts below.
pub struct TextureAtlas {
  /// Atlas texture width in pixels.
  width : Int
  /// Atlas texture height in pixels.
  height : Int
  /// Glyph cache: maps glyph keys to their atlas positions.
  cache : Map[String, CachedGlyph]
  /// Current packing cursor X position.
  mut cursor_x : Int
  /// Current packing cursor Y position.
  mut cursor_y : Int
  /// Current row height (max glyph height in the current row).
  mut row_height : Int
  /// Whether the atlas texture needs to be re-uploaded to the GPU.
  mut dirty : Bool
}

///|
/// Create a new texture atlas with the given dimensions.
pub fn TextureAtlas::new(width : Int, height : Int) -> TextureAtlas {
  {
    width,
    height,
    cache: {},
    cursor_x: 0,
    cursor_y: 0,
    row_height: 0,
    dirty: false,
  }
}

///|
/// Build a cache key string from a GlyphKey.
fn glyph_cache_key(key : GlyphKey) -> String {
  let buf = StringBuilder::new()
  buf.write_string(key.codepoint.to_string())
  buf.write_string("_")
  if key.bold {
    buf.write_string("b")
  }
  if key.italic {
    buf.write_string("i")
  }
  buf.write_string("_")
  buf.write_string(key.font_size.to_string())
  buf.to_string()
}

///|
/// Look up a glyph in the atlas cache.
pub fn TextureAtlas::lookup(
  self : TextureAtlas,
  key : GlyphKey,
) -> CachedGlyph? {
  self.cache.get(glyph_cache_key(key))
}

///|
/// Allocate space in the atlas for a new glyph.
/// Returns the (x, y) position where the glyph should be placed,
/// or None if the atlas is full.
pub fn TextureAtlas::allocate(
  self : TextureAtlas,
  key : GlyphKey,
  width : Int,
  height : Int,
  bearing_x : Int,
  bearing_y : Int,
  advance : Int,
) -> CachedGlyph? {
  let cache_key = glyph_cache_key(key)
  // Check if already cached
  match self.cache.get(cache_key) {
    Some(cached) => return Some(cached)
    None => ()
  }
  // Try to fit in the current row
  if self.cursor_x + width > self.width {
    // Move to next row
    self.cursor_y += self.row_height
    self.cursor_x = 0
    self.row_height = 0
  }
  // Check if we have vertical space
  if self.cursor_y + height > self.height {
    return None // Atlas is full
  }
  let glyph : CachedGlyph = {
    atlas_x: self.cursor_x,
    atlas_y: self.cursor_y,
    width,
    height,
    bearing_x,
    bearing_y,
    advance,
  }
  self.cache.set(cache_key, glyph)
  self.cursor_x += width + 1 // 1px padding between glyphs
  if height > self.row_height {
    self.row_height = height
  }
  self.dirty = true
  Some(glyph)
}

///|
/// Check if the atlas needs to be re-uploaded to the GPU.
pub fn TextureAtlas::is_dirty(self : TextureAtlas) -> Bool {
  self.dirty
}

///|
/// Mark the atlas as clean (after GPU upload).
pub fn TextureAtlas::mark_clean(self : TextureAtlas) -> Unit {
  self.dirty = false
}

///|
/// Clear the atlas cache (e.g. when resizing the atlas texture).
pub fn TextureAtlas::clear(self : TextureAtlas) -> Unit {
  self.cache.clear()
  self.cursor_x = 0
  self.cursor_y = 0
  self.row_height = 0
  self.dirty = true
}

///|
/// Get the number of cached glyphs.
pub fn TextureAtlas::glyph_count(self : TextureAtlas) -> Int {
  self.cache.length()
}

///|
/// Get the fill ratio of the atlas (approximate).
pub fn TextureAtlas::fill_ratio(self : TextureAtlas) -> Float {
  let used_area = self.cursor_y * self.width + self.cursor_x * self.row_height
  let total_area = self.width * self.height
  if total_area == 0 {
    0.0
  } else {
    Float::from_int(used_area) / Float::from_int(total_area)
  }
}
