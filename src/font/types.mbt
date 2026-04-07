///|
/// Font metrics describing cell dimensions and baseline position.
pub(all) struct FontMetrics {
  /// Cell width in pixels (advance of 'M').
  cell_width : Int
  /// Cell height in pixels (ascent + descent + leading).
  cell_height : Int
  /// Ascent: distance from baseline to top of cell.
  ascent : Int
  /// Descent: distance from baseline to bottom of cell.
  descent : Int
} derive(Show, Eq)

///|
/// A key identifying a unique glyph shape for atlas caching.
pub(all) struct GlyphKey {
  /// Unicode code point.
  codepoint : Int
  /// Whether bold is applied (affects rasterization).
  bold : Bool
  /// Whether italic is applied.
  italic : Bool
  /// Font size in pixels.
  font_size : Int
} derive(Show, Eq)

///|
/// A cached glyph's position and metrics in the texture atlas.
pub(all) struct CachedGlyph {
  /// Atlas texture region: x offset in pixels.
  atlas_x : Int
  /// Atlas texture region: y offset in pixels.
  atlas_y : Int
  /// Glyph width in pixels.
  width : Int
  /// Glyph height in pixels.
  height : Int
  /// Horizontal offset from pen position.
  bearing_x : Int
  /// Vertical offset from baseline (positive = above baseline).
  bearing_y : Int
  /// Horizontal advance to next character.
  advance : Int
} derive(Show)

///|
/// Result of rasterizing a glyph — includes atlas coords and optional bitmap.
pub(all) struct RasterizedGlyph {
  /// Cached glyph info (atlas position, metrics).
  cached : CachedGlyph
  /// RGBA bitmap data for newly rasterized glyphs (empty if cache hit).
  bitmap : FixedArray[Byte]
  /// Bitmap width (0 if cache hit).
  bitmap_width : Int
  /// Bitmap height (0 if cache hit).
  bitmap_height : Int
  /// Whether this glyph was newly rasterized (needs GPU upload).
  is_new : Bool
} derive(Show)

///|
/// Configuration for the font engine.
///
/// All policy decisions (font name, size, atlas size) are made in MoonBit.
/// The FFI layer receives these as parameters — it does not choose defaults.
pub(all) struct FontConfig {
  /// Font name (e.g. "Menlo", "DejaVu Sans Mono") or empty for system default.
  font_name : String
  /// Font size in pixels.
  font_size : Int
  /// Initial atlas texture dimensions.
  atlas_size : Int
} derive(Show)

///|
pub fn FontConfig::default() -> FontConfig {
  { font_name: "Menlo", font_size: 26, atlas_size: 1024 }
}
