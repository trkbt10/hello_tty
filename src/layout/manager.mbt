///|
/// LayoutManager — coordinates tabs, panels, and sessions.
///
/// This is the top-level coordinator that sits above SessionManager.
/// It owns the tab/panel layout tree and delegates session lifecycle
/// (PTY spawning, terminal init) to the existing SessionManager.
///
/// Design principles:
///   - SessionManager is unchanged — LayoutManager wraps it
///   - Each panel maps 1:1 to a Session
///   - MoonBit is the SoT for layout structure, focus, and resize
///   - Platform adapters receive layout info via FFI and render accordingly
pub struct LayoutManager {
  tabs : Map[Int, Tab]
  workspaces : Map[Int, Array[Int]]
  workspace_active_tabs : Map[Int, Int]
  tab_workspace : Map[Int, Int]
  mut workspace_order : Array[Int]
  sessions : @session.SessionManager
  mut active_workspace_id : Int
  mut active_tab_id : Int
  mut next_workspace_id : Int
  mut next_tab_id : Int
  mut next_panel_id : Int
  /// Divider size in grid cells (typically 1).
  divider_size : Int
  /// Last known total grid dimensions from the container.
  /// Stored so that ratio adjustments can re-propagate dimensions
  /// through the tree without needing the caller to pass them again.
  mut last_total_rows : Int
  mut last_total_cols : Int
}

///|
pub fn LayoutManager::new(sessions : @session.SessionManager) -> LayoutManager {
  {
    tabs: {},
    workspaces: {},
    workspace_active_tabs: {},
    tab_workspace: {},
    workspace_order: [],
    sessions,
    active_workspace_id: -1,
    active_tab_id: -1,
    next_workspace_id: 1,
    next_tab_id: 1,
    next_panel_id: 1,
    divider_size: 1,
    last_total_rows: 24,
    last_total_cols: 80,
  }
}

// ========== Tab Operations ==========

///|
/// Create a new tab with a single panel.
///
/// This is the primary entry point for creating tabs. It:
///   1. Allocates a new panel ID
///   2. Creates a Session via SessionManager (terminal init + PTY spawn)
///   3. Creates a Tab with a single Leaf layout
///   4. Activates the new tab
///
/// Returns (tab_id, panel_id, master_fd).
/// The platform adapter uses master_fd to start the PTY I/O loop.
pub fn LayoutManager::create_tab(
  self : LayoutManager,
  rows : Int,
  cols : Int,
) -> (Int, Int, Int) {
  let workspace_id = self.ensure_active_workspace()
  let tab_id = self.next_tab_id
  self.next_tab_id += 1
  let panel_id = self.next_panel_id
  self.next_panel_id += 1
  // Delegate session creation to SessionManager
  let (session_id, master_fd) = self.sessions.create_session(rows, cols)
  let panel = PanelInfo::{ panel_id, session_id, rows, cols }
  let tab = Tab::{
    id: tab_id,
    layout: Leaf(panel),
    focused_panel_id: panel_id,
    title: "",
  }
  self.tabs[tab_id] = tab
  let order = self.workspace_tab_order(workspace_id)
  order.push(tab_id)
  self.workspace_active_tabs[workspace_id] = tab_id
  self.tab_workspace[tab_id] = workspace_id
  self.active_workspace_id = workspace_id
  self.active_tab_id = tab_id
  // Keep SessionManager's active_id in sync
  self.sessions.switch_to(session_id) |> ignore
  (tab_id, panel_id, master_fd)
}

