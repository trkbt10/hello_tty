///|
/// The standard 256-color palette.
/// Colors 0-7: standard colors
/// Colors 8-15: bright colors
/// Colors 16-231: 6x6x6 color cube
/// Colors 232-255: grayscale ramp
pub let palette_256 : Array[RgbaColor] = {
  let p : Array[RgbaColor] = Array::new(capacity=256)
  // Standard colors (0-7) — xterm defaults
  p.push(RgbaColor::from_rgb(b'\x00', b'\x00', b'\x00')) // Black
  p.push(RgbaColor::from_rgb(b'\xAA', b'\x00', b'\x00')) // Red
  p.push(RgbaColor::from_rgb(b'\x00', b'\xAA', b'\x00')) // Green
  p.push(RgbaColor::from_rgb(b'\xAA', b'\x55', b'\x00')) // Yellow/Brown
  p.push(RgbaColor::from_rgb(b'\x00', b'\x00', b'\xAA')) // Blue
  p.push(RgbaColor::from_rgb(b'\xAA', b'\x00', b'\xAA')) // Magenta
  p.push(RgbaColor::from_rgb(b'\x00', b'\xAA', b'\xAA')) // Cyan
  p.push(RgbaColor::from_rgb(b'\xAA', b'\xAA', b'\xAA')) // White
  // Bright colors (8-15)
  p.push(RgbaColor::from_rgb(b'\x55', b'\x55', b'\x55')) // Bright Black
  p.push(RgbaColor::from_rgb(b'\xFF', b'\x55', b'\x55')) // Bright Red
  p.push(RgbaColor::from_rgb(b'\x55', b'\xFF', b'\x55')) // Bright Green
  p.push(RgbaColor::from_rgb(b'\xFF', b'\xFF', b'\x55')) // Bright Yellow
  p.push(RgbaColor::from_rgb(b'\x55', b'\x55', b'\xFF')) // Bright Blue
  p.push(RgbaColor::from_rgb(b'\xFF', b'\x55', b'\xFF')) // Bright Magenta
  p.push(RgbaColor::from_rgb(b'\x55', b'\xFF', b'\xFF')) // Bright Cyan
  p.push(RgbaColor::from_rgb(b'\xFF', b'\xFF', b'\xFF')) // Bright White
  // 216 color cube (16-231): 6x6x6 with values 0,95,135,175,215,255
  let cube_values : Array[Byte] = [
    b'\x00', b'\x5F', b'\x87', b'\xAF', b'\xD7', b'\xFF',
  ]
  for ri in 0..<6 {
    for gi in 0..<6 {
      for bi in 0..<6 {
        p.push(
          RgbaColor::from_rgb(cube_values[ri], cube_values[gi], cube_values[bi]),
        )
      }
    }
  }
  // Grayscale ramp (232-255): 24 shades from 8 to 238
  for i in 0..<24 {
    let v = (8 + i * 10).to_byte()
    p.push(RgbaColor::from_rgb(v, v, v))
  }
  p
}

///|
/// Resolve a terminal Color to a concrete RgbaColor using the theme.
///
/// This is the SoT for color resolution — called by:
///   - The renderer (GPU path) to generate vertex colors
///   - The bridge (ffi_get_grid) to return resolved colors to platform adapters
///
/// Platform adapters should NEVER perform their own color resolution.
pub fn Theme::resolve_color(
  self : Theme,
  color : @terminal.Color,
  is_foreground : Bool,
) -> RgbaColor {
  match color {
    Default => if is_foreground { self.fg } else { self.bg }
    Indexed(idx) =>
      if idx >= 0 && idx < 16 {
        // Use theme's ANSI 16 override
        self.ansi16[idx]
      } else if is_foreground {
        self.fg
      } else {
        self.bg
      }
    Palette(idx) =>
      if idx >= 0 && idx < 16 {
        // Use theme's ANSI 16 override for first 16
        self.ansi16[idx]
      } else if idx >= 0 && idx < 256 {
        palette_256[idx]
      } else if is_foreground {
        self.fg
      } else {
        self.bg
      }
    Rgb(r, g, b) => RgbaColor::from_rgb(r, g, b)
  }
}
