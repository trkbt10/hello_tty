///|
/// Tree traversal and manipulation utilities for LayoutNode.
///
/// The layout tree is a strict binary tree. These functions provide
/// the fundamental operations needed by LayoutManager:
///   - Finding panels by ID
///   - Collecting all leaves (for resize, serialization)
///   - DFS indexing (for Cmd+1/2/3 focus-by-index)
///   - Structural mutations (split insertion, panel removal)
///   - Recursive resize propagation

///|
/// Find a panel by ID in the tree. Returns the PanelInfo if found.
pub fn find_panel(node : LayoutNode, panel_id : Int) -> PanelInfo? {
  match node {
    Leaf(info) => if info.panel_id == panel_id { Some(info) } else { None }
    Split(_, first, second, _) =>
      match find_panel(first, panel_id) {
        Some(_) as found => found
        None => find_panel(second, panel_id)
      }
  }
}

///|
/// Collect all leaf panels in DFS order (left-to-right, top-to-bottom).
/// This ordering is used for Cmd+1/2/3 panel indexing.
pub fn collect_leaves(node : LayoutNode) -> Array[PanelInfo] {
  let result : Array[PanelInfo] = []
  collect_leaves_into(node, result)
  result
}

///|
fn collect_leaves_into(node : LayoutNode, acc : Array[PanelInfo]) -> Unit {
  match node {
    Leaf(info) => acc.push(info)
    Split(_, first, second, _) => {
      collect_leaves_into(first, acc)
      collect_leaves_into(second, acc)
    }
  }
}

///|
/// Get the DFS index of a panel (0-based). Returns -1 if not found.
pub fn dfs_index_of(node : LayoutNode, panel_id : Int) -> Int {
  let counter : Ref[Int] = Ref::new(0)
  dfs_index_search(node, panel_id, counter)
}

///|
fn dfs_index_search(node : LayoutNode, panel_id : Int, counter : Ref[Int]) -> Int {
  match node {
    Leaf(info) =>
      if info.panel_id == panel_id {
        counter.val
      } else {
        counter.val += 1
        -1
      }
    Split(_, first, second, _) => {
      let found = dfs_index_search(first, panel_id, counter)
      if found >= 0 {
        found
      } else {
        dfs_index_search(second, panel_id, counter)
      }
    }
  }
}

///|
/// Find the panel at DFS index `target` (0-based). Returns None if out of range.
pub fn panel_at_index(node : LayoutNode, target : Int) -> PanelInfo? {
  let counter : Ref[Int] = Ref::new(0)
  panel_at_index_search(node, target, counter)
}

///|
fn panel_at_index_search(
  node : LayoutNode,
  target : Int,
  counter : Ref[Int],
) -> PanelInfo? {
  match node {
    Leaf(info) =>
      if counter.val == target {
        Some(info)
      } else {
        counter.val += 1
        None
      }
    Split(_, first, second, _) =>
      match panel_at_index_search(first, target, counter) {
        Some(_) as found => found
        None => panel_at_index_search(second, target, counter)
      }
  }
}

///|
/// Count the total number of leaf panels in the tree.
pub fn count_leaves(node : LayoutNode) -> Int {
  match node {
    Leaf(_) => 1
    Split(_, first, second, _) => count_leaves(first) + count_leaves(second)
  }
}

///|
/// Replace a Leaf(panel_id) with a new subtree. Returns the new root.
///
/// This is used for splitting: the target leaf is replaced with a Split
/// node containing the (resized) original leaf and a new leaf.
///
/// Returns None if panel_id was not found.
pub fn replace_leaf(
  node : LayoutNode,
  panel_id : Int,
  replacement : LayoutNode,
) -> LayoutNode? {
  match node {
    Leaf(info) =>
      if info.panel_id == panel_id {
        Some(replacement)
      } else {
        None
      }
    Split(dir, first, second, ratio) =>
      match replace_leaf(first, panel_id, replacement) {
        Some(new_first) =>
          Some(Split(dir, new_first, second, ratio))
        None =>
          match replace_leaf(second, panel_id, replacement) {
            Some(new_second) =>
              Some(Split(dir, first, new_second, ratio))
            None => None
          }
      }
  }
}

