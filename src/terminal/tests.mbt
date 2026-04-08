// ========== char_width ==========

///|
test "char_width/ascii_printable_is_1" {
  // All printable ASCII should be width 1
  for i in 0x20..<0x7F {
    let w = char_width(i.unsafe_to_char())
    assert_eq(w, 1)
  }
}

///|
test "char_width/control_chars_are_0" {
  assert_eq(char_width('\u0000'), 0) // NUL
  assert_eq(char_width('\u0007'), 0) // BEL
  assert_eq(char_width('\u001B'), 0) // ESC
  assert_eq(char_width('\u000A'), 0) // LF
  assert_eq(char_width('\u000D'), 0) // CR
}

///|
test "char_width/cjk_ideographs_are_2" {
  assert_eq(char_width('日'), 2)
  assert_eq(char_width('本'), 2)
  assert_eq(char_width('語'), 2)
  assert_eq(char_width('漢'), 2)
  assert_eq(char_width('字'), 2)
}

///|
test "char_width/katakana_hiragana_are_2" {
  assert_eq(char_width('あ'), 2)
  assert_eq(char_width('い'), 2)
  assert_eq(char_width('ア'), 2)
  assert_eq(char_width('カ'), 2)
}

///|
test "char_width/hangul_is_2" {
  assert_eq(char_width('가'), 2)
  assert_eq(char_width('한'), 2)
}

///|
test "char_width/fullwidth_forms_are_2" {
  assert_eq(char_width('Ａ'), 2) // U+FF21 Fullwidth A
  assert_eq(char_width('１'), 2) // U+FF11 Fullwidth 1
}

///|
test "char_width/latin_is_1" {
  assert_eq(char_width('A'), 1)
  assert_eq(char_width('z'), 1)
  assert_eq(char_width('é'), 1)
  assert_eq(char_width('ñ'), 1)
}

///|
test "char_width/combining_marks_are_0" {
  assert_eq(char_width('\u0300'), 0) // Combining grave accent
  assert_eq(char_width('\u0301'), 0) // Combining acute accent
  assert_eq(char_width('\u0302'), 0) // Combining circumflex
}

///|
test "char_width/zero_width_chars_are_0" {
  assert_eq(char_width('\u200B'), 0) // Zero-width space
  assert_eq(char_width('\u200C'), 0) // Zero-width non-joiner
  assert_eq(char_width('\u200D'), 0) // Zero-width joiner
  assert_eq(char_width('\uFEFF'), 0) // BOM / ZWNBSP
}

///|
test "char_width/arabic_bismillah_is_1" {
  // U+FDFD — wcwidth returns 1 regardless of font advance
  assert_eq(char_width('﷽'), 1)
}

///|
test "char_width/emoji_wide" {
  assert_eq(char_width('🌍'), 2) // U+1F30D
  assert_eq(char_width('🎉'), 2) // U+1F389
}

// ========== print_char wide character handling ==========

///|
test "print_char/ascii_advances_cursor_by_1" {
  let term = Terminal::new(rows=24, cols=80)
  term.handle_event(@vt_parser.PrintChar('A'))
  assert_eq(term.get_cursor().col, 1)
  term.handle_event(@vt_parser.PrintChar('B'))
  assert_eq(term.get_cursor().col, 2)
}

///|
test "print_char/cjk_advances_cursor_by_2" {
  let term = Terminal::new(rows=24, cols=80)
  term.handle_event(@vt_parser.Utf8Char('日'))
  assert_eq(term.get_cursor().col, 2)
  term.handle_event(@vt_parser.Utf8Char('本'))
  assert_eq(term.get_cursor().col, 4)
}

///|
test "print_char/cjk_sets_width_2_and_continuation" {
  let term = Terminal::new(rows=24, cols=80)
  term.handle_event(@vt_parser.Utf8Char('漢'))
  let grid = term.get_grid()
  let head = grid.get_cell(0, 0)
  assert_eq(head.char, '漢')
  assert_eq(head.width, 2)
  let cont = grid.get_cell(0, 1)
  assert_eq(cont.char, '\u0000')
  assert_eq(cont.width, 0)
}

///|
test "print_char/ascii_after_cjk_cursor_position" {
  let term = Terminal::new(rows=24, cols=80)
  term.handle_event(@vt_parser.Utf8Char('あ'))
  term.handle_event(@vt_parser.PrintChar('x'))
  assert_eq(term.get_cursor().col, 3)
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'あ')
  assert_eq(grid.get_cell(0, 0).width, 2)
  assert_eq(grid.get_cell(0, 1).width, 0)
  assert_eq(grid.get_cell(0, 2).char, 'x')
  assert_eq(grid.get_cell(0, 2).width, 1)
}

