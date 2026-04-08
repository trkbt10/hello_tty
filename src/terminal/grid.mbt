///|
/// The cell grid represents one screen of the terminal (rows x cols).
pub struct Grid {
  mut rows : Int
  mut cols : Int
  /// Row storage. Index 0 is the top of the visible screen.
  lines : Array[Row]
  /// Scroll region top (inclusive, 0-based).
  mut scroll_top : Int
  /// Scroll region bottom (inclusive, 0-based).
  mut scroll_bottom : Int
  /// Dirty bounding box — tracks the minimal rectangle of changed cells.
  /// Reset after each render. (-1,-1,-1,-1) means clean.
  mut dirty_top : Int
  mut dirty_bottom : Int
  mut dirty_left : Int
  mut dirty_right : Int
  /// Whether the entire grid is dirty (e.g. after scroll, clear, resize).
  mut dirty_all : Bool
} derive(Show)

///|
/// Create a new grid with the given dimensions.
pub fn Grid::new(rows : Int, cols : Int) -> Grid {
  let lines : Array[Row] = Array::new(capacity=rows)
  for _i in 0..<rows {
    lines.push(Row::new(cols))
  }
  {
    rows,
    cols,
    lines,
    scroll_top: 0,
    scroll_bottom: rows - 1,
    dirty_top: -1,
    dirty_bottom: -1,
    dirty_left: -1,
    dirty_right: -1,
    dirty_all: true,
  }
}

///|
/// Get a cell at the given position.
pub fn Grid::get_cell(self : Grid, row : Int, col : Int) -> Cell {
  self.lines[row].get(col)
}

///|
/// Set a character at the given position with the given pen attributes.
pub fn Grid::set_cell(
  self : Grid,
  row : Int,
  col : Int,
  char : Char,
  pen : Cell,
) -> Unit {
  let cell = self.lines[row].get(col)
  cell.char = char
  cell.fg = pen.fg
  cell.bg = pen.bg
  cell.attrs.flags = pen.attrs.flags
  self.lines[row].dirty = true
  self.mark_dirty(row, col)
}

///|
/// Set a character with explicit cell width (for wide character support).
pub fn Grid::set_cell_with_width(
  self : Grid,
  row : Int,
  col : Int,
  char : Char,
  pen : Cell,
  width : Int,
) -> Unit {
  let cell = self.lines[row].get(col)
  cell.char = char
  cell.fg = pen.fg
  cell.bg = pen.bg
  cell.attrs.flags = pen.attrs.flags
  cell.width = width
  self.lines[row].dirty = true
  self.mark_dirty(row, col)
  // Wide char spans 2 cells
  if width == 2 && col + 1 < self.cols {
    self.mark_dirty(row, col + 1)
  }
}

///|
/// Clear wide character fragments when overwriting.
pub fn Grid::clear_wide_char_at(self : Grid, row : Int, col : Int) -> Unit {
  let cell = self.lines[row].get(col)
  if cell.width == 0 && col > 0 {
    let head = self.lines[row].get(col - 1)
    if head.width == 2 {
      head.char = ' '
      head.width = 1
      self.mark_dirty(row, col - 1)
    }
  }
  if cell.width == 2 && col + 1 < self.cols {
    let cont = self.lines[row].get(col + 1)
    if cont.width == 0 {
      cont.char = '\u0000'
      cont.width = 1
      self.mark_dirty(row, col + 1)
    }
  }
  self.lines[row].dirty = true
}

///|
/// Clear the entire grid.
pub fn Grid::clear(self : Grid) -> Unit {
  for i in 0..<self.rows {
    self.lines[i].clear()
  }
  self.mark_all_dirty()
}

///|
/// Clear a range of rows [from, to) inclusive on from, exclusive on to.
pub fn Grid::clear_rows(self : Grid, from : Int, to : Int) -> Unit {
  let start = from.clamp(min=0, max=self.rows)
  let end = to.clamp(min=0, max=self.rows)
  for i in start..<end {
    self.lines[i].clear()
    self.mark_row_dirty(i)
  }
}