///|
/// Remove a panel from the tree. The sibling of the removed panel
/// takes the parent's place.
///
/// Returns:
///   - Some(new_root) if panel was found and removed
///   - None if panel was not found, or if the tree is a single Leaf
///     (cannot remove the last panel through this function)
pub fn remove_panel(node : LayoutNode, panel_id : Int) -> LayoutNode? {
  match node {
    Leaf(_) =>
      // Cannot remove a single leaf — the caller (LayoutManager) handles
      // the "last panel in tab" case before calling this.
      None
    Split(_, first, second, _) =>
      // Check if either direct child is the target leaf
      match first {
        Leaf(info) if info.panel_id == panel_id => Some(second)
        _ =>
          match second {
            Leaf(info) if info.panel_id == panel_id => Some(first)
            _ =>
              // Recurse into children
              match remove_panel(first, panel_id) {
                Some(new_first) =>
                  Some(Split(node.direction(), new_first, second, node.ratio()))
                None =>
                  match remove_panel(second, panel_id) {
                    Some(new_second) =>
                      Some(Split(node.direction(), first, new_second, node.ratio()))
                    None => None
                  }
              }
          }
      }
  }
}

///|
/// Get the direction of a LayoutNode. Panics on Leaf.
fn LayoutNode::direction(self : LayoutNode) -> SplitDirection {
  match self {
    Split(dir, _, _, _) => dir
    Leaf(_) => abort("direction() called on Leaf")
  }
}

///|
/// Get the ratio of a LayoutNode. Panics on Leaf.
fn LayoutNode::ratio(self : LayoutNode) -> Float {
  match self {
    Split(_, _, _, ratio) => ratio
    Leaf(_) => abort("ratio() called on Leaf")
  }
}

///|
/// Propagate dimensions through the tree recursively.
///
/// Given the total available rows and cols for this subtree,
/// compute each leaf's allocated size based on split ratios.
/// Updates PanelInfo.rows and PanelInfo.cols in place.
///
/// `divider_size` is the number of rows/cols consumed by
/// the divider between split children (typically 1).
pub fn resize_tree(
  node : LayoutNode,
  total_rows : Int,
  total_cols : Int,
  divider_size : Int,
) -> Unit {
  // Ensure minimum dimensions to prevent panics in cursor clamping
  let rows = Int::max(total_rows, 1)
  let cols = Int::max(total_cols, 1)
  match node {
    Leaf(info) => {
      info.rows = rows
      info.cols = cols
    }
    Split(dir, first, second, ratio) =>
      match dir {
        Horizontal => {
          let available = Int::max(rows - divider_size, 2)
          let first_rows = Int::max((Float::from_int(available) * ratio).to_int(), 1)
          let second_rows = Int::max(available - first_rows, 1)
          resize_tree(first, first_rows, cols, divider_size)
          resize_tree(second, second_rows, cols, divider_size)
        }
        Vertical => {
          let available = Int::max(cols - divider_size, 2)
          let first_cols = Int::max((Float::from_int(available) * ratio).to_int(), 1)
          let second_cols = Int::max(available - first_cols, 1)
          resize_tree(first, rows, first_cols, divider_size)
          resize_tree(second, rows, second_cols, divider_size)
        }
      }
  }
}

///|
/// Check whether a split at the given dimensions is feasible.
/// Returns true if both resulting panels would meet minimum size requirements.
pub fn can_split(
  rows : Int,
  cols : Int,
  direction : SplitDirection,
  ratio : Float,
  divider_size : Int,
) -> Bool {
  match direction {
    Horizontal => {
      let available = rows - divider_size
      let first_rows = (Float::from_int(available) * ratio).to_int()
      let second_rows = available - first_rows
      first_rows >= min_panel_rows && second_rows >= min_panel_rows
    }
    Vertical => {
      let available = cols - divider_size
      let first_cols = (Float::from_int(available) * ratio).to_int()
      let second_cols = available - first_cols
      first_cols >= min_panel_cols && second_cols >= min_panel_cols
    }
  }
}