///|
test "print_char/wide_char_at_last_col_wraps" {
  // 80-col terminal: cursor at col 79, wide char should wrap to next line
  let term = Terminal::new(rows=24, cols=80)
  // Move cursor to col 79
  for _i in 0..<79 {
    term.handle_event(@vt_parser.PrintChar('.'))
  }
  assert_eq(term.get_cursor().col, 79)
  // Print a wide char — can't fit in col 79 alone, should wrap
  term.handle_event(@vt_parser.Utf8Char('日'))
  assert_eq(term.get_cursor().row, 1)
  assert_eq(term.get_cursor().col, 2) // After the wide char on new line
  let grid = term.get_grid()
  // Col 79 should be a space (padding)
  assert_eq(grid.get_cell(0, 79).char, ' ')
  // Wide char on line 1
  assert_eq(grid.get_cell(1, 0).char, '日')
  assert_eq(grid.get_cell(1, 0).width, 2)
}

///|
test "print_char/overwrite_wide_char_head_clears_continuation" {
  let term = Terminal::new(rows=24, cols=80)
  term.handle_event(@vt_parser.Utf8Char('漢'))
  // Overwrite position 0 with ASCII — should clear the continuation at position 1
  // Move cursor back to col 0
  term.handle_event(@vt_parser.Control(b'\x0D')) // CR
  term.handle_event(@vt_parser.PrintChar('X'))
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'X')
  assert_eq(grid.get_cell(0, 0).width, 1)
  // Continuation cell should have been cleaned up
  assert_eq(grid.get_cell(0, 1).width, 1)
}

///|
test "print_char/overwrite_continuation_clears_head" {
  let term = Terminal::new(rows=24, cols=80)
  let parser = @vt_parser.Parser::new()
  term.handle_event(@vt_parser.Utf8Char('漢'))
  // Move cursor to col 1 via CSI: ESC[2G = CHA column 2 (1-based → col 1)
  let events = parser.feed_str("\u001b[2G")
  term.handle_events(events)
  term.handle_event(@vt_parser.PrintChar('Y'))
  let grid = term.get_grid()
  // Head at col 0 should have been cleared
  assert_eq(grid.get_cell(0, 0).char, ' ')
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_eq(grid.get_cell(0, 1).char, 'Y')
  assert_eq(grid.get_cell(0, 1).width, 1)
}

///|
test "print_char/zero_width_char_does_not_advance" {
  let term = Terminal::new(rows=24, cols=80)
  term.handle_event(@vt_parser.PrintChar('A'))
  let col_before = term.get_cursor().col
  // Combining acute accent (U+0301)
  term.handle_event(@vt_parser.Utf8Char('\u0301'))
  assert_eq(term.get_cursor().col, col_before)
}

///|
test "print_char/multiple_cjk_fill_line" {
  let term = Terminal::new(rows=2, cols=10)
  // 5 wide chars should fill 10 columns exactly
  for _i in 0..<5 {
    term.handle_event(@vt_parser.Utf8Char('字'))
  }
  // Should be at wrap_pending state (col 9 reached after 5th char)
  let cursor = term.get_cursor()
  // 5 wide chars × 2 cols = 10, cursor should be at col 9 with wrap pending
  // or already wrapped depending on implementation
  assert_true(cursor.col >= 8)
}

// ========== Grid dirty bounding box ==========

///|
test "dirty_rect/initially_all_dirty" {
  let grid = Grid::new(24, 80)
  assert_true(grid.dirty_all)
  match grid.get_dirty_rect() {
    Some((0, 0, 23, 79)) => () // Full grid
    other => fail("Expected full grid dirty rect, got \{other}")
  }
}

///|
test "dirty_rect/clean_then_single_cell" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  assert_eq(grid.get_dirty_rect(), None)
  grid.mark_dirty(5, 10)
  match grid.get_dirty_rect() {
    Some((5, 10, 5, 10)) => ()
    other => fail("Expected (5,10,5,10), got \{other}")
  }
}

///|
test "dirty_rect/expands_correctly" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  grid.mark_dirty(3, 5)
  grid.mark_dirty(7, 20)
  match grid.get_dirty_rect() {
    Some((3, 5, 7, 20)) => ()
    other => fail("Expected (3,5,7,20), got \{other}")
  }
}

///|
test "dirty_rect/set_cell_marks_dirty" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  let pen = Cell::empty()
  grid.set_cell(10, 40, 'X', pen)
  match grid.get_dirty_rect() {
    Some((10, 40, 10, 40)) => ()
    other => fail("Expected (10,40,10,40), got \{other}")
  }
}

