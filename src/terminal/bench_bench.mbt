///|
/// Benchmarks for terminal hot paths.
///
/// Run with: moon bench src/terminal --target native
///
/// These establish baselines for:
///   1. Grid serialization to JSON (ffi_get_grid equivalent)
///   2. print_char for ASCII, CJK, and mixed text
///   3. VT parser + terminal event processing
///   4. char_width lookup

// ========== Grid JSON Serialization ==========

///|
/// Serialize full grid using @json.
fn serialize_grid_json(grid : Grid) -> String {
  let cells_arr : Array[Json] = []
  for row in 0..<grid.rows {
    let line = grid.lines[row]
    for col in 0..<grid.cols {
      let cell = line.get(col)
      if cell.char == '\u0000' {
        continue
      }
      let m : Map[String, Json] = {
        "r": row.to_json(),
        "c": col.to_json(),
        "ch": cell.char.to_string().to_json(),
        "fg": [230, 230, 230].to_json(),
        "bg": [20, 20, 26].to_json(),
        "a": cell.attrs.flags.to_json(),
        "w": cell.width.to_json(),
      }
      cells_arr.push(m.to_json())
    }
  }
  let cursor_map : Map[String, Json] = {
    "row": Int::to_json(0),
    "col": Int::to_json(0),
    "visible": true.to_json(),
    "style": "block".to_json(),
  }
  let grid_map : Map[String, Json] = {
    "rows": grid.rows.to_json(),
    "cols": grid.cols.to_json(),
    "cursor": cursor_map.to_json(),
    "cells": cells_arr.to_json(),
  }
  grid_map.to_json().stringify()
}

///|
/// Differential: only serialize cells within the dirty bounding box using @json.
fn serialize_grid_json_diff(grid : Grid) -> String {
  let cursor_map : Map[String, Json] = {
    "row": Int::to_json(0),
    "col": Int::to_json(0),
    "visible": true.to_json(),
    "style": "block".to_json(),
  }
  match grid.get_dirty_rect() {
    None => {
      let grid_map : Map[String, Json] = {
        "rows": grid.rows.to_json(),
        "cols": grid.cols.to_json(),
        "cursor": cursor_map.to_json(),
        "dirty": "none".to_json(),
        "cells": ([] : Array[Json]).to_json(),
      }
      grid_map.to_json().stringify()
    }
    Some((dr_top, dr_left, dr_bottom, dr_right)) => {
      let dirty_json : Json = if grid.dirty_all {
        "all".to_json()
      } else {
        [dr_top, dr_left, dr_bottom, dr_right].to_json()
      }
      let cells_arr : Array[Json] = []
      for row in dr_top..<=dr_bottom {
        let line = grid.lines[row]
        for col in dr_left..<=dr_right {
          let cell = line.get(col)
          if cell.char == '\u0000' {
            continue
          }
          let m : Map[String, Json] = {
            "r": row.to_json(),
            "c": col.to_json(),
            "ch": cell.char.to_string().to_json(),
            "fg": [230, 230, 230].to_json(),
            "bg": [20, 20, 26].to_json(),
            "a": cell.attrs.flags.to_json(),
            "w": cell.width.to_json(),
          }
          cells_arr.push(m.to_json())
        }
      }
      let grid_map : Map[String, Json] = {
        "rows": grid.rows.to_json(),
        "cols": grid.cols.to_json(),
        "cursor": cursor_map.to_json(),
        "dirty": dirty_json,
        "cells": cells_arr.to_json(),
      }
      grid_map.to_json().stringify()
    }
  }
}

///|
/// Helper: fill grid with typical terminal content (mixed ASCII).
fn fill_grid_ascii(grid : Grid) -> Unit {
  let pen = Cell::empty()
  let chars : Array[Char] = []
  for c in "hello world 1234567890 abcdefghij" {
    chars.push(c)
  }
  let mut i = 0
  for row in 0..<grid.rows {
    for col in 0..<grid.cols {
      grid.set_cell(row, col, chars[i % chars.length()], pen)
      i += 1
    }
  }
}