///|
/// Clear cells in a row from column `from` to `to` (exclusive).
/// Handles wide character boundaries: if the clear range splits a wide character
/// (covers only the head or only the continuation), the other half is cleaned up.
pub fn Grid::clear_cells(self : Grid, row : Int, from : Int, to : Int) -> Unit {
  let line = self.lines[row]
  let start = from.clamp(min=0, max=self.cols)
  let end = to.clamp(min=0, max=self.cols)
  if start >= end {
    return
  }
  // If the start of the range lands on a continuation cell (width=0),
  // the preceding head cell loses its continuation — clean it up.
  if start > 0 && line.cells[start].width == 0 {
    let head = line.cells[start - 1]
    if head.width == 2 {
      head.char = ' '
      head.width = 1
      self.mark_dirty(row, start - 1)
    }
  }
  // If the end of the range lands inside a wide character (i.e. the cell just
  // before `end` is a head with width=2, meaning its continuation at `end` is
  // outside the clear range), clean up the continuation.
  // Also: if the cell at `end` is a continuation (width=0), its head was cleared.
  if end < self.cols && line.cells[end].width == 0 {
    line.cells[end].reset()
    self.mark_dirty(row, end)
  }
  for i in start..<end {
    line.cells[i].reset()
  }
  line.dirty = true
  self.mark_dirty(row, start)
  self.mark_dirty(row, end - 1)
}

///|
/// Scroll the region [scroll_top, scroll_bottom] up by n lines.
/// New blank lines appear at the bottom.
/// Returns the lines that scrolled off the top (for scrollback).
pub fn Grid::scroll_up(self : Grid, n : Int) -> Array[Row] {
  let scrolled_off : Array[Row] = []
  let count = n.clamp(min=0, max=self.scroll_bottom - self.scroll_top + 1)
  for _i in 0..<count {
    // Remove the top line of the scroll region
    let removed = self.lines.remove(self.scroll_top)
    scrolled_off.push(removed)
    // Insert a new blank line at the bottom of the scroll region
    let new_row = Row::new(self.cols)
    // Insert at scroll_bottom position (which shifted by one)
    self.lines.insert(self.scroll_bottom, new_row)
  }
  // Mark all rows in the scroll region as dirty
  for i in self.scroll_top..<=self.scroll_bottom {
    self.lines[i].dirty = true
  }
  self.mark_all_dirty()
  scrolled_off
}

///|
/// Scroll the region [scroll_top, scroll_bottom] down by n lines.
/// New blank lines appear at the top.
pub fn Grid::scroll_down(self : Grid, n : Int) -> Unit {
  let count = n.clamp(min=0, max=self.scroll_bottom - self.scroll_top + 1)
  for _i in 0..<count {
    // Remove the bottom line of the scroll region
    self.lines.remove(self.scroll_bottom) |> ignore
    // Insert a new blank line at the top of the scroll region
    let new_row = Row::new(self.cols)
    self.lines.insert(self.scroll_top, new_row)
  }
  for i in self.scroll_top..<=self.scroll_bottom {
    self.lines[i].dirty = true
  }
  self.mark_all_dirty()
}

///|
/// Set the scroll region. top and bottom are 0-based, inclusive.
pub fn Grid::set_scroll_region(self : Grid, top : Int, bottom : Int) -> Unit {
  self.scroll_top = top.clamp(min=0, max=self.rows - 1)
  self.scroll_bottom = bottom.clamp(min=0, max=self.rows - 1)
  if self.scroll_top >= self.scroll_bottom {
    // Invalid region: reset to full screen
    self.scroll_top = 0
    self.scroll_bottom = self.rows - 1
  }
}

///|
/// Reset scroll region to full screen.
pub fn Grid::reset_scroll_region(self : Grid) -> Unit {
  self.scroll_top = 0
  self.scroll_bottom = self.rows - 1
}

///|
/// Resize the grid to new dimensions.
pub fn Grid::resize(self : Grid, new_rows : Int, new_cols : Int) -> Unit {
  // Resize existing rows
  for i in 0..<self.lines.length() {
    self.lines[i].resize(new_cols)
  }
  // Add or remove rows as needed
  if new_rows > self.rows {
    for _i in 0..<(new_rows - self.rows) {
      self.lines.push(Row::new(new_cols))
    }
  } else if new_rows < self.rows {
    for _i in 0..<(self.rows - new_rows) {
      self.lines.pop() |> ignore
    }
  }
  self.rows = new_rows
  self.cols = new_cols
  self.scroll_top = 0
  self.scroll_bottom = new_rows - 1
  self.mark_all_dirty()
}