///|
test "dirty_rect/set_cell_with_width_marks_wide" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  let pen = Cell::empty()
  grid.set_cell_with_width(5, 10, '漢', pen, 2)
  match grid.get_dirty_rect() {
    Some((5, 10, 5, 11)) => ()
    other => fail("Expected (5,10,5,11), got \{other}")
  }
}

///|
test "dirty_rect/clear_cells_marks_range" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  grid.clear_cells(3, 10, 20)
  match grid.get_dirty_rect() {
    Some((3, 10, 3, 19)) => ()
    other => fail("Expected (3,10,3,19), got \{other}")
  }
}

///|
test "dirty_rect/scroll_marks_all_dirty" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  let _ = grid.scroll_up(1)
  assert_true(grid.dirty_all)
}

///|
test "dirty_rect/resize_marks_all_dirty" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  grid.resize(30, 100)
  assert_true(grid.dirty_all)
}

///|
test "dirty_rect/mark_all_clean_resets" {
  let grid = Grid::new(24, 80)
  let pen = Cell::empty()
  grid.set_cell(5, 5, 'A', pen)
  grid.mark_all_clean()
  assert_eq(grid.dirty_all, false)
  assert_eq(grid.dirty_top, -1)
  assert_eq(grid.get_dirty_rect(), None)
}

///|
test "dirty_rect/multiple_writes_expand_rect" {
  let grid = Grid::new(24, 80)
  grid.mark_all_clean()
  let pen = Cell::empty()
  grid.set_cell(2, 3, 'A', pen)
  grid.set_cell(2, 5, 'B', pen)
  grid.set_cell(8, 3, 'C', pen)
  match grid.get_dirty_rect() {
    Some((2, 3, 8, 5)) => ()
    other => fail("Expected (2,3,8,5), got \{other}")
  }
}

// ========== Renderer continuation cell handling ==========

///|
test "renderer/continuation_cell_cols_is_0" {
  // When a wide char is written, the renderer should see cell_cols=0 for continuation
  let term = Terminal::new(rows=2, cols=10)
  term.handle_event(@vt_parser.Utf8Char('日'))
  let grid = term.get_grid()
  // Head cell
  assert_eq(grid.get_cell(0, 0).width, 2)
  // Continuation cell — renderer should skip this (cell_cols=0)
  assert_eq(grid.get_cell(0, 1).width, 0)
}

// ========== Text editing operations with wide characters ==========
// These tests simulate what a shell (bash/zsh readline) actually sends to
// the terminal for common editing operations.

// ---------- Helper: feed a VT sequence string ----------

///|
fn feed(term : Terminal, s : String) -> Unit {
  let parser = @vt_parser.Parser::new()
  let events = parser.feed_str(s)
  term.handle_events(events)
}

// ---------- Backspace (BS) ----------

///|
test "bs/ascii_moves_cursor_left_by_1" {
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "ABC")
  assert_eq(term.get_cursor().col, 3)
  term.handle_event(@vt_parser.Control(b'\x08'))
  assert_eq(term.get_cursor().col, 2)
}

///|
test "bs/at_col_0_does_nothing" {
  let term = Terminal::new(rows=2, cols=20)
  assert_eq(term.get_cursor().col, 0)
  term.handle_event(@vt_parser.Control(b'\x08'))
  assert_eq(term.get_cursor().col, 0)
}

///|
test "bs/two_bs_moves_back_over_wide_char" {
  // Shell sends 2× BS for a wide character to move cursor back to head position
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "日")
  assert_eq(term.get_cursor().col, 2)
  term.handle_event(@vt_parser.Control(b'\x08'))
  assert_eq(term.get_cursor().col, 1)
  term.handle_event(@vt_parser.Control(b'\x08'))
  assert_eq(term.get_cursor().col, 0)
}

// ---------- Shell-style backspace: BS×n + EL (erase to end of line) ----------

///|
test "shell_bs/delete_ascii_char" {
  // Type "ABC", then shell deletes 'C': BS + EL
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "ABC")
  assert_eq(term.get_cursor().col, 3)
  // BS to move back 1 column
  feed(term, "\u0008")
  // EL (erase from cursor to end of line)
  feed(term, "\u001b[K")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  assert_eq(grid.get_cell(0, 1).char, 'B')
  assert_true(grid.get_cell(0, 2).is_empty())
  assert_eq(term.get_cursor().col, 2)
}