///|
/// Find a sibling panel for focus fallback after closing a panel.
///
/// Strategy: find the panel's sibling in the tree. If the sibling is
/// a subtree, return its first leaf (DFS order).
pub fn find_sibling_panel(node : LayoutNode, panel_id : Int) -> PanelInfo? {
  match node {
    Leaf(_) => None
    Split(_, first, second, _) =>
      // If the target is a direct child, return the first leaf of the sibling
      if is_or_contains(first, panel_id) {
        match first {
          Leaf(info) if info.panel_id == panel_id => first_leaf(second)
          _ =>
            // Recurse deeper — target is in first's subtree
            match find_sibling_panel(first, panel_id) {
              Some(_) as found => found
              None => first_leaf(second)
            }
        }
      } else if is_or_contains(second, panel_id) {
        match second {
          Leaf(info) if info.panel_id == panel_id => first_leaf(first)
          _ =>
            match find_sibling_panel(second, panel_id) {
              Some(_) as found => found
              None => first_leaf(first)
            }
        }
      } else {
        None
      }
  }
}

///|
/// Check if a subtree contains a panel with the given ID.
fn is_or_contains(node : LayoutNode, panel_id : Int) -> Bool {
  match node {
    Leaf(info) => info.panel_id == panel_id
    Split(_, first, second, _) =>
      is_or_contains(first, panel_id) || is_or_contains(second, panel_id)
  }
}

///|
/// Return the first leaf in DFS order.
fn first_leaf(node : LayoutNode) -> PanelInfo? {
  match node {
    Leaf(info) => Some(info)
    Split(_, first, _, _) => first_leaf(first)
  }
}

///|
/// Find a neighbor panel in the given direction from the focused panel.
///
/// For directional navigation (Cmd+Alt+Arrow):
///   - Up: find the nearest panel above
///   - Down: find the nearest panel below
///   - Left: find the nearest panel to the left
///   - Right: find the nearest panel to the right
///
/// The algorithm walks up the tree to find the nearest relevant split,
/// then descends into the sibling to find the closest panel.
pub fn find_neighbor(
  node : LayoutNode,
  panel_id : Int,
  direction : FocusDirection,
) -> PanelInfo? {
  // Determine which split direction and which child position we need
  let (split_dir, want_second) = match direction {
    Up => (Horizontal, false) // Need a Horizontal split where we're in second
    Down => (Horizontal, true) // Need a Horizontal split where we're in first
    Left => (Vertical, false) // Need a Vertical split where we're in second
    Right => (Vertical, true) // Need a Vertical split where we're in first
  }
  find_neighbor_recursive(node, panel_id, split_dir, want_second)
}

///|
fn find_neighbor_recursive(
  node : LayoutNode,
  panel_id : Int,
  split_dir : SplitDirection,
  want_second : Bool,
) -> PanelInfo? {
  match node {
    Leaf(_) => None
    Split(dir, first, second, _) => {
      let in_first = is_or_contains(first, panel_id)
      let in_second = is_or_contains(second, panel_id)
      if !in_first && !in_second {
        return None
      }
      // If this split matches the direction we're looking for
      if dir == split_dir {
        if want_second && in_first {
          // We want to go to second (e.g., Down/Right), and target is in first
          // → navigate into second's nearest leaf
          return if want_second {
            first_leaf(second)
          } else {
            last_leaf(second)
          }
        }
        if !want_second && in_second {
          // We want to go to first (e.g., Up/Left), and target is in second
          // → navigate into first's last leaf
          return last_leaf(first)
        }
      }
      // Recurse into the subtree containing the target
      if in_first {
        find_neighbor_recursive(first, panel_id, split_dir, want_second)
      } else {
        find_neighbor_recursive(second, panel_id, split_dir, want_second)
      }
    }
  }
}

///|
/// Return the last leaf in DFS order (rightmost/bottommost).
fn last_leaf(node : LayoutNode) -> PanelInfo? {
  match node {
    Leaf(info) => Some(info)
    Split(_, _, second, _) => last_leaf(second)
  }
}