///|
/// Compare full vs diff for 24×80: full grid dirty (worst case for diff).
test "bench/grid_json_24x80_full" (b : @bench.T) {
  let grid = Grid::new(24, 80)
  fill_grid_ascii(grid)
  b.bench(name="full", fn() {
    grid.mark_all_dirty()
    b.keep(serialize_grid_json(grid))
  })
  b.bench(name="diff_full_dirty", fn() {
    grid.mark_all_dirty()
    b.keep(serialize_grid_json_diff(grid))
  })
}

///|
/// Diff for single character typed (dirty rect = 1 cell).
test "bench/grid_json_24x80_single_cell" (b : @bench.T) {
  let grid = Grid::new(24, 80)
  fill_grid_ascii(grid)
  b.bench(name="full", fn() {
    grid.mark_all_dirty()
    b.keep(serialize_grid_json(grid))
  })
  b.bench(name="diff_1_cell", fn() {
    grid.mark_all_clean()
    grid.mark_dirty(5, 10)
    b.keep(serialize_grid_json_diff(grid))
  })
}

///|
/// Diff for a line of text typed (dirty rect = 1 row x ~20 cols).
test "bench/grid_json_24x80_one_line" (b : @bench.T) {
  let grid = Grid::new(24, 80)
  fill_grid_ascii(grid)
  b.bench(name="full", fn() {
    grid.mark_all_dirty()
    b.keep(serialize_grid_json(grid))
  })
  b.bench(name="diff_1_line", fn() {
    grid.mark_all_clean()
    grid.mark_dirty(5, 0)
    grid.mark_dirty(5, 79)
    b.keep(serialize_grid_json_diff(grid))
  })
}

///|
/// Diff for nothing dirty (cursor blink, no content change).
test "bench/grid_json_24x80_nothing_dirty" (b : @bench.T) {
  let grid = Grid::new(24, 80)
  fill_grid_ascii(grid)
  b.bench(name="full", fn() {
    grid.mark_all_dirty()
    b.keep(serialize_grid_json(grid))
  })
  b.bench(name="diff_nothing", fn() {
    grid.mark_all_clean()
    b.keep(serialize_grid_json_diff(grid))
  })
}

// ========== print_char ==========

///|
/// Baseline: print ASCII characters via terminal.
test "bench/print_char_ascii" (b : @bench.T) {
  let terminal = Terminal::new(rows=24, cols=80)
  let text = "The quick brown fox jumps over the lazy dog. 1234567890"
  let events : Array[@vt_parser.ParserEvent] = []
  for c in text {
    events.push(@vt_parser.PrintChar(c))
  }
  b.bench(fn() {
    terminal.reset()
    for i in 0..<events.length() {
      terminal.handle_event(events[i])
    }
    b.keep(terminal.get_cursor().col)
  })
}

///|
/// Baseline: print CJK (wide) characters via terminal.
test "bench/print_char_cjk" (b : @bench.T) {
  let terminal = Terminal::new(rows=24, cols=80)
  let text = "日本語のテスト文字列です漢字カタカナひらがな"
  let events : Array[@vt_parser.ParserEvent] = []
  for c in text {
    events.push(@vt_parser.Utf8Char(c))
  }
  b.bench(fn() {
    terminal.reset()
    for i in 0..<events.length() {
      terminal.handle_event(events[i])
    }
    b.keep(terminal.get_cursor().col)
  })
}

///|
/// Baseline: mixed ASCII + CJK.
test "bench/print_char_mixed" (b : @bench.T) {
  let terminal = Terminal::new(rows=24, cols=80)
  let text = "Hello こんにちは World 世界 Test テスト 12345 一二三四五"
  let events : Array[@vt_parser.ParserEvent] = []
  for c in text {
    let cp = c.to_int()
    if cp <= 0x7F {
      events.push(@vt_parser.PrintChar(c))
    } else {
      events.push(@vt_parser.Utf8Char(c))
    }
  }
  b.bench(fn() {
    terminal.reset()
    for i in 0..<events.length() {
      terminal.handle_event(events[i])
    }
    b.keep(terminal.get_cursor().col)
  })
}

