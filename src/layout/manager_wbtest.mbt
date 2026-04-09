///|
fn test_manager_with_two_workspaces() -> LayoutManager {
  let manager = LayoutManager::new(@session.SessionManager::new())
  manager.tabs[1] = Tab::{
    id: 1,
    layout: Leaf(PanelInfo::{
      panel_id: 11,
      session_id: 101,
      rows: 24,
      cols: 80,
    }),
    focused_panel_id: 11,
    title: "one",
  }
  manager.tabs[2] = Tab::{
    id: 2,
    layout: Leaf(PanelInfo::{
      panel_id: 12,
      session_id: 102,
      rows: 24,
      cols: 80,
    }),
    focused_panel_id: 12,
    title: "two",
  }
  manager.tabs[3] = Tab::{
    id: 3,
    layout: Leaf(PanelInfo::{
      panel_id: 13,
      session_id: 103,
      rows: 24,
      cols: 80,
    }),
    focused_panel_id: 13,
    title: "three",
  }
  manager.workspaces[1] = [1, 2]
  manager.workspaces[2] = [3]
  manager.workspace_active_tabs[1] = 1
  manager.workspace_active_tabs[2] = 3
  manager.tab_workspace[1] = 1
  manager.tab_workspace[2] = 1
  manager.tab_workspace[3] = 2
  manager.workspace_order = [1, 2]
  manager.active_workspace_id = 1
  manager.active_tab_id = 1
  manager.next_workspace_id = 3
  manager.next_tab_id = 4
  manager.next_panel_id = 14
  manager
}

///|
test "remove_tab_id keeps relative order of remaining tabs" {
  let result = remove_tab_id([1, 2, 3, 4], 3)
  assert_eq(result.length(), 3)
  assert_eq(result[0], 1)
  assert_eq(result[1], 2)
  assert_eq(result[2], 4)
}

///|
test "insert_tab_id inserts at the requested index" {
  let result = insert_tab_id([1, 3, 4], 2, 1)
  assert_eq(result.length(), 4)
  assert_eq(result[0], 1)
  assert_eq(result[1], 2)
  assert_eq(result[2], 3)
  assert_eq(result[3], 4)
}

///|
test "insert_tab_id appends when target index is past the end" {
  let result = insert_tab_id([1, 2], 3, 99)
  assert_eq(result.length(), 3)
  assert_eq(result[0], 1)
  assert_eq(result[1], 2)
  assert_eq(result[2], 3)
}

///|
test "next_active_tab_id_after_close prefers the tab now occupying the removed slot" {
  let result = next_active_tab_id_after_close([10, 30], Some(1))
  assert_eq(result, 30)
}

///|
test "next_active_tab_id_after_close falls back to the last tab when the tail closes" {
  let result = next_active_tab_id_after_close([10, 20], Some(2))
  assert_eq(result, 20)
}

///|
test "detach_tab_to_new_workspace preserves source order and activates detached workspace" {
  let manager = test_manager_with_two_workspaces()
  let new_workspace_id = manager.detach_tab_to_new_workspace(2)

  assert_eq(new_workspace_id, 3)
  assert_eq(manager.workspace_order, [1, 2, 3])
  assert_eq(manager.workspace_tab_order(1), [1])
  assert_eq(manager.workspace_tab_order(3), [2])
  assert_eq(manager.workspace_active_tab_id(1), 1)
  assert_eq(manager.workspace_active_tab_id(3), 2)
  assert_eq(manager.tab_workspace.get(2), Some(3))
  assert_eq(manager.get_active_workspace_id(), 3)
  assert_eq(manager.active_tab_id, 2)
}

///|
test "detach_tab_to_new_workspace refuses to orphan the source workspace" {
  let manager = test_manager_with_two_workspaces()
  let new_workspace_id = manager.detach_tab_to_new_workspace(3)

  assert_eq(new_workspace_id, -1)
  assert_eq(manager.workspace_order, [1, 2])
  assert_eq(manager.workspace_tab_order(2), [3])
  assert_eq(manager.tab_workspace.get(3), Some(2))
}

///|
test "attach_tab_to_workspace inserts into target order and removes empty source workspace" {
  let manager = test_manager_with_two_workspaces()
  let detached_workspace_id = manager.detach_tab_to_new_workspace(2)
  let attached = manager.attach_tab_to_workspace(2, 2, 0)

  assert_true(attached)
  assert_eq(detached_workspace_id, 3)
  assert_eq(manager.workspace_order, [1, 2])
  assert_eq(manager.workspace_tab_order(1), [1])
  assert_eq(manager.workspace_tab_order(2), [2, 3])
  assert_eq(manager.workspace_active_tab_id(2), 2)
  assert_eq(manager.tab_workspace.get(2), Some(2))
  assert_eq(manager.get_active_workspace_id(), 2)
  assert_eq(manager.active_tab_id, 2)
}

///|
test "close_tab activates another workspace when the last tab in the active workspace closes" {
  let manager = test_manager_with_two_workspaces()
  manager.activate_workspace(2) |> ignore
  manager.close_tab(3)

  assert_eq(manager.workspace_order, [1])
  assert_eq(manager.get_active_workspace_id(), 1)
  assert_eq(manager.active_tab_id, 1)
  assert_eq(manager.workspace_tab_order(1), [1, 2])
  assert_eq(manager.tab_workspace.get(3), None)
}

///|
test "merge_tab_into_panel removes the dragged tab and expands the target tab layout" {
  let manager = test_manager_with_two_workspaces()
  let merged = manager.merge_tab_into_panel(3, 11, Vertical)

  assert_true(merged)
  assert_eq(manager.workspace_order, [1])
  assert_eq(manager.workspace_tab_order(1), [1, 2])
  assert_eq(manager.tab_workspace.get(3), None)
  assert_eq(manager.get_active_workspace_id(), 1)
  assert_eq(manager.active_tab_id, 1)
  match manager.tabs.get(1) {
    Some(tab) => {
      assert_eq(count_leaves(tab.layout), 2)
      assert_eq(tab.focused_panel_id, 13)
    }
    None => assert_true(false)
  }
}