///|
/// Close a tab and destroy all its sessions.
///
/// After closing:
///   - If other tabs exist, activates the nearest one
///   - If no tabs remain, active_tab_id becomes -1
pub fn LayoutManager::close_tab(self : LayoutManager, tab_id : Int) -> Unit {
  let workspace_id = match self.tab_workspace.get(tab_id) {
    Some(id) => id
    None => return
  }
  let order = self.workspace_tab_order(workspace_id)
  let removed_index = order.search(tab_id)
  match self.tabs.get(tab_id) {
    Some(tab) => {
      // Destroy all sessions in this tab
      let leaves = collect_leaves(tab.layout)
      for leaf in leaves {
        self.sessions.destroy_session(leaf.session_id)
      }
      self.tabs.remove(tab_id) |> ignore
      self.tab_workspace.remove(tab_id) |> ignore
      let new_order = remove_tab_id(order, tab_id)
      if new_order.is_empty() {
        self.workspaces.remove(workspace_id) |> ignore
        self.workspace_active_tabs.remove(workspace_id) |> ignore
        self.workspace_order = remove_tab_id(self.workspace_order, workspace_id)
        if self.active_workspace_id == workspace_id {
          self.activate_fallback_workspace_after_close(workspace_id)
        }
      } else {
        self.workspaces[workspace_id] = new_order
        if self.workspace_active_tabs.get(workspace_id) == Some(tab_id) {
          let next_tab_id = next_active_tab_id_after_close(
            new_order, removed_index,
          )
          self.workspace_active_tabs[workspace_id] = next_tab_id
          if self.active_workspace_id == workspace_id {
            self.active_tab_id = next_tab_id
          }
        }
      }
      if self.active_workspace_id == workspace_id {
        self.sync_active_session()
      }
    }
    None => ()
  }
}

///|
/// Switch to a different tab by ID.
pub fn LayoutManager::switch_tab(self : LayoutManager, tab_id : Int) -> Bool {
  match self.tab_workspace.get(tab_id) {
    Some(workspace_id) => {
      self.active_workspace_id = workspace_id
      self.workspace_active_tabs[workspace_id] = tab_id
      self.active_tab_id = tab_id
      self.sync_active_session()
      true
    }
    None => false
  }
}

///|
/// Switch to a different workspace by ID.
pub fn LayoutManager::activate_workspace(
  self : LayoutManager,
  workspace_id : Int,
) -> Bool {
  if self.workspaces.contains(workspace_id) {
    self.active_workspace_id = workspace_id
    self.active_tab_id = self.workspace_active_tab_id(workspace_id)
    self.sync_active_session()
    true
  } else {
    false
  }
}

///|
/// Switch to the next tab (wraps around) inside the active workspace.
pub fn LayoutManager::next_tab(self : LayoutManager) -> Bool {
  let ids = self.active_workspace_tab_order()
  if ids.length() <= 1 {
    return false
  }
  let current_idx = ids.search(self.active_tab_id)
  match current_idx {
    Some(idx) => {
      let next_idx = (idx + 1) % ids.length()
      self.switch_tab(ids[next_idx])
    }
    None => false
  }
}

///|
/// Switch to the previous tab (wraps around) inside the active workspace.
pub fn LayoutManager::prev_tab(self : LayoutManager) -> Bool {
  let ids = self.active_workspace_tab_order()
  if ids.length() <= 1 {
    return false
  }
  let current_idx = ids.search(self.active_tab_id)
  match current_idx {
    Some(idx) => {
      let prev_idx = if idx == 0 { ids.length() - 1 } else { idx - 1 }
      self.switch_tab(ids[prev_idx])
    }
    None => false
  }
}

///|
/// Get the currently active tab.
pub fn LayoutManager::active_tab(self : LayoutManager) -> Tab? {
  self.tabs.get(self.active_tab_id)
}

///|
/// List all tabs in the active workspace: (id, title, is_active).
pub fn LayoutManager::list_tabs(
  self : LayoutManager,
) -> Array[(Int, String, Bool)] {
  let result : Array[(Int, String, Bool)] = []
  for id in self.active_workspace_tab_order() {
    match self.tabs.get(id) {
      Some(tab) => result.push((id, tab.title, id == self.active_tab_id))
      None => ()
    }
  }
  result
}

///|
pub fn LayoutManager::tab_count(self : LayoutManager) -> Int {
  self.active_workspace_tab_order().length()
}

///|
pub fn LayoutManager::can_detach_tab_to_new_workspace(
  self : LayoutManager,
  tab_id : Int,
) -> Bool {
  match self.tab_workspace.get(tab_id) {
    Some(workspace_id) => self.workspace_tab_order(workspace_id).length() > 1
    None => false
  }
}

