///|
/// Built-in terminal themes.

///|
/// Midnight — dark theme with semi-transparent background for blur.
/// Matches the macOS Liquid Glass aesthetic.
pub fn Theme::midnight() -> Theme {
  let ansi16 : FixedArray[RgbaColor] = FixedArray::make(16, RgbaColor::opaque(b'\x00', b'\x00', b'\x00'))
  // Normal colors (0-7)
  ansi16[0] = RgbaColor::opaque(b'\x26', b'\x26', b'\x2B')  // Black
  ansi16[1] = RgbaColor::opaque(b'\xE6', b'\x4D', b'\x4D')  // Red
  ansi16[2] = RgbaColor::opaque(b'\x59', b'\xCC', b'\x66')  // Green
  ansi16[3] = RgbaColor::opaque(b'\xE6', b'\xBF', b'\x59')  // Yellow
  ansi16[4] = RgbaColor::opaque(b'\x66', b'\x99', b'\xF2')  // Blue
  ansi16[5] = RgbaColor::opaque(b'\xBF', b'\x73', b'\xD9')  // Magenta
  ansi16[6] = RgbaColor::opaque(b'\x59', b'\xCC', b'\xCC')  // Cyan
  ansi16[7] = RgbaColor::opaque(b'\xBF', b'\xBF', b'\xC7')  // White
  // Bright colors (8-15)
  ansi16[8] = RgbaColor::opaque(b'\x66', b'\x66', b'\x73')   // Bright Black
  ansi16[9] = RgbaColor::opaque(b'\xFF', b'\x73', b'\x73')   // Bright Red
  ansi16[10] = RgbaColor::opaque(b'\x80', b'\xF2', b'\x8C')  // Bright Green
  ansi16[11] = RgbaColor::opaque(b'\xFF', b'\xE6', b'\x80')  // Bright Yellow
  ansi16[12] = RgbaColor::opaque(b'\x8C', b'\xBF', b'\xFF')  // Bright Blue
  ansi16[13] = RgbaColor::opaque(b'\xE6', b'\x99', b'\xFF')  // Bright Magenta
  ansi16[14] = RgbaColor::opaque(b'\x80', b'\xF2', b'\xF2')  // Bright Cyan
  ansi16[15] = RgbaColor::opaque(b'\xF2', b'\xF2', b'\xF2')  // Bright White
  {
    name: "Midnight",
    fg: RgbaColor::opaque(b'\xE6', b'\xE6', b'\xE6'),       // 0.90 white
    bg: RgbaColor::opaque(b'\x14', b'\x14', b'\x1A'),        // dark blue-black
    cursor: { r: b'\x66', g: b'\xB3', b: b'\xFF', a: b'\xD9' }, // blue, 0.85 alpha
    selection: { r: b'\x40', g: b'\x73', b: b'\xBF', a: b'\x66' }, // blue, 0.40 alpha
    bold_color: Some(RgbaColor::opaque(b'\xFF', b'\xFF', b'\xFF')),
    ansi16,
    bg_alpha: 0.82,
  }
}

///|
/// Classic — opaque dark theme (no transparency).
pub fn Theme::classic() -> Theme {
  let midnight = Theme::midnight()
  {
    ..midnight,
    name: "Classic",
    bg: RgbaColor::opaque(b'\x12', b'\x12', b'\x17'),
    bold_color: None,
    bg_alpha: 1.0,
  }
}