///|
/// Insert n blank lines at the cursor row, scrolling lines below down.
/// Lines that fall off the scroll_bottom are lost.
pub fn Grid::insert_lines(self : Grid, at_row : Int, n : Int) -> Unit {
  if at_row < self.scroll_top || at_row > self.scroll_bottom {
    return
  }
  let count = n.clamp(min=0, max=self.scroll_bottom - at_row + 1)
  for _i in 0..<count {
    // Remove from bottom of scroll region
    if self.scroll_bottom < self.lines.length() {
      self.lines.remove(self.scroll_bottom) |> ignore
    }
    // Insert blank line at cursor row
    self.lines.insert(at_row, Row::new(self.cols))
  }
  for i in at_row..<=self.scroll_bottom {
    self.lines[i].dirty = true
  }
  self.mark_all_dirty()
}

///|
/// Delete n lines at the cursor row, scrolling lines below up.
/// Blank lines appear at the scroll_bottom.
pub fn Grid::delete_lines(self : Grid, at_row : Int, n : Int) -> Unit {
  if at_row < self.scroll_top || at_row > self.scroll_bottom {
    return
  }
  let count = n.clamp(min=0, max=self.scroll_bottom - at_row + 1)
  for _i in 0..<count {
    self.lines.remove(at_row) |> ignore
    self.lines.insert(self.scroll_bottom, Row::new(self.cols))
  }
  for i in at_row..<=self.scroll_bottom {
    self.lines[i].dirty = true
  }
  self.mark_all_dirty()
}

///|
/// Insert n blank cells at position (row, col), shifting cells to the right.
/// Cells that fall off the right edge are lost.
/// Handles wide character boundaries: if the insertion point splits a wide
/// character, or if a wide character is pushed partially off the right edge,
/// the orphaned halves are cleaned up.
pub fn Grid::insert_cells(self : Grid, row : Int, col : Int, n : Int) -> Unit {
  let line = self.lines[row]
  let count = n.clamp(min=0, max=self.cols - col)
  if count == 0 {
    return
  }
  // Before insertion: if the cell at `col` is a continuation (width=0),
  // its head at col-1 will be separated from its continuation — clean up both.
  // The head loses its continuation, and the continuation itself (which will
  // shift right) becomes orphaned.
  if col > 0 && line.cells[col].width == 0 {
    let head = line.cells[col - 1]
    if head.width == 2 {
      head.char = ' '
      head.width = 1
    }
    // Also clean up the continuation cell itself — after the shift it will
    // no longer be preceded by a valid head.
    line.cells[col].reset()
  }
  // Check if cells that will fall off the right edge include a wide char head
  // whose continuation would survive (or vice versa).
  // The cells that fall off are at positions [cols - count, cols).
  // If the cell at (cols - count - 1) is a wide head (width=2) and its
  // continuation at (cols - count) would be pushed off — the head survives
  // but loses its continuation.
  let shift_boundary = self.cols - count
  if shift_boundary > 0 && shift_boundary < self.cols {
    let cell_at_boundary = line.cells[shift_boundary]
    if cell_at_boundary.width == 0 {
      // Continuation is at the boundary — its head won't be pushed off.
      // After shift, the head remains but continuation is lost.
      // Actually the continuation IS the one being lost (pushed off).
      // Wait — cells at [shift_boundary, cols) are lost. The continuation
      // at shift_boundary is lost. Its head at shift_boundary-1 survives — clean it.
      let head = line.cells[shift_boundary - 1]
      if head.width == 2 {
        head.char = ' '
        head.width = 1
      }
    }
    // If the cell at shift_boundary is a wide head, its continuation at
    // shift_boundary+1 is also being lost — both are lost, so that's fine.
  }
  for _i in 0..<count {
    line.cells.pop() |> ignore
    line.cells.insert(col, Cell::empty())
  }
  line.dirty = true
  self.mark_row_dirty(row)
}