///|
/// Reorder a tab within its current workspace tab strip order.
pub fn LayoutManager::reorder_tab(
  self : LayoutManager,
  tab_id : Int,
  target_index : Int,
) -> Bool {
  let workspace_id = match self.tab_workspace.get(tab_id) {
    Some(id) => id
    None => return false
  }
  let current_order = self.workspace_tab_order(workspace_id)
  let current_index = match current_order.search(tab_id) {
    Some(index) => index
    None => return false
  }
  let max_index = current_order.length() - 1
  let clamped_target = target_index.clamp(min=0, max=max_index)
  if current_index == clamped_target {
    return true
  }
  let order_without = remove_tab_id(current_order, tab_id)
  self.workspaces[workspace_id] = insert_tab_id(
    order_without, tab_id, clamped_target,
  )
  true
}

///|
/// Detach a tab into a newly created workspace.
pub fn LayoutManager::detach_tab_to_new_workspace(
  self : LayoutManager,
  tab_id : Int,
) -> Int {
  if !self.can_detach_tab_to_new_workspace(tab_id) {
    return -1
  }
  let source_workspace_id = match self.tab_workspace.get(tab_id) {
    Some(id) => id
    None => return -1
  }
  let source_order = self.workspace_tab_order(source_workspace_id)
  let removed_index = source_order.search(tab_id)
  let workspace_id = self.create_workspace()
  self.workspaces[workspace_id] = [tab_id]
  self.workspace_active_tabs[workspace_id] = tab_id
  self.tab_workspace[tab_id] = workspace_id
  self.active_workspace_id = workspace_id
  self.active_tab_id = tab_id
  let new_source_order = remove_tab_id(source_order, tab_id)
  if new_source_order.is_empty() {
    self.workspaces.remove(source_workspace_id) |> ignore
    self.workspace_active_tabs.remove(source_workspace_id) |> ignore
    self.workspace_order = remove_tab_id(
      self.workspace_order,
      source_workspace_id,
    )
  } else {
    self.workspaces[source_workspace_id] = new_source_order
    if self.workspace_active_tabs.get(source_workspace_id) == Some(tab_id) {
      self.workspace_active_tabs[source_workspace_id] = next_active_tab_id_after_close(
        new_source_order, removed_index,
      )
    }
  }
  self.sync_active_session()
  workspace_id
}

///|
/// Attach a tab into a target workspace at the requested index.
pub fn LayoutManager::attach_tab_to_workspace(
  self : LayoutManager,
  tab_id : Int,
  workspace_id : Int,
  target_index : Int,
) -> Bool {
  if !self.workspaces.contains(workspace_id) {
    return false
  }
  let source_workspace_id = match self.tab_workspace.get(tab_id) {
    Some(id) => id
    None => return false
  }
  if source_workspace_id == workspace_id {
    return self.reorder_tab(tab_id, target_index)
  }
  let source_order = self.workspace_tab_order(source_workspace_id)
  let removed_index = source_order.search(tab_id)
  let new_source_order = remove_tab_id(source_order, tab_id)
  if new_source_order.is_empty() {
    self.workspaces.remove(source_workspace_id) |> ignore
    self.workspace_active_tabs.remove(source_workspace_id) |> ignore
    self.workspace_order = remove_tab_id(
      self.workspace_order,
      source_workspace_id,
    )
  } else {
    self.workspaces[source_workspace_id] = new_source_order
    if self.workspace_active_tabs.get(source_workspace_id) == Some(tab_id) {
      self.workspace_active_tabs[source_workspace_id] = next_active_tab_id_after_close(
        new_source_order, removed_index,
      )
    }
  }
  let target_order = self.workspace_tab_order(workspace_id)
  self.workspaces[workspace_id] = insert_tab_id(
    target_order, tab_id, target_index,
  )
  self.workspace_active_tabs[workspace_id] = tab_id
  self.tab_workspace[tab_id] = workspace_id
  self.active_workspace_id = workspace_id
  self.active_tab_id = tab_id
  self.sync_active_session()
  true
}

