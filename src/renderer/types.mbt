// RgbaColor is defined in src/theme/types.mbt — the single source of truth.
// Use @theme.RgbaColor throughout the renderer.
pub typealias @theme.RgbaColor as RgbaColor

// GlyphKey and CachedGlyph are in src/font/types.mbt — used via @font.

///|
/// Configuration for the renderer.
pub(all) struct RendererConfig {
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
} derive(Show)

///|
pub fn RendererConfig::default() -> RendererConfig {
  {
    cell_width: 8,
    cell_height: 16,
    font_size: 14,
    dpi_scale: 1.0,
    atlas_size: 1024,
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
  /// Cell width in columns (1 for normal, 2 for wide CJK/emoji).
  cell_cols : Int
  /// The glyph key (None for empty cells).
  glyph : @font.GlyphKey?
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
