///|
/// Scrollback buffer using an immutable page-list architecture.
/// Rows that scroll off the top of the primary screen are stored here.
/// Each "page" holds a fixed number of rows to minimize memory allocation.
pub struct Scrollback {
  /// Pages of scrollback rows, newest last.
  pages : Array[ScrollbackPage]
  /// Maximum total number of scrollback lines.
  max_lines : Int
  /// Current total number of lines stored.
  mut total_lines : Int
  /// Number of rows per page.
  page_size : Int
}

///|
/// A page in the scrollback buffer.
/// Pages are immutable once full — new rows are appended to the active (last) page.
struct ScrollbackPage {
  rows : Array[Row]
  mut frozen : Bool
}

///|
/// Default scrollback configuration.
pub let default_max_scrollback : Int = 10000

///|
pub let default_page_size : Int = 128

///|
/// Create a new scrollback buffer.
pub fn Scrollback::new(
  max_lines? : Int = 10000,
  page_size? : Int = 128,
) -> Scrollback {
  { pages: [], max_lines, total_lines: 0, page_size }
}

///|
/// Push a row into the scrollback buffer.
/// If the buffer exceeds max_lines, the oldest page is evicted.
pub fn Scrollback::push(self : Scrollback, row : Row) -> Unit {
  // Get or create the active (last) page
  let page = if self.pages.length() == 0 {
    let p : ScrollbackPage = { rows: [], frozen: false }
    self.pages.push(p)
    p
  } else {
    let last = self.pages[self.pages.length() - 1]
    if last.frozen {
      let p : ScrollbackPage = { rows: [], frozen: false }
      self.pages.push(p)
      p
    } else {
      last
    }
  }
  page.rows.push(row)
  self.total_lines += 1
  // Freeze the page if it's full
  if page.rows.length() >= self.page_size {
    page.frozen = true
  }
  // Evict oldest pages if over limit
  while self.total_lines > self.max_lines && self.pages.length() > 0 {
    let oldest = self.pages[0]
    self.total_lines -= oldest.rows.length()
    self.pages.remove(0) |> ignore
  }
}

///|
/// Push multiple rows into the scrollback buffer.
pub fn Scrollback::push_rows(self : Scrollback, rows : Array[Row]) -> Unit {
  for i in 0..<rows.length() {
    self.push(rows[i])
  }
}

///|
/// Get the total number of scrollback lines.
pub fn Scrollback::length(self : Scrollback) -> Int {
  self.total_lines
}

///|
/// Get a row by absolute index (0 = oldest line in scrollback).
pub fn Scrollback::get(self : Scrollback, index : Int) -> Row? {
  if index < 0 || index >= self.total_lines {
    return None
  }
  let mut offset = index
  for i in 0..<self.pages.length() {
    let page = self.pages[i]
    if offset < page.rows.length() {
      return Some(page.rows[offset])
    }
    offset -= page.rows.length()
  }
  None
}

///|
/// Clear all scrollback history.
pub fn Scrollback::clear(self : Scrollback) -> Unit {
  self.pages.clear()
  self.total_lines = 0
}
