///|
/// Linux adapter — key event handling, IME, clipboard.

///|
/// Handle a key event. Returns false if the application should quit.
pub fn handle_key(
  key_code : Int,
  modifiers : Int,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  platform : @platform.Platform,
  renderer : @renderer.Renderer,
  term_cfg : @config.TerminalConfig,
) -> Bool {
  // Linux clipboard: Ctrl+Shift+C/V
  let ctrl = modifiers.land(@input.mod_ctrl) != 0
  let shift = modifiers.land(@input.mod_shift) != 0
  if ctrl && shift {
    match key_code {
      0x63 | 0x43 => {
        let text = extract_selection_text(sessions, layout)
        if text.length() > 0 {
          try { platform.clipboard_set(text) } catch { _ => () }
        }
        return true
      }
      0x76 | 0x56 => {
        let text = try { platform.clipboard_get() } catch { _ => "" }
        if text.length() > 0 {
          write_to_focused_pty(sessions, layout, text)
        }
        return true
      }
      _ => ()
    }
  }
  let classification = @input.classify_key(key_code, modifiers, false)
  match classification {
    DirectToPty => {
      if shift && key_code == 0xF72C {
        scroll_focused(sessions, layout, true)
        return true
      }
      if shift && key_code == 0xF72D {
        scroll_focused(sessions, layout, false)
        return true
      }
      reset_viewport_if_scrolled(sessions, layout)
      let modes = get_focused_modes(sessions, layout)
      let seq = @input.translate_key_input(
        key_code, modifiers, modes.cursor_keys_application,
      )
      if seq.length() > 0 {
        write_to_focused_pty(sessions, layout, seq)
      }
    }
    ForwardToIme => {
      reset_viewport_if_scrolled(sessions, layout)
      if key_code >= 0x80 && key_code <= 0xFF && modifiers == 0 {
        write_raw_byte_to_pty(sessions, layout, key_code)
      } else {
        let modes = get_focused_modes(sessions, layout)
        let seq = @input.translate_key_input(
          key_code, modifiers, modes.cursor_keys_application,
        )
        if seq.length() > 0 {
          write_to_focused_pty(sessions, layout, seq)
        }
      }
    }
    ClipboardCopy => {
      let text = extract_selection_text(sessions, layout)
      if text.length() > 0 {
        try { platform.clipboard_set(text) } catch { _ => () }
      }
    }
    ClipboardPaste => {
      let text = try { platform.clipboard_get() } catch { _ => "" }
      if text.length() > 0 {
        write_to_focused_pty(sessions, layout, text)
      }
    }
    ClipboardCut | SelectAll | FindInTerminal => ()
    NewTab => {
      let _ = layout.create_tab(term_cfg.rows, term_cfg.cols)
      set_all_nonblocking(sessions, layout)
    }
    SplitRight => {
      let pid = layout.get_focused_panel_id()
      if pid >= 0 {
        match layout.split_panel(pid, Vertical) {
          Some(_) => set_all_nonblocking(sessions, layout)
          None => ()
        }
      }
    }
    SplitDown => {
      let pid = layout.get_focused_panel_id()
      if pid >= 0 {
        match layout.split_panel(pid, Horizontal) {
          Some(_) => set_all_nonblocking(sessions, layout)
          None => ()
        }
      }
    }
    ClosePanel => {
      let pid = layout.get_focused_panel_id()
      if pid >= 0 { layout.close_panel(pid) |> ignore }
      if sessions.count() == 0 { return false }
    }
    NextTab => { layout.next_tab() |> ignore }
    PrevTab => { layout.prev_tab() |> ignore }
    GotoTab(index) => {
      let tabs = layout.list_tabs()
      if index == -1 {
        if tabs.length() > 0 {
          let (tid, _, _) = tabs[tabs.length() - 1]
          layout.switch_tab(tid) |> ignore
        }
      } else if index >= 0 && index < tabs.length() {
        let (tid, _, _) = tabs[index]
        layout.switch_tab(tid) |> ignore
      }
    }
    NextSplit => {
      let panels = layout.get_all_panels()
      let cur = layout.get_focused_panel_id()
      let mut found = false
      for i in 0..<panels.length() {
        if panels[i].panel_id == cur {
          let next = (i + 1) % panels.length()
          layout.focus_panel(panels[next].panel_id) |> ignore
          found = true
          break
        }
      }
      if !found && panels.length() > 0 {
        layout.focus_panel(panels[0].panel_id) |> ignore
      }
    }
    PrevSplit => {
      let panels = layout.get_all_panels()
      let cur = layout.get_focused_panel_id()
      for i in 0..<panels.length() {
        if panels[i].panel_id == cur {
          let prev = if i == 0 { panels.length() - 1 } else { i - 1 }
          layout.focus_panel(panels[prev].panel_id) |> ignore
          break
        }
      }
    }
    FocusDirection(dir) => {
      let fd : @layout.FocusDirection = match dir {
        0 => Up
        1 => Down
        2 => Left
        _ => Right
      }
      layout.focus_direction(fd) |> ignore
    }
  }
  true
}

///|
/// Handle mouse events: scroll, click-to-focus, drag selection.
pub fn handle_mouse(
  x : Int,
  y : Int,
  button : Int,
  kind : Int,
  sessions : @session.SessionManager,
  layout : @layout.LayoutManager,
  renderer : @renderer.Renderer,
  win_w : Int,
  win_h : Int,
) -> Unit {
  if button == -2 {
    if kind > 0 {
      scroll_focused(sessions, layout, true)
    } else if kind < 0 {
      scroll_focused(sessions, layout, false)
    }
    return
  }
  match hit_test_panel(layout, x, y, win_w, win_h) {
    None => ()
    Some(hit_rect) => {
      let cfg = renderer.get_config()
      let cw = if cfg.cell_width > 0 { cfg.cell_width } else { 8 }
      let ch = if cfg.cell_height > 0 { cfg.cell_height } else { 16 }
      if button == 0 {
        layout.focus_panel(hit_rect.panel_id) |> ignore
        let col = (x - hit_rect.x) / cw
        let row = (y - hit_rect.y) / ch
        g_selection.active = true
        g_selection.panel_id = hit_rect.panel_id
        g_selection.anchor_row = row
        g_selection.anchor_col = col
        g_selection.end_row = row
        g_selection.end_col = col
      } else if button == -1 {
        if g_selection.active && g_selection.panel_id == hit_rect.panel_id {
          g_selection.end_row = (y - hit_rect.y) / ch
          g_selection.end_col = (x - hit_rect.x) / cw
        }
      } else if button == 0x100 {
        if g_selection.active {
          g_selection.end_row = (y - hit_rect.y) / ch
          g_selection.end_col = (x - hit_rect.x) / cw
        }
      }
      ignore(sessions)
    }
  }
}