///|
test "shell_bs/delete_wide_char_at_end" {
  // Type "A日", then shell deletes '日': BS×2 + EL
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "A日")
  assert_eq(term.get_cursor().col, 3)
  // BS × 2 to go back 2 columns
  feed(term, "\u0008\u0008")
  assert_eq(term.get_cursor().col, 1)
  // EL (erase from cursor to end of line)
  feed(term, "\u001b[K")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  // Cells 1 and 2 should be cleared — no leftover wide char fragments
  assert_true(grid.get_cell(0, 1).is_empty())
  assert_eq(grid.get_cell(0, 1).width, 1) // Not a continuation cell
  assert_true(grid.get_cell(0, 2).is_empty())
  assert_eq(grid.get_cell(0, 2).width, 1)
}

///|
test "shell_bs/delete_wide_char_then_redraw_tail" {
  // Type "日本語", cursor at col 6.
  // Shell deletes '語' (last char): BS×2 + EL
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "日本語")
  assert_eq(term.get_cursor().col, 6)
  feed(term, "\u0008\u0008")
  assert_eq(term.get_cursor().col, 4)
  feed(term, "\u001b[K")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, '日')
  assert_eq(grid.get_cell(0, 0).width, 2)
  assert_eq(grid.get_cell(0, 1).width, 0)
  assert_eq(grid.get_cell(0, 2).char, '本')
  assert_eq(grid.get_cell(0, 2).width, 2)
  assert_eq(grid.get_cell(0, 3).width, 0)
  assert_true(grid.get_cell(0, 4).is_empty())
  assert_true(grid.get_cell(0, 5).is_empty())
}

///|
test "shell_bs/delete_wide_char_middle_then_redraw" {
  // Type "日本語", shell deletes '本' (middle):
  // Move cursor to col 2 (head of '本'), EL, redraw '語'
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "日本語")
  // Move cursor to col 2: CSI 3G (CHA, 1-based)
  feed(term, "\u001b[3G")
  assert_eq(term.get_cursor().col, 2)
  // Erase from cursor to end
  feed(term, "\u001b[K")
  // Redraw remaining text '語'
  feed(term, "語")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, '日')
  assert_eq(grid.get_cell(0, 0).width, 2)
  assert_eq(grid.get_cell(0, 1).width, 0)
  assert_eq(grid.get_cell(0, 2).char, '語')
  assert_eq(grid.get_cell(0, 2).width, 2)
  assert_eq(grid.get_cell(0, 3).width, 0)
  assert_true(grid.get_cell(0, 4).is_empty())
}

// ---------- DCH (Delete Character, CSI P) ----------

///|
test "dch/delete_1_ascii" {
  // "ABCD", cursor at B (col 1), delete 1 char → "ACD_"
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "ABCD")
  feed(term, "\u001b[2G") // CHA col 2 → col 1
  feed(term, "\u001b[P") // DCH 1
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  assert_eq(grid.get_cell(0, 1).char, 'C')
  assert_eq(grid.get_cell(0, 2).char, 'D')
  assert_true(grid.get_cell(0, 3).is_empty())
}

///|
test "dch/delete_2_removes_wide_char" {
  // "A日B", cursor at col 1 (head of '日'), DCH 2 → "AB____"
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "A日B")
  feed(term, "\u001b[2G") // CHA col 2 → col 1
  feed(term, "\u001b[2P") // DCH 2
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  assert_eq(grid.get_cell(0, 1).char, 'B')
  assert_true(grid.get_cell(0, 2).is_empty())
}

