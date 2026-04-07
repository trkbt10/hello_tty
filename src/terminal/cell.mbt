///|
/// A single cell in the terminal grid.
/// Each cell holds one (possibly wide) character with its display attributes.
pub struct Cell {
  /// The character displayed. '\u0000' means empty.
  mut char : Char
  /// Foreground color.
  mut fg : Color
  /// Background color.
  mut bg : Color
  /// Text attributes (bold, italic, etc.).
  attrs : CellAttrs
  /// Width of the character in cells (1 for normal, 2 for wide CJK, 0 for continuation).
  mut width : Int
} derive(Show)

///|
/// Create an empty cell with default attributes.
pub fn Cell::empty() -> Cell {
  {
    char: '\u0000',
    fg: Default,
    bg: Default,
    attrs: CellAttrs::default(),
    width: 1,
  }
}

///|
/// Create a cell with a character and default colors.
pub fn Cell::from_char(c : Char) -> Cell {
  { char: c, fg: Default, bg: Default, attrs: CellAttrs::default(), width: 1 }
}

///|
/// Reset the cell to empty state.
pub fn Cell::reset(self : Cell) -> Unit {
  self.char = '\u0000'
  self.fg = Default
  self.bg = Default
  self.attrs.clear()
  self.width = 1
}

///|
/// Check if the cell is empty (no character content).
pub fn Cell::is_empty(self : Cell) -> Bool {
  self.char == '\u0000' || self.char == ' '
}

///|
/// Copy attributes from another cell (for style propagation).
pub fn Cell::copy_style_from(self : Cell, other : Cell) -> Unit {
  self.fg = other.fg
  self.bg = other.bg
  self.attrs.flags = other.attrs.flags
}

///|
/// A row is a fixed-size array of cells representing one terminal line.
pub struct Row {
  cells : Array[Cell]
  /// Dirty flag for rendering optimization — true if row changed since last render.
  mut dirty : Bool
  /// Whether this row is a continuation of the previous line (soft-wrapped).
  mut wrapped : Bool
} derive(Show)

///|
/// Create a new row with the given number of columns.
pub fn Row::new(cols : Int) -> Row {
  let cells : Array[Cell] = Array::new(capacity=cols)
  for _i in 0..<cols {
    cells.push(Cell::empty())
  }
  { cells, dirty: true, wrapped: false }
}

///|
/// Reset all cells in the row to empty.
pub fn Row::clear(self : Row) -> Unit {
  for i in 0..<self.cells.length() {
    self.cells[i].reset()
  }
  self.dirty = true
  self.wrapped = false
}

///|
/// Get the number of columns in this row.
pub fn Row::cols(self : Row) -> Int {
  self.cells.length()
}

///|
/// Get a cell by column index.
pub fn Row::get(self : Row, col : Int) -> Cell {
  self.cells[col]
}

///|
/// Resize the row to a new column count.
pub fn Row::resize(self : Row, new_cols : Int) -> Unit {
  let old_cols = self.cells.length()
  if new_cols > old_cols {
    for _i in 0..<(new_cols - old_cols) {
      self.cells.push(Cell::empty())
    }
  } else if new_cols < old_cols {
    // Truncate: just shrink by popping
    for _i in 0..<(old_cols - new_cols) {
      self.cells.pop() |> ignore
    }
  }
  self.dirty = true
}
