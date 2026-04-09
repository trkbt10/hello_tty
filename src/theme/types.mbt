///|
/// Terminal color theme definition.
///
/// This is the single source of truth for all color decisions.
/// The renderer and bridge consume this to resolve terminal Colors
/// (Default, Indexed, Palette, RGB) into concrete RGBA values.
///
/// Platform adapters receive only resolved RGB — they do NOT perform
/// color resolution themselves.
pub(all) struct Theme {
  /// Theme name (for display/identification).
  name : String
  /// Default foreground color (used when terminal sends Color::Default for fg).
  fg : RgbaColor
  /// Default background color (used when terminal sends Color::Default for bg).
  bg : RgbaColor
  /// Cursor color.
  cursor : RgbaColor
  /// Selection highlight color.
  selection : RgbaColor
  /// Bold text color override (None = same as fg).
  bold_color : RgbaColor?
  /// The 16 ANSI palette colors (indices 0-15).
  /// These override the standard xterm defaults for the first 16 colors.
  ansi16 : FixedArray[RgbaColor]
  /// Background alpha (0.0-1.0) for transparency/blur support.
  bg_alpha : Float
} derive(Show)

///|
/// RGBA color with 0-255 per channel.
/// Distinct from renderer's RgbaColor to avoid circular dependency.
pub(all) struct RgbaColor {
  r : Byte
  g : Byte
  b : Byte
  a : Byte
} derive(Show, Eq)

///|
pub fn RgbaColor::new(r : Byte, g : Byte, b : Byte, a : Byte) -> RgbaColor {
  { r, g, b, a }
}

///|
pub fn RgbaColor::from_rgb(r : Byte, g : Byte, b : Byte) -> RgbaColor {
  { r, g, b, a: b'\xFF' }
}

///|
pub fn RgbaColor::white() -> RgbaColor {
  RgbaColor::from_rgb(b'\xFF', b'\xFF', b'\xFF')
}

///|
pub fn RgbaColor::black() -> RgbaColor {
  RgbaColor::from_rgb(b'\x00', b'\x00', b'\x00')
}

///|
/// Whether this theme has a dark background.
/// Used by platform adapters to set the system appearance (dark/light mode).
pub fn Theme::is_dark(self : Theme) -> Bool {
  let r = self.bg.r.to_int()
  let g = self.bg.g.to_int()
  let b = self.bg.b.to_int()
  // Perceived luminance formula (ITU-R BT.601)
  let luminance = 299 * r + 587 * g + 114 * b
  luminance < 128_000 // < 0.5 on 0-255 scale (128 * 1000)
}