///|
test "dch/delete_1_on_wide_head_clears_continuation" {
  // "日B", cursor at col 0 (head of '日'), DCH 1
  // Only 1 cell deleted from a 2-cell char → continuation cell must be cleaned
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[1G") // CHA col 1 → col 0
  feed(term, "\u001b[P") // DCH 1
  let grid = term.get_grid()
  // After removing col 0, old col 1 (continuation, width=0) shifts to col 0
  // It must not remain as an orphan continuation
  // No orphaned continuation cells in the row
  for col in 0..<10 {
    let cell = grid.get_cell(0, col)
    if cell.width == 0 {
      assert_true(col > 0 && grid.get_cell(0, col - 1).width == 2)
    }
  }
}

///|
test "dch/delete_1_on_continuation_clears_head" {
  // "日B", cursor at col 1 (continuation of '日'), DCH 1
  // Deleting the continuation should clean up the head
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[2G") // CHA col 2 → col 1
  feed(term, "\u001b[P") // DCH 1
  let grid = term.get_grid()
  // Head at col 0 lost its continuation — must be cleaned up
  for col in 0..<10 {
    let cell = grid.get_cell(0, col)
    if cell.width == 2 {
      assert_true(col + 1 < 10 && grid.get_cell(0, col + 1).width == 0)
    }
    if cell.width == 0 {
      assert_true(col > 0 && grid.get_cell(0, col - 1).width == 2)
    }
  }
}

// ---------- EL (Erase in Line, CSI K) ----------

///|
test "el/erase_to_end_from_continuation" {
  // "日本", cursor at col 1 (continuation of '日'), EL 0 (erase to end)
  // The head of '日' should be cleaned up since its continuation is erased
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日本")
  feed(term, "\u001b[2G") // CHA col 2 → col 1
  feed(term, "\u001b[K") // EL 0
  let grid = term.get_grid()
  // Head at col 0 should no longer be width=2 (its continuation was erased)
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_true(grid.get_cell(0, 1).is_empty())
  assert_eq(grid.get_cell(0, 1).width, 1)
}

///|
test "el/erase_to_beginning_from_wide_head" {
  // "AB日", cursor at col 2 (head of '日'), EL 1 (erase from start to cursor)
  // Should erase cols 0-2, but col 3 is continuation of '日' and must be cleaned
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "AB日")
  feed(term, "\u001b[3G") // CHA col 3 → col 2
  feed(term, "\u001b[1K") // EL 1 (erase from start of line to cursor inclusive)
  let grid = term.get_grid()
  assert_true(grid.get_cell(0, 0).is_empty())
  assert_true(grid.get_cell(0, 1).is_empty())
  assert_true(grid.get_cell(0, 2).is_empty())
  // Continuation at col 3 must be cleaned up — no orphan
  assert_eq(grid.get_cell(0, 3).width, 1)
}

///|
test "el/erase_to_end_preserves_preceding_wide_char" {
  // "日B", cursor at col 2 ('B'), EL 0 (erase to end)
  // '日' at cols 0-1 should be preserved
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[3G") // CHA col 3 → col 2
  feed(term, "\u001b[K") // EL 0
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, '日')
  assert_eq(grid.get_cell(0, 0).width, 2)
  assert_eq(grid.get_cell(0, 1).width, 0)
  assert_true(grid.get_cell(0, 2).is_empty())
}

// ---------- ICH (Insert Characters, CSI @) ----------

///|
test "ich/insert_at_wide_char_head" {
  // "日B", cursor at col 0 (head of '日'), ICH 1
  // Inserting at the head should push the wide char right
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[1G") // CHA col 1 → col 0
  feed(term, "\u001b[@") // ICH 1
  let grid = term.get_grid()
  // Col 0 should be blank, '日' shifted to cols 1-2
  assert_true(grid.get_cell(0, 0).is_empty())
  assert_eq(grid.get_cell(0, 1).char, '日')
  assert_eq(grid.get_cell(0, 1).width, 2)
  assert_eq(grid.get_cell(0, 2).width, 0)
  assert_eq(grid.get_cell(0, 3).char, 'B')
}

///|
test "ich/insert_at_continuation_splits_wide_char" {
  // "日B", cursor at col 1 (continuation of '日'), ICH 1
  // The wide char is split — head at col 0 loses its continuation
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[2G") // CHA col 2 → col 1
  feed(term, "\u001b[@") // ICH 1
  let grid = term.get_grid()
  // Head at col 0 should be cleaned up (no continuation anymore)
  assert_eq(grid.get_cell(0, 0).width, 1)
  // No orphan continuations
  for col in 0..<10 {
    let cell = grid.get_cell(0, col)
    if cell.width == 0 {
      assert_true(col > 0 && grid.get_cell(0, col - 1).width == 2)
    }
  }
}

///|
test "ich/push_wide_char_off_right_edge" {
  // 10-col terminal: "AAAA日BBBB" (cols 0-3: A, cols 4-5: 日, cols 6-9: B)
  // Cursor at col 0, ICH 2 → pushes everything right by 2
  // Verify no orphan wide char fragments at the right edge
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "AAAA日BBBB")
  feed(term, "\u001b[1G") // CHA col 1 → col 0
  feed(term, "\u001b[2@") // ICH 2
  let grid = term.get_grid()
  for col in 0..<10 {
    let cell = grid.get_cell(0, col)
    if cell.width == 2 {
      assert_true(col + 1 < 10 && grid.get_cell(0, col + 1).width == 0)
    }
    if cell.width == 0 {
      assert_true(col > 0 && grid.get_cell(0, col - 1).width == 2)
    }
  }
}

// ---------- Overwrite scenarios ----------

///|
test "overwrite/ascii_on_wide_head" {
  // "日", cursor at col 0, write 'X' → "X " (head overwritten, continuation cleared)
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "X")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'X')
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_eq(grid.get_cell(0, 1).width, 1)
}

