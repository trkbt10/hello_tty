
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
/// This reads the grid and cursor, resolves colors via the theme, and produces
/// a sequence of commands that a GPU backend can execute.
pub fn Renderer::render(
  self : Renderer,
  terminal : @terminal.Terminal,
  theme : @theme.Theme,
) -> Array[RenderCommand] {
  let commands : Array[RenderCommand] = []
  let grid = terminal.get_grid()
  let cursor = terminal.get_cursor()
  let modes = terminal.get_modes()
  let viewport_offset = terminal.get_viewport_offset()
  // Clear with background color
  let bg = if modes.reverse_video {
    theme.fg
  } else {
    theme.bg
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
      let resolved_fg = theme.resolve_color(fg_color, true)
      let resolved_bg = theme.resolve_color(bg_color, false)
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
    commands.push(
      DrawCursor({
        row: cursor.row,
        col: cursor.col,
        style: cursor.style,
        color: theme.cursor,
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
