///|
/// Linux adapter — multi-panel GPU rendering via viewport subdivision.

///|
pub fn render_all_panels(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  renderer : @renderer.Renderer,
  gpu : @renderer.GpuBackend,
  theme : @theme.Theme,
  win_w : Int,
  win_h : Int,
) -> Unit {
  let rects = compute_panel_rects(layout, win_w, win_h)
  if rects.length() == 0 { return }
  let focused_id = layout.get_focused_panel_id()
  if !gpu.frame_begin(0, theme.bg) { return }
  for i in 0..<rects.length() {
    let rect = rects[i]
    if rect.w <= 0 || rect.h <= 0 { continue }
    match sessions.get_session(rect.session_id) {
      Some(session) => {
        gpu.set_viewport(0, rect.x, rect.y, rect.w, rect.h)
        let commands = renderer.render(session.get_terminal(), theme)
        for j in 0..<commands.length() {
          match commands[j] {
            @renderer.Clear(_) => ()
            @renderer.DrawCells(cells) => gpu.draw_cell_quads_on(0, cells)
            @renderer.DrawCursor(cursor) =>
              if rect.panel_id == focused_id {
                gpu.draw_cursor_quad_on(0, cursor)
              }
            @renderer.Present => ()
          }
        }
      }
      None => ()
    }
  }
  gpu.frame_end(0) |> ignore
}