///|
test "overwrite/ascii_on_continuation" {
  // "日", cursor at col 1 (continuation), write 'X' → " X"
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日")
  feed(term, "\u001b[2G") // cursor to col 1
  feed(term, "X")
  let grid = term.get_grid()
  // Head at col 0 should be cleaned up
  assert_eq(grid.get_cell(0, 0).char, ' ')
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_eq(grid.get_cell(0, 1).char, 'X')
  assert_eq(grid.get_cell(0, 1).width, 1)
}

///|
test "overwrite/wide_char_on_two_narrow_chars" {
  // "AB", cursor at col 0, write '日' → "日" occupying cols 0-1
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "AB")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "日")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, '日')
  assert_eq(grid.get_cell(0, 0).width, 2)
  assert_eq(grid.get_cell(0, 1).width, 0)
}

///|
test "overwrite/wide_on_wide_aligned" {
  // "日", cursor at col 0, write '本' → "本"
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "本")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, '本')
  assert_eq(grid.get_cell(0, 0).width, 2)
  assert_eq(grid.get_cell(0, 1).width, 0)
}

///|
test "overwrite/wide_on_wide_misaligned" {
  // "A日B", cursor at col 1 (continuation of 日), write '本'
  // '本' occupies cols 1-2, so 日's head at col 0 needs clearing
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "A日B")
  feed(term, "\u001b[2G") // cursor to col 1
  feed(term, "本")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  assert_eq(grid.get_cell(0, 1).char, '本')
  assert_eq(grid.get_cell(0, 1).width, 2)
  assert_eq(grid.get_cell(0, 2).width, 0)
}

// ---------- ECH (Erase Characters, CSI X) ----------

///|
test "ech/erase_1_on_wide_head" {
  // "日B", cursor at col 0, ECH 1 → only col 0 erased, but continuation orphaned
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "\u001b[X") // ECH 1
  let grid = term.get_grid()
  // Col 0 should be erased, and continuation at col 1 should not be orphaned
  assert_true(grid.get_cell(0, 0).is_empty())
  assert_eq(grid.get_cell(0, 0).width, 1)
  // Continuation should be cleaned up
  assert_eq(grid.get_cell(0, 1).width, 1)
}

///|
test "ech/erase_1_on_continuation" {
  // "日B", cursor at col 1 (continuation), ECH 1
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日B")
  feed(term, "\u001b[2G") // cursor to col 1
  feed(term, "\u001b[X") // ECH 1
  let grid = term.get_grid()
  // Head at col 0 lost its continuation — should be cleaned up
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_true(grid.get_cell(0, 1).is_empty())
  assert_eq(grid.get_cell(0, 1).width, 1)
}

// ---------- CUB/CUF (Cursor movement) over wide chars ----------

///|
test "cursor/cub_over_wide_char" {
  // "日", cursor at col 2, CUB 1 → col 1 (inside continuation)
  // This is correct VT behavior — cursor CAN land on a continuation cell
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "日")
  assert_eq(term.get_cursor().col, 2)
  feed(term, "\u001b[D") // CUB 1
  assert_eq(term.get_cursor().col, 1)
}

///|
test "cursor/cuf_from_wide_char_head" {
  // Cursor at col 0 (on '日' head), CUF 1 → col 1
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "日")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "\u001b[C") // CUF 1
  assert_eq(term.get_cursor().col, 1)
}

// ---------- Mixed ASCII and wide characters ----------

///|
test "mixed/alternating_ascii_and_wide" {
  // "A日B本C" → A at 0, 日 at 1-2, B at 3, 本 at 4-5, C at 6
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "A日B本C")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_eq(grid.get_cell(0, 1).char, '日')
  assert_eq(grid.get_cell(0, 1).width, 2)
  assert_eq(grid.get_cell(0, 2).width, 0)
  assert_eq(grid.get_cell(0, 3).char, 'B')
  assert_eq(grid.get_cell(0, 3).width, 1)
  assert_eq(grid.get_cell(0, 4).char, '本')
  assert_eq(grid.get_cell(0, 4).width, 2)
  assert_eq(grid.get_cell(0, 5).width, 0)
  assert_eq(grid.get_cell(0, 6).char, 'C')
  assert_eq(term.get_cursor().col, 7)
}

///|
test "mixed/shell_delete_wide_between_ascii" {
  // "A日B" → delete '日': move to col 1, EL, redraw "B"
  let term = Terminal::new(rows=2, cols=20)
  feed(term, "A日B")
  // Move cursor to col 1 (head of 日)
  feed(term, "\u001b[2G")
  // Erase to end
  feed(term, "\u001b[K")
  // Redraw remaining
  feed(term, "B")
  let grid = term.get_grid()
  assert_eq(grid.get_cell(0, 0).char, 'A')
  assert_eq(grid.get_cell(0, 1).char, 'B')
  assert_eq(grid.get_cell(0, 1).width, 1)
  assert_true(grid.get_cell(0, 2).is_empty())
  assert_eq(grid.get_cell(0, 2).width, 1)
  assert_true(grid.get_cell(0, 3).is_empty())
  assert_eq(grid.get_cell(0, 3).width, 1)
}

