///|
/// Texture atlas for glyph caching.
/// Organizes rasterized glyphs into a single texture to minimize
/// GPU texture binding calls during rendering.
///
/// Uses a simple row-based packing strategy:
/// Glyphs are placed left-to-right in rows of equal height.
/// When a row is full, a new row starts below.
pub struct TextureAtlas {
  width : Int
  height : Int
  cache : Map[String, CachedGlyph]
  mut cursor_x : Int
  mut cursor_y : Int
  mut row_height : Int
  mut dirty : Bool
}

///|
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
pub fn TextureAtlas::lookup(
  self : TextureAtlas,
  key : GlyphKey,
) -> CachedGlyph? {
  self.cache.get(glyph_cache_key(key))
}

///|
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
  match self.cache.get(cache_key) {
    Some(cached) => return Some(cached)
    None => ()
  }
  if self.cursor_x + width > self.width {
    self.cursor_y += self.row_height
    self.cursor_x = 0
    self.row_height = 0
  }
  if self.cursor_y + height > self.height {
    return None
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
  self.cursor_x += width + 1
  if height > self.row_height {
    self.row_height = height
  }
  self.dirty = true
  Some(glyph)
}

///|
pub fn TextureAtlas::is_dirty(self : TextureAtlas) -> Bool {
  self.dirty
}

///|
pub fn TextureAtlas::mark_clean(self : TextureAtlas) -> Unit {
  self.dirty = false
}

///|
pub fn TextureAtlas::clear(self : TextureAtlas) -> Unit {
  self.cache.clear()
  self.cursor_x = 0
  self.cursor_y = 0
  self.row_height = 0
  self.dirty = true
}

///|
pub fn TextureAtlas::glyph_count(self : TextureAtlas) -> Int {
  self.cache.length()
}