///|
/// Merge a dragged tab into the currently visible tab by splitting a target panel.
///
/// The dragged tab's entire panel layout becomes one side of the new split.
/// This is the MoonBit SoT for "drop tab on panel to split".
pub fn LayoutManager::merge_tab_into_panel(
  self : LayoutManager,
  tab_id : Int,
  target_panel_id : Int,
  direction : SplitDirection,
) -> Bool {
  let source_workspace_id = match self.tab_workspace.get(tab_id) {
    Some(id) => id
    None => return false
  }
  let source_tab = match self.tabs.get(tab_id) {
    Some(tab) => tab
    None => return false
  }
  let target_tab = match self.active_tab() {
    Some(tab) => tab
    None => return false
  }
  if target_tab.id == tab_id {
    return false
  }
  let target_workspace_id = match self.tab_workspace.get(target_tab.id) {
    Some(id) => id
    None => return false
  }
  let target_panel = match find_panel(target_tab.layout, target_panel_id) {
    Some(panel) => panel
    None => return false
  }
  let ratio : Float = 0.5
  if !can_split(
      target_panel.rows,
      target_panel.cols,
      direction,
      ratio,
      self.divider_size,
    ) {
    return false
  }
  let source_layout = source_tab.layout
  let source_focused_panel_id = source_tab.focused_panel_id
  let replacement = Split(direction, Leaf(target_panel), source_layout, ratio)
  let new_root = match
    replace_leaf(target_tab.layout, target_panel_id, replacement) {
    Some(root) => root
    None => return false
  }
  target_tab.layout = new_root
  target_tab.focused_panel_id = source_focused_panel_id
  resize_tree(
    new_root,
    self.last_total_rows,
    self.last_total_cols,
    self.divider_size,
  )
  self.sync_session_sizes(target_tab)
  self.tabs.remove(tab_id) |> ignore
  self.tab_workspace.remove(tab_id) |> ignore
  let source_order = self.workspace_tab_order(source_workspace_id)
  let removed_index = source_order.search(tab_id)
  let new_source_order = remove_tab_id(source_order, tab_id)
  if new_source_order.is_empty() {
    self.workspaces.remove(source_workspace_id) |> ignore
    self.workspace_active_tabs.remove(source_workspace_id) |> ignore
    self.workspace_order = remove_tab_id(
      self.workspace_order,
      source_workspace_id,
    )
  } else {
    self.workspaces[source_workspace_id] = new_source_order
    if self.workspace_active_tabs.get(source_workspace_id) == Some(tab_id) {
      let replacement_tab_id = if source_workspace_id == target_workspace_id {
        target_tab.id
      } else {
        next_active_tab_id_after_close(new_source_order, removed_index)
      }
      self.workspace_active_tabs[source_workspace_id] = replacement_tab_id
    }
  }
  self.active_workspace_id = target_workspace_id
  self.workspace_active_tabs[target_workspace_id] = target_tab.id
  self.active_tab_id = target_tab.id
  self.sync_active_session()
  true
}

///|
pub fn LayoutManager::list_workspaces(
  self : LayoutManager,
) -> Array[WorkspaceSnapshot] {
  let result : Array[WorkspaceSnapshot] = []
  for workspace_id in self.workspace_order {
    let tabs : Array[WorkspaceTabSnapshot] = []
    let active_tab_id = self.workspace_active_tab_id(workspace_id)
    for tab_id in self.workspace_tab_order(workspace_id) {
      match self.tabs.get(tab_id) {
        Some(tab) =>
          tabs.push(WorkspaceTabSnapshot::{
            tab_id,
            title: tab.title,
            active: tab_id == active_tab_id,
            panel_count: count_leaves(tab.layout),
            focused_panel_id: tab.focused_panel_id,
          })
        None => ()
      }
    }
    result.push(WorkspaceSnapshot::{
      workspace_id,
      active: workspace_id == self.active_workspace_id,
      active_tab_id,
      tabs,
    })
  }
  result
}

///|
pub fn LayoutManager::get_active_workspace_id(self : LayoutManager) -> Int {
  self.active_workspace_id
}

///|
fn LayoutManager::ensure_active_workspace(self : LayoutManager) -> Int {
  if self.active_workspace_id >= 0 &&
    self.workspaces.contains(self.active_workspace_id) {
    self.active_workspace_id
  } else {
    self.create_workspace()
  }
}

///|
fn LayoutManager::create_workspace(self : LayoutManager) -> Int {
  let workspace_id = self.next_workspace_id
  self.next_workspace_id += 1
  self.workspaces[workspace_id] = []
  self.workspace_active_tabs[workspace_id] = -1
  self.workspace_order.push(workspace_id)
  self.active_workspace_id = workspace_id
  workspace_id
}

