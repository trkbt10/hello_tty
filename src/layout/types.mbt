///|
/// Split direction — how a parent node divides its space between children.
///
/// Horizontal: divider runs horizontally, children stack top (first) / bottom (second).
/// Vertical: divider runs vertically, children stack left (first) / right (second).
pub(all) enum SplitDirection {
  Horizontal
  Vertical
} derive(Show, Eq)

///|
/// Information about a leaf panel in the layout tree.
///
/// Each panel maps 1:1 to a Session in SessionManager.
/// `rows` and `cols` are the grid dimensions allocated to this panel
/// by the layout algorithm — they are kept in sync with the Session's
/// terminal grid via resize.
pub struct PanelInfo {
  panel_id : Int
  session_id : Int
  mut rows : Int
  mut cols : Int
} derive(Show)

///|
/// A node in the layout tree — either a terminal panel or a binary split.
///
/// The tree is a strict binary tree: every internal node has exactly two children.
/// Splits are always binary — no n-way splits. To achieve 3+ panels, nest splits.
///
/// Example: three panels side-by-side
///   Split(Vertical, Split(Vertical, Leaf(A), Leaf(B)), Leaf(C))
pub(all) enum LayoutNode {
  /// A terminal panel (leaf of the tree).
  Leaf(PanelInfo)
  /// A binary split with direction, ratio, and two children.
  /// `ratio` (0.0–1.0) is the proportion of space given to `first`.
  Split(SplitDirection, LayoutNode, LayoutNode, Float)
} derive(Show)

///|
/// A tab — one top-level workspace containing a layout tree of panels.
///
/// Each tab is independent: its own layout tree, its own focused panel.
/// Switching tabs switches the entire visible layout.
pub struct Tab {
  id : Int
  /// Root of the layout tree. Always starts as a single Leaf.
  mut layout : LayoutNode
  /// Which panel in this tab currently has keyboard focus.
  mut focused_panel_id : Int
  /// Tab title — derived from the focused panel's session title.
  mut title : String
} derive(Show)

///|
/// Minimum panel dimensions. Splits that would create a panel smaller
/// than these values are rejected.
///
/// 2 rows: at minimum, one line of content + one status indicator.
/// 10 cols: enough for a short prompt.
pub let min_panel_rows : Int = 2

///|
pub let min_panel_cols : Int = 10

///|
/// Result of a split operation, returned to the caller (and ultimately
/// across FFI) so the platform adapter can start the new PTY I/O loop.
pub struct SplitResult {
  /// The newly created panel's ID.
  new_panel_id : Int
  /// The session ID of the new panel (maps to SessionManager).
  new_session_id : Int
  /// The PTY master fd for the new session (-1 on failure).
  master_fd : Int
  /// Updated dimensions of the *existing* panel after shrinking.
  existing_rows : Int
  existing_cols : Int
} derive(Show)

///|
/// Panel info snapshot for querying the current state of all panels
/// in a tab — used for FFI serialization.
pub struct PanelSnapshot {
  panel_id : Int
  session_id : Int
  rows : Int
  cols : Int
  focused : Bool
} derive(Show)

///|
/// Direction for focus navigation (Cmd+Alt+Arrow).
pub(all) enum FocusDirection {
  Up
  Down
  Left
  Right
} derive(Show, Eq)

///|
/// Panel backend mode — determines how panels are managed.
///
/// Native: each panel = independent PTY + shell (primary implementation).
/// Multiplexer: single PTY running tmux/screen; panels are virtual.
///   In Multiplexer mode, split/close/focus operations send tmux control
///   commands instead of creating sessions.
///
/// This enum is the integration point for future tmux/screen support.
/// Currently only Native is implemented.
pub(all) enum PanelBackend {
  /// Each panel owns an independent PTY with its own shell process.
  Native
} derive(Show)
