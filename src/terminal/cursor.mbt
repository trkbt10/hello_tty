///|
/// The terminal cursor state.
pub struct Cursor {
  /// Current row (0-based, relative to the visible screen).
  mut row : Int
  /// Current column (0-based).
  mut col : Int
  /// The "pen" — attributes applied to newly written characters.
  pen : Cell
  /// Cursor style for rendering.
  style : CursorStyle
  /// Whether the cursor is visible.
  mut visible : Bool
  /// Saved cursor state (for DECSC/DECRC).
  mut saved_row : Int
  mut saved_col : Int
  saved_pen : Cell
  /// Whether the cursor wrapped and is pending at the right margin.
  /// This is the "pending wrap" state from the VT spec.
  mut wrap_pending : Bool
  /// Character set designations (G0-G3).
  mut charset_g0 : CharSet
  mut charset_g1 : CharSet
  /// Which charset is active (0 = G0, 1 = G1).
  mut active_charset : Int
} derive(Show)

///|
/// Create a new cursor at position (0, 0) with default attributes.
pub fn Cursor::new() -> Cursor {
  {
    row: 0,
    col: 0,
    pen: Cell::empty(),
    style: Block,
    visible: true,
    saved_row: 0,
    saved_col: 0,
    saved_pen: Cell::empty(),
    wrap_pending: false,
    charset_g0: Ascii,
    charset_g1: Ascii,
    active_charset: 0,
  }
}

///|
/// Save the current cursor position and attributes (DECSC).
pub fn Cursor::save(self : Cursor) -> Unit {
  self.saved_row = self.row
  self.saved_col = self.col
  self.saved_pen.copy_style_from(self.pen)
}

///|
/// Restore the previously saved cursor position and attributes (DECRC).
pub fn Cursor::restore(self : Cursor) -> Unit {
  self.row = self.saved_row
  self.col = self.saved_col
  self.pen.copy_style_from(self.saved_pen)
  self.wrap_pending = false
}

///|
/// Move the cursor to an absolute position, clamped to grid bounds.
pub fn Cursor::move_to(
  self : Cursor,
  row : Int,
  col : Int,
  max_rows : Int,
  max_cols : Int,
) -> Unit {
  self.row = row.clamp(min=0, max=max_rows - 1)
  self.col = col.clamp(min=0, max=max_cols - 1)
  self.wrap_pending = false
}

///|
/// Move the cursor by a relative offset, clamped to grid bounds.
pub fn Cursor::move_by(
  self : Cursor,
  d_row : Int,
  d_col : Int,
  max_rows : Int,
  max_cols : Int,
) -> Unit {
  self.row = (self.row + d_row).clamp(min=0, max=max_rows - 1)
  self.col = (self.col + d_col).clamp(min=0, max=max_cols - 1)
  self.wrap_pending = false
}
