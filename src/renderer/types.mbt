///|
/// RGBA color for the renderer (0-255 per channel).
pub struct RgbaColor {
  r : Byte
  g : Byte
  b : Byte
  a : Byte
} derive(Show, Eq)

///|
pub fn RgbaColor::opaque(r : Byte, g : Byte, b : Byte) -> RgbaColor {
  { r, g, b, a: b'\xFF' }
}

///|
pub fn RgbaColor::white() -> RgbaColor {
  RgbaColor::opaque(b'\xFF', b'\xFF', b'\xFF')
}

///|
pub fn RgbaColor::black() -> RgbaColor {
  RgbaColor::opaque(b'\x00', b'\x00', b'\x00')
}

///|
/// A glyph key used for texture atlas lookups.
/// Identifies a unique glyph shape for caching.
pub struct GlyphKey {
  /// The character code point.
  codepoint : Int
  /// Whether bold is applied (affects glyph rasterization).
  bold : Bool
  /// Whether italic is applied.
  italic : Bool
  /// Font size in pixels (for atlas organization).
  font_size : Int
} derive(Show, Eq)

///|
/// A cached glyph in the texture atlas.
pub struct CachedGlyph {
  /// Atlas texture region: x offset in pixels.
  atlas_x : Int
  /// Atlas texture region: y offset in pixels.
  atlas_y : Int
  /// Glyph width in pixels.
  width : Int
  /// Glyph height in pixels.
  height : Int
  /// Bearing X (horizontal offset from pen position).
  bearing_x : Int
  /// Bearing Y (vertical offset from baseline).
  bearing_y : Int
  /// Advance width (how far the pen moves after this glyph).
  advance : Int
} derive(Show)

///|
/// A vertex for the GPU renderer — represents one corner of a cell quad.
pub struct Vertex {
  /// Position X (normalized device coordinates or pixels).
  x : Float
  /// Position Y.
  y : Float
  /// Texture coordinate U.
  u : Float
  /// Texture coordinate V.
  v : Float
  /// Foreground color (packed RGBA).
  fg_r : Float
  fg_g : Float
  fg_b : Float
  fg_a : Float
  /// Background color (packed RGBA).
  bg_r : Float
  bg_g : Float
  bg_b : Float
  bg_a : Float
} derive(Show)

///|
/// Configuration for the renderer.
pub struct RendererConfig {
  /// Cell width in pixels.
  cell_width : Int
  /// Cell height in pixels.
  cell_height : Int
  /// Font size in pixels.
  font_size : Int
  /// DPI scale factor (e.g. 2.0 for Retina displays).
  dpi_scale : Float
  /// Initial texture atlas size (width and height in pixels).
  atlas_size : Int
  /// Default foreground color.
  default_fg : RgbaColor
  /// Default background color.
  default_bg : RgbaColor
} derive(Show)

///|
pub fn RendererConfig::default() -> RendererConfig {
  {
    cell_width: 8,
    cell_height: 16,
    font_size: 14,
    dpi_scale: 1.0,
    atlas_size: 1024,
    default_fg: RgbaColor::white(),
    default_bg: RgbaColor::black(),
  }
}

///|
/// Render command sent to the GPU backend.
/// The renderer produces a batch of these per frame.
pub(all) enum RenderCommand {
  /// Clear the framebuffer with a color.
  Clear(RgbaColor)
  /// Draw a batch of cell quads (text + background).
  DrawCells(Array[CellQuad])
  /// Draw the cursor.
  DrawCursor(CursorQuad)
  /// Present the frame (swap buffers).
  Present
} derive(Show)

///|
/// A single cell's renderable data.
pub struct CellQuad {
  /// Screen position (row, col).
  row : Int
  col : Int
  /// The glyph key (None for empty cells).
  glyph : GlyphKey?
  /// Foreground color (resolved from terminal Color).
  fg : RgbaColor
  /// Background color (resolved).
  bg : RgbaColor
  /// Cell attributes (for underline, strikethrough decorations).
  attrs_flags : Int
} derive(Show)

///|
/// Cursor renderable data.
pub struct CursorQuad {
  row : Int
  col : Int
  style : @terminal.CursorStyle
  color : RgbaColor
  visible : Bool
} derive(Show)
