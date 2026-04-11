///|
/// Linux adapter — layout tree to pixel bounds conversion.

///|
pub struct PanelRect {
  panel_id : Int
  session_id : Int
  x : Int
  y : Int
  w : Int
  h : Int
}

///|
pub fn compute_panel_rects(
  layout : @layout.LayoutManager,
  win_w : Int,
  win_h : Int,
) -> Array[PanelRect] {
  let rects : Array[PanelRect] = []
  match layout.get_active_layout() {
    Some(node) => layout_node_to_rects(node, 0, 0, win_w, win_h, rects)
    None => ()
  }
  rects
}

///|
fn layout_node_to_rects(
  node : @layout.LayoutNode,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  out : Array[PanelRect],
) -> Unit {
  match node {
    Leaf(info) =>
      out.push({ panel_id: info.panel_id, session_id: info.session_id, x, y, w, h })
    Split(dir, first, second, ratio) =>
      match dir {
        Vertical => {
          let fw = (Float::from_int(w) * ratio).to_int()
          layout_node_to_rects(first, x, y, fw, h, out)
          layout_node_to_rects(second, x + fw, y, w - fw, h, out)
        }
        Horizontal => {
          let fh = (Float::from_int(h) * ratio).to_int()
          layout_node_to_rects(first, x, y, w, fh, out)
          layout_node_to_rects(second, x, y + fh, w, h - fh, out)
        }
      }
  }
}

///|
/// Find which panel contains the given pixel coordinate.
pub fn hit_test_panel(
  layout : @layout.LayoutManager,
  x : Int,
  y : Int,
  win_w : Int,
  win_h : Int,
) -> PanelRect? {
  let rects = compute_panel_rects(layout, win_w, win_h)
  for i in 0..<rects.length() {
    let r = rects[i]
    if x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h {
      return Some(r)
    }
  }
  None
}
