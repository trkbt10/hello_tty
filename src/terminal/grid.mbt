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
} derive(Show)

///|
/// Create a new grid with the given dimensions.
pub fn Grid::new(rows : Int, cols : Int) -> Grid {
  let lines : Array[Row] = Array::new(capacity=rows)
  for _i in 0..<rows {
    lines.push(Row::new(cols))
  }
  { rows, cols, lines, scroll_top: 0, scroll_bottom: rows - 1 }
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
}

///|
/// Clear wide character fragments when overwriting.
///
/// If the cell at (row, col) is:
///   - A continuation cell (width=0): the preceding cell is the head of a
///     wide character. Reset the head to a space with width=1.
///   - A wide character head (width=2): the next cell is a continuation.
///     Reset the continuation to empty with width=1.
///
/// This prevents rendering artifacts when a narrow character overwrites
/// part of a wide character.
pub fn Grid::clear_wide_char_at(self : Grid, row : Int, col : Int) -> Unit {
  let cell = self.lines[row].get(col)
  if cell.width == 0 && col > 0 {
    // This is a continuation cell — clear the head
    let head = self.lines[row].get(col - 1)
    if head.width == 2 {
      head.char = ' '
      head.width = 1
    }
  }
  if cell.width == 2 && col + 1 < self.cols {
    // This is a wide head — clear the continuation
    let cont = self.lines[row].get(col + 1)
    if cont.width == 0 {
      cont.char = '\u0000'
      cont.width = 1
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
}

///|
/// Clear a range of rows [from, to) inclusive on from, exclusive on to.
pub fn Grid::clear_rows(self : Grid, from : Int, to : Int) -> Unit {
  let start = from.clamp(min=0, max=self.rows)
  let end = to.clamp(min=0, max=self.rows)
  for i in start..<end {
    self.lines[i].clear()
  }
}

///|
/// Clear cells in a row from column `from` to `to` (exclusive).
pub fn Grid::clear_cells(self : Grid, row : Int, from : Int, to : Int) -> Unit {
  let line = self.lines[row]
  let start = from.clamp(min=0, max=self.cols)
  let end = to.clamp(min=0, max=self.cols)
  for i in start..<end {
    line.cells[i].reset()
  }
  line.dirty = true
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
}

///|
/// Insert n blank cells at position (row, col), shifting cells to the right.
/// Cells that fall off the right edge are lost.
pub fn Grid::insert_cells(self : Grid, row : Int, col : Int, n : Int) -> Unit {
  let line = self.lines[row]
  let count = n.clamp(min=0, max=self.cols - col)
  for _i in 0..<count {
    // Remove the last cell
    line.cells.pop() |> ignore
    // Insert blank cell at the cursor position
    line.cells.insert(col, Cell::empty())
  }
  line.dirty = true
}

///|
/// Delete n cells at position (row, col), shifting cells to the left.
/// Blank cells appear at the right edge.
pub fn Grid::delete_cells(self : Grid, row : Int, col : Int, n : Int) -> Unit {
  let line = self.lines[row]
  let count = n.clamp(min=0, max=self.cols - col)
  for _i in 0..<count {
    line.cells.remove(col) |> ignore
    line.cells.push(Cell::empty())
  }
  line.dirty = true
}

///|
/// Mark all rows as clean (after rendering).
pub fn Grid::mark_all_clean(self : Grid) -> Unit {
  for i in 0..<self.rows {
    self.lines[i].dirty = false
  }
}

///|
/// Check if any row is dirty.
pub fn Grid::has_dirty_rows(self : Grid) -> Bool {
  for i in 0..<self.rows {
    if self.lines[i].dirty {
      return true
    }
  }
  false
}