// ---------- ED (Erase in Display) with wide chars ----------

///|
test "ed/erase_from_cursor_splits_wide_char" {
  // Row 0: "日本", cursor at row 0 col 1 (continuation of 日)
  // ED 0 (erase from cursor to end of screen) should clean up the head
  let term = Terminal::new(rows=3, cols=10)
  feed(term, "日本")
  feed(term, "\u001b[1;2H") // CUP row 1, col 2 → row 0, col 1
  feed(term, "\u001b[J") // ED 0
  let grid = term.get_grid()
  // Head at col 0 should be cleaned up
  assert_eq(grid.get_cell(0, 0).width, 1)
  assert_true(grid.get_cell(0, 1).is_empty())
}

///|
test "ed/erase_to_cursor_splits_wide_char" {
  // Row 0: "AB日", cursor at row 0 col 2 (head of 日)
  // ED 1 (erase from start to cursor) should clean up the continuation at col 3
  let term = Terminal::new(rows=3, cols=10)
  feed(term, "AB日")
  feed(term, "\u001b[1;3H") // CUP row 1, col 3 → row 0, col 2
  feed(term, "\u001b[1J") // ED 1
  let grid = term.get_grid()
  assert_true(grid.get_cell(0, 0).is_empty())
  assert_true(grid.get_cell(0, 1).is_empty())
  assert_true(grid.get_cell(0, 2).is_empty())
  // Continuation at col 3 should be cleaned up
  assert_eq(grid.get_cell(0, 3).width, 1)
}

// ---------- Grid invariant: no orphan wide char fragments ----------

///|
/// Helper to verify the wide character invariant across an entire grid row:
/// - Every width=2 cell must be followed by a width=0 cell
/// - Every width=0 cell must be preceded by a width=2 cell
fn assert_row_invariant(grid : Grid, row : Int) -> Unit raise {
  let cols = grid.cols
  for col in 0..<cols {
    let cell = grid.get_cell(row, col)
    if cell.width == 2 {
      if col + 1 >= cols {
        fail("width=2 at col \{col} has no continuation (at right edge)")
      }
      let next = grid.get_cell(row, col + 1)
      if next.width != 0 {
        fail(
          "width=2 at col \{col} followed by width=\{next.width} instead of 0",
        )
      }
    }
    if cell.width == 0 {
      if col == 0 {
        fail("orphan continuation at col 0")
      }
      let prev = grid.get_cell(row, col - 1)
      if prev.width != 2 {
        fail(
          "continuation at col \{col} preceded by width=\{prev.width} instead of 2",
        )
      }
    }
  }
}

///|
test "invariant/after_multiple_operations" {
  let term = Terminal::new(rows=3, cols=10)
  // Write some wide chars
  feed(term, "日本語AB")
  assert_row_invariant(term.get_grid(), 0)
  // Delete in middle
  feed(term, "\u001b[3G") // cursor to col 2
  feed(term, "\u001b[2P") // DCH 2
  assert_row_invariant(term.get_grid(), 0)
  // Insert in middle
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "\u001b[@") // ICH 1
  assert_row_invariant(term.get_grid(), 0)
  // Erase
  feed(term, "\u001b[5G") // cursor to col 4
  feed(term, "\u001b[K") // EL 0
  assert_row_invariant(term.get_grid(), 0)
}

///|
test "invariant/dch_on_adjacent_wide_chars" {
  // "日本語" → DCH 1 at col 1 (continuation of 日)
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日本語")
  feed(term, "\u001b[2G") // cursor to col 1
  feed(term, "\u001b[P") // DCH 1
  assert_row_invariant(term.get_grid(), 0)
}

///|
test "invariant/dch_3_on_wide_chars" {
  // "日本語" → DCH 3 at col 0
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日本語")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "\u001b[3P") // DCH 3
  assert_row_invariant(term.get_grid(), 0)
}

///|
test "invariant/insert_splitting_wide_char_at_edge" {
  // 10-col terminal: "AAAA日BBBB" (A×4 at 0-3, 日 at 4-5, B×4 at 6-9)
  // ICH 1 at col 0 → everything shifts right
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "AAAA日BBBB")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "\u001b[@") // ICH 1
  assert_row_invariant(term.get_grid(), 0)
}

