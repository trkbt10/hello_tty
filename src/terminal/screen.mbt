///|
/// ScreenSet manages the primary and alternate screen buffers.
/// The primary screen is used for normal terminal operation and has scrollback.
/// The alternate screen is used by full-screen applications (vim, less, etc.)
/// and has no scrollback.
pub struct ScreenSet {
  /// Primary screen grid.
  primary : Grid
  /// Alternate screen grid.
  alternate : Grid
  /// Scrollback buffer for the primary screen.
  scrollback : Scrollback
  /// Which screen is currently active.
  mut active : ScreenKind
  /// Cursor for the primary screen.
  primary_cursor : Cursor
  /// Cursor for the alternate screen.
  alternate_cursor : Cursor
  /// Terminal dimensions.
  mut rows : Int
  mut cols : Int
}

///|
pub(all) enum ScreenKind {
  Primary
  Alternate
} derive(Show, Eq)

///|
/// Create a new screen set with the given dimensions.
pub fn ScreenSet::new(
  rows : Int,
  cols : Int,
  max_scrollback? : Int = 10000,
) -> ScreenSet {
  {
    primary: Grid::new(rows, cols),
    alternate: Grid::new(rows, cols),
    scrollback: Scrollback::new(max_lines=max_scrollback),
    active: Primary,
    primary_cursor: Cursor::new(),
    alternate_cursor: Cursor::new(),
    rows,
    cols,
  }
}

///|
/// Get the currently active grid.
pub fn ScreenSet::active_grid(self : ScreenSet) -> Grid {
  match self.active {
    Primary => self.primary
    Alternate => self.alternate
  }
}

///|
/// Get the currently active cursor.
pub fn ScreenSet::active_cursor(self : ScreenSet) -> Cursor {
  match self.active {
    Primary => self.primary_cursor
    Alternate => self.alternate_cursor
  }
}

///|
/// Switch to the alternate screen buffer.
/// Saves the primary cursor and clears the alternate screen.
pub fn ScreenSet::switch_to_alternate(self : ScreenSet) -> Unit {
  if self.active == Alternate {
    return
  }
  self.primary_cursor.save()
  self.alternate.clear()
  self.active = Alternate
}

///|
/// Switch back to the primary screen buffer.
/// Restores the primary cursor.
pub fn ScreenSet::switch_to_primary(self : ScreenSet) -> Unit {
  if self.active == Primary {
    return
  }
  self.active = Primary
  self.primary_cursor.restore()
}

///|
/// Scroll the active screen up, pushing lines to scrollback if on primary.
pub fn ScreenSet::scroll_up(self : ScreenSet, n : Int) -> Unit {
  let grid = self.active_grid()
  let scrolled = grid.scroll_up(n)
  // Only primary screen lines go to scrollback
  if self.active == Primary {
    self.scrollback.push_rows(scrolled)
  }
}

///|
/// Scroll the active screen down.
pub fn ScreenSet::scroll_down(self : ScreenSet, n : Int) -> Unit {
  self.active_grid().scroll_down(n)
}

///|
/// Resize both screens to new dimensions.
pub fn ScreenSet::resize(
  self : ScreenSet,
  new_rows : Int,
  new_cols : Int,
) -> Unit {
  self.primary.resize(new_rows, new_cols)
  self.alternate.resize(new_rows, new_cols)
  self.rows = new_rows
  self.cols = new_cols
}
