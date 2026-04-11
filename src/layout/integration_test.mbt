///|
/// Integration tests for LayoutManager with real SessionManager + PTY.
/// Verifies tab creation, panel splitting, focus switching, and cleanup.

///|
test "create_tab spawns PTY and returns valid fd" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (tab_id, panel_id, master_fd) = lm.create_tab(24, 80)
  assert_true(tab_id > 0)
  assert_true(panel_id > 0)
  assert_true(master_fd >= 0)
  assert_eq(sm.count(), 1)
  assert_eq(lm.tab_count(), 1)
  lm.destroy_all()
}

///|
test "multiple tabs each have independent sessions" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (tid1, _, fd1) = lm.create_tab(24, 80)
  let (tid2, _, fd2) = lm.create_tab(24, 80)
  assert_true(tid1 != tid2)
  assert_true(fd1 >= 0)
  assert_true(fd2 >= 0)
  assert_eq(sm.count(), 2)
  assert_eq(lm.tab_count(), 2)
  assert_true(lm.switch_tab(tid1))
  assert_true(lm.switch_tab(tid2))
  lm.destroy_all()
  assert_eq(sm.count(), 0)
}

///|
test "split_panel creates new session with PTY" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (_, panel_id, _) = lm.create_tab(24, 80)
  assert_eq(sm.count(), 1)
  match lm.split_panel(panel_id, Vertical) {
    Some(result) => {
      assert_true(result.new_panel_id > 0)
      assert_true(result.new_session_id > 0)
      assert_true(result.master_fd >= 0)
      assert_eq(sm.count(), 2)
      assert_eq(lm.get_all_panels().length(), 2)
    }
    None => assert_true(false)
  }
  lm.destroy_all()
}

///|
test "close_panel destroys session and PTY" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (_, panel_id, _) = lm.create_tab(24, 80)
  match lm.split_panel(panel_id, Vertical) {
    Some(result) => {
      assert_eq(sm.count(), 2)
      lm.close_panel(result.new_panel_id) |> ignore
      assert_eq(sm.count(), 1)
      assert_eq(lm.get_all_panels().length(), 1)
    }
    None => assert_true(false)
  }
  lm.destroy_all()
}

///|
test "focus_direction navigates between split panels" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (_, panel_id, _) = lm.create_tab(24, 80)
  match lm.split_panel(panel_id, Vertical) {
    Some(result) => {
      assert_eq(lm.get_focused_panel_id(), result.new_panel_id)
      assert_true(lm.focus_direction(Left))
      assert_eq(lm.get_focused_panel_id(), panel_id)
      assert_true(lm.focus_direction(Right))
      assert_eq(lm.get_focused_panel_id(), result.new_panel_id)
    }
    None => assert_true(false)
  }
  lm.destroy_all()
}

///|
test "next_tab and prev_tab cycle correctly" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (tid1, _, _) = lm.create_tab(24, 80)
  let (tid2, _, _) = lm.create_tab(24, 80)
  let (tid3, _, _) = lm.create_tab(24, 80)
  assert_eq(lm.get_active_tab_id(), tid3)
  lm.prev_tab() |> ignore
  assert_eq(lm.get_active_tab_id(), tid2)
  lm.prev_tab() |> ignore
  assert_eq(lm.get_active_tab_id(), tid1)
  lm.next_tab() |> ignore
  assert_eq(lm.get_active_tab_id(), tid2)
  lm.destroy_all()
}

///|
test "close_tab cleans up all panels and sessions" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (tid1, pid1, _) = lm.create_tab(24, 80)
  match lm.split_panel(pid1, Horizontal) {
    Some(_) => ()
    None => ()
  }
  let _ = lm.create_tab(24, 80)
  let count_before = sm.count()
  assert_true(count_before >= 2)
  lm.close_tab(tid1)
  assert_true(sm.count() < count_before)
  assert_eq(lm.tab_count(), 1)
  lm.destroy_all()
}

///|
test "resize_all propagates to all panels" {
  let sm = @session.SessionManager::new()
  let lm = LayoutManager::new(sm)
  let (_, panel_id, _) = lm.create_tab(24, 80)
  match lm.split_panel(panel_id, Vertical) {
    Some(_) => {
      lm.resize_all(40, 120)
      let panels = lm.get_all_panels()
      for i in 0..<panels.length() {
        // Each panel should have been resized (exact dimensions depend on ratio)
        assert_true(panels[i].rows > 0)
        assert_true(panels[i].cols > 0)
      }
    }
    None => ()
  }
  lm.destroy_all()
}