///|
fn LayoutManager::workspace_tab_order(
  self : LayoutManager,
  workspace_id : Int,
) -> Array[Int] {
  match self.workspaces.get(workspace_id) {
    Some(order) => order
    None => []
  }
}

///|
fn LayoutManager::active_workspace_tab_order(
  self : LayoutManager,
) -> Array[Int] {
  self.workspace_tab_order(self.active_workspace_id)
}

///|
fn LayoutManager::workspace_active_tab_id(
  self : LayoutManager,
  workspace_id : Int,
) -> Int {
  match self.workspace_active_tabs.get(workspace_id) {
    Some(tab_id) => tab_id
    None => -1
  }
}

///|
fn LayoutManager::activate_fallback_workspace_after_close(
  self : LayoutManager,
  _closed_workspace_id : Int,
) -> Unit {
  if self.workspace_order.is_empty() {
    self.active_workspace_id = -1
    self.active_tab_id = -1
  } else {
    let fallback_workspace_id = self.workspace_order[0]
    self.active_workspace_id = fallback_workspace_id
    self.active_tab_id = self.workspace_active_tab_id(fallback_workspace_id)
  }
}

///|
fn LayoutManager::sync_active_session(self : LayoutManager) -> Unit {
  match self.active_tab() {
    Some(tab) =>
      match find_panel(tab.layout, tab.focused_panel_id) {
        Some(info) => self.sessions.switch_to(info.session_id) |> ignore
        None => ()
      }
    None => ()
  }
}

// ========== Panel Operations ==========

///|
/// Split the specified panel, creating a new panel in the given direction.
///
/// Steps:
///   1. Validate that the split is feasible (minimum sizes)
///   2. Create a new Session via SessionManager
///   3. Replace the target Leaf with a Split(Leaf_resized, Leaf_new)
///   4. Resize both sessions' terminal grids
///   5. Move focus to the new panel
///
/// Returns SplitResult on success, None if the split would create
/// panels below minimum size.
pub fn LayoutManager::split_panel(
  self : LayoutManager,
  panel_id : Int,
  direction : SplitDirection,
) -> SplitResult? {
  self.split_panel_with_ratio(panel_id, direction, 0.5)
}

///|
/// Split with a custom ratio.
pub fn LayoutManager::split_panel_with_ratio(
  self : LayoutManager,
  panel_id : Int,
  direction : SplitDirection,
  ratio : Float,
) -> SplitResult? {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return None
  }
  let panel = match find_panel(tab.layout, panel_id) {
    Some(p) => p
    None => return None
  }
  // Check feasibility
  if !can_split(panel.rows, panel.cols, direction, ratio, self.divider_size) {
    return None
  }
  // Compute new dimensions
  let (first_rows, first_cols, second_rows, second_cols) = match direction {
    Horizontal => {
      let available = panel.rows - self.divider_size
      let fr = (Float::from_int(available) * ratio).to_int()
      let sr = available - fr
      (fr, panel.cols, sr, panel.cols)
    }
    Vertical => {
      let available = panel.cols - self.divider_size
      let fc = (Float::from_int(available) * ratio).to_int()
      let sc = available - fc
      (panel.rows, fc, panel.rows, sc)
    }
  }
  // Create new session
  let (new_session_id, master_fd) = self.sessions.create_session(
    second_rows, second_cols,
  )
  let new_panel_id = self.next_panel_id
  self.next_panel_id += 1
  let new_panel = PanelInfo::{
    panel_id: new_panel_id,
    session_id: new_session_id,
    rows: second_rows,
    cols: second_cols,
  }
  // Resize the existing panel's session
  panel.rows = first_rows
  panel.cols = first_cols
  match self.sessions.get_session(panel.session_id) {
    Some(session) => session.resize(first_rows, first_cols)
    None => ()
  }
  // Build the replacement subtree
  let replacement = Split(direction, Leaf(panel), Leaf(new_panel), ratio)
  // Replace in the tree
  match replace_leaf(tab.layout, panel_id, replacement) {
    Some(new_root) => tab.layout = new_root
    None => ()
  }
  // Focus the new panel
  tab.focused_panel_id = new_panel_id
  self.sessions.switch_to(new_session_id) |> ignore
  Some(SplitResult::{
    new_panel_id,
    new_session_id,
    master_fd,
    existing_rows: first_rows,
    existing_cols: first_cols,
  })
}