// ========== VT Parser + Terminal Processing ==========

///|
/// Baseline: parse and process a typical ls -la output.
test "bench/vt_process_ls_output" (b : @bench.T) {
  let terminal = Terminal::new(rows=24, cols=80)
  let parser = @vt_parser.Parser::new()
  // Simulated ls output with color codes
  let output = "\u001b[1;34mdrwxr-xr-x\u001b[0m  5 user staff  160 Jan  1 12:00 \u001b[1;34msrc\u001b[0m\r\n\u001b[1;32m-rw-r--r--\u001b[0m  1 user staff 1234 Jan  1 12:00 main.mbt\r\n\u001b[1;32m-rw-r--r--\u001b[0m  1 user staff  567 Jan  1 12:00 types.mbt\r\n"
  b.bench(fn() {
    terminal.reset()
    parser.reset()
    let events = parser.feed_str(output)
    terminal.handle_events(events)
    b.keep(terminal.get_cursor().row)
  })
}

///|
/// Baseline: parse a large chunk of plain text output (e.g. cat a file).
test "bench/vt_process_plaintext_4k" (b : @bench.T) {
  let terminal = Terminal::new(rows=24, cols=80)
  let parser = @vt_parser.Parser::new()
  // Build 4KB of plain text with line wraps
  let buf = StringBuilder::new()
  for i in 0..<4096 {
    let c = (i % 94 + 0x21).unsafe_to_char()
    buf.write_char(c)
    if (i + 1) % 80 == 0 {
      buf.write_string("\r\n")
    }
  }
  let output = buf.to_string()
  b.bench(fn() {
    terminal.reset()
    parser.reset()
    let events = parser.feed_str(output)
    terminal.handle_events(events)
    b.keep(terminal.get_cursor().row)
  })
}

///|
/// Baseline: process text with heavy SGR (color) attributes.
test "bench/vt_process_heavy_sgr" (b : @bench.T) {
  let terminal = Terminal::new(rows=24, cols=80)
  let parser = @vt_parser.Parser::new()
  let buf = StringBuilder::new()
  for i in 0..<200 {
    let color = i % 8 + 30
    buf.write_string("\u001b[")
    buf.write_string(color.to_string())
    buf.write_string(";1mtext")
    buf.write_string("\u001b[0m ")
  }
  let output = buf.to_string()
  b.bench(fn() {
    terminal.reset()
    parser.reset()
    let events = parser.feed_str(output)
    terminal.handle_events(events)
    b.keep(terminal.get_cursor().col)
  })
}

// ========== char_width ==========

///|
/// Baseline: char_width for ASCII characters.
test "bench/char_width_ascii" (b : @bench.T) {
  b.bench(fn() {
    let mut sum = 0
    for i in 0x20..<0x7F {
      sum += char_width(i.unsafe_to_char())
    }
    b.keep(sum)
  })
}

///|
/// Baseline: char_width for CJK range.
test "bench/char_width_cjk" (b : @bench.T) {
  b.bench(fn() {
    let mut sum = 0
    // Sample CJK Unified Ideographs
    for i in 0x4E00..<0x4E80 {
      sum += char_width(i.unsafe_to_char())
    }
    b.keep(sum)
  })
}

///|
/// Baseline: char_width for mixed characters.
test "bench/char_width_mixed" (b : @bench.T) {
  let chars = "Hello こんにちは 🌍 café ﷽ テスト"
  b.bench(fn() {
    let mut sum = 0
    for c in chars {
      sum += char_width(c)
    }
    b.keep(sum)
  })
}