///|
test "invariant/ech_partial_wide" {
  // "日本" → ECH 3 at col 0 → erases cols 0-2 (head+cont of 日, head of 本)
  // Continuation of 本 at col 3 becomes orphaned
  let term = Terminal::new(rows=2, cols=10)
  feed(term, "日本")
  feed(term, "\u001b[1G") // cursor to col 0
  feed(term, "\u001b[3X") // ECH 3
  assert_row_invariant(term.get_grid(), 0)
}

// ========== Viewport / Scrollback ==========

///|
test "viewport/offset_starts_at_zero" {
  let term = Terminal::new(rows=4, cols=10)
  assert_eq(term.get_viewport_offset(), 0)
}

///|
test "viewport/live_returns_grid_rows" {
  let term = Terminal::new(rows=4, cols=5)
  // Use \r\n to ensure each line starts at column 0
  feed(term, "AAA\r\nBBB\r\nCCC")
  assert_eq(term.get_viewport_row(0).unwrap().get(0).char, 'A')
  assert_eq(term.get_viewport_row(1).unwrap().get(0).char, 'B')
  assert_eq(term.get_viewport_row(2).unwrap().get(0).char, 'C')
}

///|
test "viewport/scroll_up_into_scrollback" {
  // Use \r\n so each line starts at col 0 (LF alone doesn't do CR)
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  // After 8 lines with 4-row grid: 4 lines in scrollback, 4 in grid
  let sb = term.get_scrollback()
  assert_eq(sb.length(), 4)
  assert_eq(sb.get(0).unwrap().get(0).char, 'A')
  assert_eq(sb.get(1).unwrap().get(0).char, 'B')
  assert_eq(sb.get(2).unwrap().get(0).char, 'C')
  assert_eq(sb.get(3).unwrap().get(0).char, 'D')
  assert_eq(term.get_grid().get_cell(0, 0).char, 'E')
  assert_eq(term.get_grid().get_cell(1, 0).char, 'F')
  assert_eq(term.get_grid().get_cell(2, 0).char, 'G')
  assert_eq(term.get_grid().get_cell(3, 0).char, 'H')

  // Scroll viewport up by 2 lines
  term.scroll_viewport_up(2)
  assert_eq(term.get_viewport_offset(), 2)

  // screen_row 0: abs_index = 4 - 2 + 0 = 2 → scrollback[2] = C
  assert_eq(term.get_viewport_row(0).unwrap().get(0).char, 'C')
  // screen_row 1: abs_index = 3 → scrollback[3] = D
  assert_eq(term.get_viewport_row(1).unwrap().get(0).char, 'D')
  // screen_row 2: abs_index = 4 → grid[0] = E
  assert_eq(term.get_viewport_row(2).unwrap().get(0).char, 'E')
  // screen_row 3: abs_index = 5 → grid[1] = F
  assert_eq(term.get_viewport_row(3).unwrap().get(0).char, 'F')
}

///|
test "viewport/scroll_fully_into_scrollback" {
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  term.scroll_viewport_up(4)
  assert_eq(term.get_viewport_offset(), 4)
  assert_eq(term.get_viewport_row(0).unwrap().get(0).char, 'A')
  assert_eq(term.get_viewport_row(1).unwrap().get(0).char, 'B')
  assert_eq(term.get_viewport_row(2).unwrap().get(0).char, 'C')
  assert_eq(term.get_viewport_row(3).unwrap().get(0).char, 'D')
}

///|
test "viewport/clamps_to_scrollback_length" {
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  term.scroll_viewport_up(100)
  assert_eq(term.get_viewport_offset(), 4)
}

///|
test "viewport/scroll_down_toward_live" {
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  term.scroll_viewport_up(4)
  assert_eq(term.get_viewport_offset(), 4)
  term.scroll_viewport_down(2)
  assert_eq(term.get_viewport_offset(), 2)
  term.scroll_viewport_down(10)
  assert_eq(term.get_viewport_offset(), 0)
}

///|
test "viewport/new_output_resets_to_live" {
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  term.scroll_viewport_up(3)
  assert_eq(term.get_viewport_offset(), 3)
  // New output arrives → viewport snaps to live
  feed(term, "X")
  assert_eq(term.get_viewport_offset(), 0)
}

///|
test "viewport/alternate_screen_ignores_scroll" {
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  // Switch to alternate screen (DECSET 1049)
  feed(term, "\u001b[?1049h")
  term.scroll_viewport_up(5)
  assert_eq(term.get_viewport_offset(), 0)
}

///|
test "viewport/reset_clears_viewport_offset" {
  let term = Terminal::new(rows=4, cols=5)
  feed(term, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH")
  term.scroll_viewport_up(3)
  assert_eq(term.get_viewport_offset(), 3)
  term.reset()
  assert_eq(term.get_viewport_offset(), 0)
}