///|
/// Close a panel. The sibling expands to fill the space.
///
/// If this is the last panel in the tab, the tab is closed.
/// Returns the session_id of the focused panel after closing,
/// or -1 if the tab was closed.
pub fn LayoutManager::close_panel(self : LayoutManager, panel_id : Int) -> Int {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return -1
  }
  let panel = match find_panel(tab.layout, panel_id) {
    Some(p) => p
    None => return -1
  }
  let session_id = panel.session_id
  // Check if this is the last panel
  if count_leaves(tab.layout) <= 1 {
    // Close the entire tab
    self.close_tab(tab.id)
    return -1
  }
  // Find a sibling for focus fallback before removing
  let new_focus = find_sibling_panel(tab.layout, panel_id)
  // Remove the panel from the tree
  match remove_panel(tab.layout, panel_id) {
    Some(new_root) => {
      tab.layout = new_root
      // Destroy the session
      self.sessions.destroy_session(session_id)
      // Update focus
      match new_focus {
        Some(sibling) => {
          tab.focused_panel_id = sibling.panel_id
          self.sessions.switch_to(sibling.session_id) |> ignore
          // Resize the tree to fill the freed space using the stored
          // total dimensions (the container size hasn't changed).
          resize_tree(
            new_root,
            self.last_total_rows,
            self.last_total_cols,
            self.divider_size,
          )
          // Apply resize to all sessions
          self.sync_session_sizes(tab)
          sibling.session_id
        }
        None => -1
      }
    }
    None => -1
  }
}

///|
/// Detach a panel from the current tab's split layout and create a new tab
/// for it in the same workspace. The panel's session is preserved (not destroyed).
///
/// Returns the new tab ID, or -1 on failure.
/// Fails if the panel is the only panel in its tab (nothing to detach from).
pub fn LayoutManager::detach_panel_to_tab(
  self : LayoutManager,
  panel_id : Int
) -> Int {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return -1
  }
  // Cannot detach the only panel — that's just the tab itself.
  if count_leaves(tab.layout) <= 1 {
    return -1
  }
  let panel = match find_panel(tab.layout, panel_id) {
    Some(p) => p
    None => return -1
  }
  // Find a sibling for focus fallback in the source tab.
  let new_focus = match find_sibling_panel(tab.layout, panel_id) {
    Some(s) => s
    None => return -1
  }
  // Remove the panel from the source tab's layout tree.
  let new_root = match remove_panel(tab.layout, panel_id) {
    Some(r) => r
    None => return -1
  }
  tab.layout = new_root
  tab.focused_panel_id = new_focus.panel_id
  self.sessions.switch_to(new_focus.session_id) |> ignore
  // Resize the source tab to fill the freed space.
  resize_tree(new_root, self.last_total_rows, self.last_total_cols, self.divider_size)
  self.sync_session_sizes(tab)
  // Create a new tab with the detached panel as its sole layout node.
  let workspace_id = self.active_workspace_id
  let new_tab_id = self.next_tab_id
  self.next_tab_id += 1
  let new_tab = Tab::{
    id: new_tab_id,
    layout: Leaf(panel),
    focused_panel_id: panel_id,
    title: "",
  }
  self.tabs[new_tab_id] = new_tab
  let order = self.workspace_tab_order(workspace_id)
  order.push(new_tab_id)
  self.tab_workspace[new_tab_id] = workspace_id
  // Switch to the new tab.
  self.workspace_active_tabs[workspace_id] = new_tab_id
  self.active_tab_id = new_tab_id
  self.sessions.switch_to(panel.session_id) |> ignore
  // Resize the new tab's panel to the full container.
  resize_tree(
    new_tab.layout,
    self.last_total_rows,
    self.last_total_cols,
    self.divider_size,
  )
  self.sync_session_sizes(new_tab)
  self.sync_active_session()
  new_tab_id
}

