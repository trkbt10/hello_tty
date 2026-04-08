///|
/// The standard 256-color palette.
/// Colors 0-7: standard colors
/// Colors 8-15: bright colors
/// Colors 16-231: 6x6x6 color cube
/// Colors 232-255: grayscale ramp
let palette_256 : Array[RgbaColor] = {
  let p : Array[RgbaColor] = Array::new(capacity=256)
  // Standard colors (0-7)
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
/// Resolve a terminal Color to an RgbaColor using the palette and config.
pub fn resolve_color(
  color : @terminal.Color,
  config : RendererConfig,
  is_foreground : Bool,
) -> RgbaColor {
  match color {
    Default => if is_foreground { config.default_fg } else { config.default_bg }
    Indexed(idx) =>
      if idx >= 0 && idx < 16 {
        palette_256[idx]
      } else if is_foreground {
        config.default_fg
      } else {
        config.default_bg
      }
    Palette(idx) =>
      if idx >= 0 && idx < 256 {
        palette_256[idx]
      } else if is_foreground {
        config.default_fg
      } else {
        config.default_bg
      }
    Rgb(r, g, b) => RgbaColor::from_rgb(r, g, b)
  }
}

///|
/// The Renderer produces render commands from terminal state.
/// It does not own or lock the terminal — it takes a snapshot of the
/// visible grid and produces rendering instructions for the GPU backend.
pub struct Renderer {
  config : RendererConfig
  atlas : @font.TextureAtlas
}

///|
pub fn Renderer::new(
  config? : RendererConfig = RendererConfig::default(),
) -> Renderer {
  {
    config,
    atlas: @font.TextureAtlas::new(config.atlas_size, config.atlas_size),
  }
}

///|
/// Build render commands for the current terminal state.
/// This reads the grid and cursor, resolves colors, and produces
/// a sequence of commands that a GPU backend can execute.
pub fn Renderer::render(
  self : Renderer,
  terminal : @terminal.Terminal,
) -> Array[RenderCommand] {
  let commands : Array[RenderCommand] = []
  let grid = terminal.get_grid()
  let cursor = terminal.get_cursor()
  let modes = terminal.get_modes()
  let viewport_offset = terminal.get_viewport_offset()
  // Clear with background color
  let bg = if modes.reverse_video {
    self.config.default_fg
  } else {
    self.config.default_bg
  }
  commands.push(Clear(bg))
  // Build cell quads — use viewport rows when scrolled back
  let cell_quads : Array[CellQuad] = []
  for row in 0..<grid.rows {
    let line = match terminal.get_viewport_row(row) {
      Some(r) => r
      None => continue
    }
    for col in 0..<grid.cols {
      let cell = line.get(col)
      let mut fg_color = cell.fg
      let mut bg_color = cell.bg
      // Handle inverse attribute
      if cell.attrs.has(@terminal.attr_inverse) {
        let tmp = fg_color
        fg_color = bg_color
        bg_color = tmp
      }
      // Handle screen-level reverse video
      if modes.reverse_video {
        let tmp = fg_color
        fg_color = bg_color
        bg_color = tmp
      }
      let resolved_fg = resolve_color(fg_color, self.config, true)
      let resolved_bg = resolve_color(bg_color, self.config, false)
      let glyph_key : @font.GlyphKey? = if cell.is_empty() {
        None
      } else {
        Some({
          codepoint: cell.char.to_int(),
          bold: cell.attrs.has(@terminal.attr_bold),
          italic: cell.attrs.has(@terminal.attr_italic),
          font_size: self.config.font_size,
        })
      }
      cell_quads.push({
        row,
        col,
        cell_cols: cell.width,
        glyph: glyph_key,
        fg: resolved_fg,
        bg: resolved_bg,
        attrs_flags: cell.attrs.flags,
      })
    }
  }
  commands.push(DrawCells(cell_quads))
  // Draw cursor only when viewing live (not scrolled back)
  if cursor.visible && viewport_offset == 0 {
    let cursor_fg = self.config.default_fg
    commands.push(
      DrawCursor({
        row: cursor.row,
        col: cursor.col,
        style: cursor.style,
        color: cursor_fg,
        visible: true,
      }),
    )
  }
  commands.push(Present)
  commands
}

///|
/// Get the texture atlas (for GPU texture management).
pub fn Renderer::get_atlas(self : Renderer) -> @font.TextureAtlas {
  self.atlas
}

///|
/// Get the renderer configuration.
pub fn Renderer::get_config(self : Renderer) -> RendererConfig {
  self.config
}

///|
/// Calculate the window size in pixels for the given grid dimensions.
pub fn Renderer::calculate_window_size(
  self : Renderer,
  rows : Int,
  cols : Int,
) -> (Int, Int) {
  let width = Float::from_int(cols * self.config.cell_width) *
    self.config.dpi_scale
  let height = Float::from_int(rows * self.config.cell_height) *
    self.config.dpi_scale
  (width.to_int(), height.to_int())
}

///|
/// Calculate grid dimensions from a window size in pixels.
pub fn Renderer::calculate_grid_size(
  self : Renderer,
  window_width : Int,
  window_height : Int,
) -> (Int, Int) {
  let cell_w = Float::from_int(self.config.cell_width) * self.config.dpi_scale
  let cell_h = Float::from_int(self.config.cell_height) * self.config.dpi_scale
  let cols = (Float::from_int(window_width) / cell_w).to_int()
  let rows = (Float::from_int(window_height) / cell_h).to_int()
  (if rows > 0 { rows } else { 1 }, if cols > 0 { cols } else { 1 })
}
