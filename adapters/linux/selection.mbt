///|
/// Linux adapter — text selection state and clipboard text extraction.

///|
pub struct SelectionState {
  mut active : Bool
  mut anchor_row : Int
  mut anchor_col : Int
  mut end_row : Int
  mut end_col : Int
  mut panel_id : Int
}

///|
pub let g_selection : SelectionState = {
  active: false,
  anchor_row: 0,
  anchor_col: 0,
  end_row: 0,
  end_col: 0,
  panel_id: -1,
}

///|
pub fn extract_selection_text(
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
) -> String {
  if !g_selection.active { return "" }
  let panels = layout.get_all_panels()
  let mut session_id = -1
  for i in 0..<panels.length() {
    if panels[i].panel_id == g_selection.panel_id {
      session_id = panels[i].session_id
      break
    }
  }
  match sessions.get_session(session_id) {
    Some(session) => {
      let grid = session.get_terminal().get_grid()
      let mut r1 = g_selection.anchor_row
      let mut c1 = g_selection.anchor_col
      let mut r2 = g_selection.end_row
      let mut c2 = g_selection.end_col
      if r1 > r2 || (r1 == r2 && c1 > c2) {
        let tr = r1
        let tc = c1
        r1 = r2
        c1 = c2
        r2 = tr
        c2 = tc
      }
      r1 = Int::max(0, Int::min(r1, grid.rows - 1))
      r2 = Int::max(0, Int::min(r2, grid.rows - 1))
      c1 = Int::max(0, Int::min(c1, grid.cols - 1))
      c2 = Int::max(0, Int::min(c2, grid.cols - 1))
      let sb = StringBuilder::new()
      for row in r1..=r2 {
        let col_start = if row == r1 { c1 } else { 0 }
        let col_end = if row == r2 { c2 } else { grid.cols - 1 }
        let mut last_non_space = col_start - 1
        for col in col_start..=col_end {
          let cell = grid.get_cell(row, col)
          if cell.char != '\u0000' && cell.char != ' ' {
            last_non_space = col
          }
        }
        for col in col_start..=Int::max(col_start, last_non_space) {
          let cell = grid.get_cell(row, col)
          if cell.char != '\u0000' {
            sb.write_char(cell.char)
          } else {
            sb.write_char(' ')
          }
        }
        if row < r2 { sb.write_char('\n') }
      }
      sb.to_string()
    }
    None => ""
  }
}