///|
/// Focus a panel by ID.
pub fn LayoutManager::focus_panel(self : LayoutManager, panel_id : Int) -> Bool {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return false
  }
  match find_panel(tab.layout, panel_id) {
    Some(info) => {
      tab.focused_panel_id = panel_id
      self.sessions.switch_to(info.session_id) |> ignore
      true
    }
    None => false
  }
}

///|
/// Focus panel by DFS index (0-based). Used for Cmd+1/2/3.
pub fn LayoutManager::focus_panel_by_index(
  self : LayoutManager,
  index : Int,
) -> Bool {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return false
  }
  match panel_at_index(tab.layout, index) {
    Some(info) => {
      tab.focused_panel_id = info.panel_id
      self.sessions.switch_to(info.session_id) |> ignore
      true
    }
    None => false
  }
}

///|
/// Focus the neighboring panel in the given direction.
pub fn LayoutManager::focus_direction(
  self : LayoutManager,
  direction : FocusDirection,
) -> Bool {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return false
  }
  match find_neighbor(tab.layout, tab.focused_panel_id, direction) {
    Some(info) => {
      tab.focused_panel_id = info.panel_id
      self.sessions.switch_to(info.session_id) |> ignore
      true
    }
    None => false
  }
}

///|
/// Get the currently focused panel's info.
pub fn LayoutManager::focused_panel(self : LayoutManager) -> PanelInfo? {
  match self.active_tab() {
    Some(tab) => find_panel(tab.layout, tab.focused_panel_id)
    None => None
  }
}

///|
/// Get the focused panel ID, or -1 if none.
pub fn LayoutManager::get_focused_panel_id(self : LayoutManager) -> Int {
  match self.active_tab() {
    Some(tab) => tab.focused_panel_id
    None => -1
  }
}

// ========== Resize ==========

///|
/// Resize all panels in the active tab to fit new total dimensions.
///
/// Called when the window is resized. Propagates dimensions through
/// the layout tree using ratios, then syncs each Session's terminal grid.
pub fn LayoutManager::resize_all(
  self : LayoutManager,
  total_rows : Int,
  total_cols : Int,
) -> Unit {
  self.last_total_rows = total_rows
  self.last_total_cols = total_cols
  match self.active_tab() {
    Some(tab) => {
      resize_tree(tab.layout, total_rows, total_cols, self.divider_size)
      self.sync_session_sizes(tab)
    }
    None => ()
  }
}

///|
/// Sync all sessions in a tab to match their panel's dimensions.
fn LayoutManager::sync_session_sizes(self : LayoutManager, tab : Tab) -> Unit {
  let leaves = collect_leaves(tab.layout)
  for leaf in leaves {
    match self.sessions.get_session(leaf.session_id) {
      Some(session) => session.resize(leaf.rows, leaf.cols)
      None => ()
    }
  }
}

// ========== Query ==========

///|
/// Get all panel snapshots for the active tab.
pub fn LayoutManager::get_all_panels(
  self : LayoutManager,
) -> Array[PanelSnapshot] {
  match self.active_tab() {
    Some(tab) => {
      let leaves = collect_leaves(tab.layout)
      let focused_id = tab.focused_panel_id
      leaves.map(fn(leaf) {
        PanelSnapshot::{
          panel_id: leaf.panel_id,
          session_id: leaf.session_id,
          rows: leaf.rows,
          cols: leaf.cols,
          focused: leaf.panel_id == focused_id,
        }
      })
    }
    None => []
  }
}

///|
/// Get the layout tree of the active tab.
pub fn LayoutManager::get_active_layout(self : LayoutManager) -> LayoutNode? {
  match self.active_tab() {
    Some(tab) => Some(tab.layout)
    None => None
  }
}

///|
/// Get the active tab ID.
pub fn LayoutManager::get_active_tab_id(self : LayoutManager) -> Int {
  self.active_tab_id
}

///|
/// Get the underlying SessionManager (for session-targeted operations).
pub fn LayoutManager::get_sessions(
  self : LayoutManager,
) -> @session.SessionManager {
  self.sessions
}

///|
/// Update tab title from the focused session's terminal title.
pub fn LayoutManager::update_tab_title(self : LayoutManager) -> Unit {
  match self.active_tab() {
    Some(tab) =>
      match find_panel(tab.layout, tab.focused_panel_id) {
        Some(info) =>
          match self.sessions.get_session(info.session_id) {
            Some(session) => tab.title = session.get_title()
            None => ()
          }
        None => ()
      }
    None => ()
  }
}