///|
/// Delete n cells at position (row, col), shifting cells to the left.
/// Blank cells appear at the right edge.
/// Handles wide character boundaries: if deletion splits a wide character
/// (removes only the head or only the continuation), the orphaned half is cleaned up.
pub fn Grid::delete_cells(self : Grid, row : Int, col : Int, n : Int) -> Unit {
  let line = self.lines[row]
  let count = n.clamp(min=0, max=self.cols - col)
  if count == 0 {
    return
  }
  // Before deletion: check if the cell at `col` is a continuation (width=0).
  // If so, its head at col-1 will lose its continuation — clean it up.
  if col > 0 && line.cells[col].width == 0 {
    let head = line.cells[col - 1]
    if head.width == 2 {
      head.char = ' '
      head.width = 1
    }
  }
  // Check if the last cell to be deleted (col + count - 1) is the head of a
  // wide character whose continuation (at col + count) would survive.
  // After the shift, that continuation becomes orphaned — clean it up.
  let del_end = col + count
  if del_end < self.cols && line.cells[del_end].width == 0 {
    // The continuation's head was deleted — reset the continuation
    line.cells[del_end].reset()
  }
  // Also check if the first cell to be deleted is a wide head whose
  // continuation is also being deleted — that's fine. But if the first
  // cell being deleted is a wide head and its continuation is NOT being
  // deleted, the continuation shifts left and becomes the new col position.
  // Actually this is already handled: after removal + shift, we need to
  // check again. Let's just do the deletion first.
  for _i in 0..<count {
    line.cells.remove(col) |> ignore
    line.cells.push(Cell::empty())
  }
  // After deletion, check the cell now at position `col` — it was shifted in.
  // If it's an orphaned continuation (width=0) with no valid head before it,
  // clean it up.
  if col < self.cols && line.cells[col].width == 0 {
    if col == 0 || line.cells[col - 1].width != 2 {
      line.cells[col].reset()
    }
  }
  line.dirty = true
  self.mark_row_dirty(row)
}

///|
/// Expand the dirty bounding box to include the cell at (row, col).
pub fn Grid::mark_dirty(self : Grid, row : Int, col : Int) -> Unit {
  if self.dirty_top < 0 {
    self.dirty_top = row
    self.dirty_bottom = row
    self.dirty_left = col
    self.dirty_right = col
  } else {
    if row < self.dirty_top { self.dirty_top = row }
    if row > self.dirty_bottom { self.dirty_bottom = row }
    if col < self.dirty_left { self.dirty_left = col }
    if col > self.dirty_right { self.dirty_right = col }
  }
}

///|
/// Expand the dirty bounding box to include an entire row.
pub fn Grid::mark_row_dirty(self : Grid, row : Int) -> Unit {
  self.mark_dirty(row, 0)
  self.mark_dirty(row, self.cols - 1)
}

///|
/// Mark the entire grid as dirty.
pub fn Grid::mark_all_dirty(self : Grid) -> Unit {
  self.dirty_all = true
}

///|
/// Get the dirty bounding box: (top, left, bottom, right).
/// Returns None if nothing is dirty.
pub fn Grid::get_dirty_rect(self : Grid) -> (Int, Int, Int, Int)? {
  if self.dirty_all {
    return Some((0, 0, self.rows - 1, self.cols - 1))
  }
  if self.dirty_top < 0 {
    return None
  }
  Some((self.dirty_top, self.dirty_left, self.dirty_bottom, self.dirty_right))
}

///|
/// Mark all rows as clean (after rendering).
pub fn Grid::mark_all_clean(self : Grid) -> Unit {
  for i in 0..<self.rows {
    self.lines[i].dirty = false
  }
  self.dirty_top = -1
  self.dirty_bottom = -1
  self.dirty_left = -1
  self.dirty_right = -1
  self.dirty_all = false
}

///|
/// Check if any row is dirty.
pub fn Grid::has_dirty_rows(self : Grid) -> Bool {
  if self.dirty_all || self.dirty_top >= 0 {
    return true
  }
  false
}