// ========== Divider Resize ==========

///|
/// Notify that the first child of a split (identified by its first leaf's
/// panel_id) has been given `first_size` cells along the split axis.
///
/// The platform adapter knows divider positions in pixels and converts
/// to cells before calling this. MoonBit computes the new ratio from
/// the pixel-derived cell sizes, then re-propagates dimensions through
/// the tree and syncs sessions.
///
/// This is the correct boundary: the adapter says "this panel area is now
/// this size", and MoonBit updates its internal ratio accordingly.
pub fn LayoutManager::notify_panel_resize(
  self : LayoutManager,
  panel_id : Int,
  first_size : Int,
  total_size : Int,
) -> Bool {
  let tab = match self.active_tab() {
    Some(t) => t
    None => return false
  }
  guard total_size > 0 else { return false }
  let new_ratio = Float::from_int(first_size) / Float::from_int(total_size)
  let clamped = new_ratio.clamp(min=0.15, max=0.85)
  match set_ratio_for_panel(tab.layout, panel_id, clamped) {
    Some(new_root) => {
      tab.layout = new_root
      resize_tree(
        new_root,
        self.last_total_rows,
        self.last_total_cols,
        self.divider_size,
      )
      self.sync_session_sizes(tab)
      true
    }
    None => false
  }
}

///|
/// Find the nearest ancestor split of a panel and set its ratio to the given value.
fn set_ratio_for_panel(
  node : LayoutNode,
  panel_id : Int,
  new_ratio : Float,
) -> LayoutNode? {
  match node {
    Leaf(_) => None
    Split(dir, first, second, ratio) => {
      let in_first = is_or_contains(first, panel_id)
      let in_second = is_or_contains(second, panel_id)
      if !in_first && !in_second {
        return None
      }
      // Check if the target is a direct child of this split
      let is_direct_child = match first {
        Leaf(info) if info.panel_id == panel_id => true
        _ =>
          match second {
            Leaf(info) if info.panel_id == panel_id => true
            _ => false
          }
      }
      if is_direct_child {
        Some(Split(dir, first, second, new_ratio))
        // Recurse into the subtree containing the target
      } else if in_first {
        match set_ratio_for_panel(first, panel_id, new_ratio) {
          Some(new_first) => Some(Split(dir, new_first, second, ratio))
          None => None
        }
      } else {
        match set_ratio_for_panel(second, panel_id, new_ratio) {
          Some(new_second) => Some(Split(dir, first, new_second, ratio))
          None => None
        }
      }
    }
  }
}

// ========== Shutdown ==========

///|
/// Destroy all tabs and sessions.
pub fn LayoutManager::destroy_all(self : LayoutManager) -> Unit {
  self.tabs.clear()
  self.workspaces.clear()
  self.workspace_active_tabs.clear()
  self.tab_workspace.clear()
  self.workspace_order.clear()
  self.active_workspace_id = -1
  self.active_tab_id = -1
  self.sessions.destroy_all()
}

///|
fn remove_tab_id(order : Array[Int], tab_id : Int) -> Array[Int] {
  let result : Array[Int] = []
  for id in order {
    if id != tab_id {
      result.push(id)
    }
  }
  result
}

///|
fn insert_tab_id(
  order : Array[Int],
  tab_id : Int,
  target_index : Int,
) -> Array[Int] {
  let result : Array[Int] = []
  let mut inserted = false
  let clamped_target = target_index.clamp(min=0, max=order.length())
  let mut index = 0
  for id in order {
    if !inserted && index == clamped_target {
      result.push(tab_id)
      inserted = true
    }
    result.push(id)
    index += 1
  }
  if !inserted {
    result.push(tab_id)
  }
  result
}

///|
fn next_active_tab_id_after_close(
  order : Array[Int],
  removed_index : Int?,
) -> Int {
  if order.is_empty() {
    return -1
  }
  match removed_index {
    Some(index) => {
      let fallback_index = index.clamp(min=0, max=order.length() - 1)
      order[fallback_index]
    }
    None => order[0]
  }
}
