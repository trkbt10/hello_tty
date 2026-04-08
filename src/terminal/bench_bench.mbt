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
/// Old approach: Map/Json/stringify chain. Kept for comparison.
fn serialize_grid_json_old(grid : Grid) -> String {
  let cells_arr : Array[Json] = []
  for row in 0..<grid.rows {
    let line = grid.lines[row]
    for col in 0..<grid.cols {
      let cell = line.get(col)
      if cell.char == '\u0000' {
        continue
      }
      let cell_map : Map[String, Json] = {
        "r": row.to_json(),
        "c": col.to_json(),
        "ch": cell.char.to_string().to_json(),
        "fg": [230, 230, 230].to_json(),
        "bg": [20, 20, 26].to_json(),
        "a": cell.attrs.flags.to_json(),
        "w": cell.width.to_json(),
      }
      cells_arr.push(cell_map.to_json())
    }
  }
  let grid_map : Map[String, Json] = {
    "rows": grid.rows.to_json(),
    "cols": grid.cols.to_json(),
    "cursor": {
      let m : Map[String, Json] = {
        "row": Int::to_json(0),
        "col": Int::to_json(0),
        "visible": true.to_json(),
        "style": "block".to_json(),
      }
      m.to_json()
    },
    "cells": cells_arr.to_json(),
  }
  grid_map.to_json().stringify()
}

///|
/// New approach: direct StringBuilder. Matches the optimized ffi_get_grid.
fn serialize_grid_json(grid : Grid) -> String {
  let sb = StringBuilder::new(size_hint=grid.rows * grid.cols * 20)
  sb.write_string("{\"rows\":")
  sb.write_string(grid.rows.to_string())
  sb.write_string(",\"cols\":")
  sb.write_string(grid.cols.to_string())
  sb.write_string(",\"cursor\":{\"row\":0,\"col\":0,\"visible\":true,\"style\":\"block\"}")
  sb.write_string(",\"cells\":[")
  let mut first = true
  for row in 0..<grid.rows {
    let line = grid.lines[row]
    for col in 0..<grid.cols {
      let cell = line.get(col)
      if cell.char == '\u0000' {
        continue
      }
      if first {
        first = false
      } else {
        sb.write_char(',')
      }
      sb.write_string("{\"r\":")
      sb.write_string(row.to_string())
      sb.write_string(",\"c\":")
      sb.write_string(col.to_string())
      sb.write_string(",\"ch\":\"")
      sb.write_char(cell.char)
      sb.write_string("\",\"fg\":[230,230,230],\"bg\":[20,20,26],\"a\":")
      sb.write_string(cell.attrs.flags.to_string())
      sb.write_string(",\"w\":")
      sb.write_string(cell.width.to_string())
      sb.write_char('}')
    }
  }
  sb.write_string("]}")
  sb.to_string()
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
/// Compare old (Map/Json) vs new (StringBuilder) for 24×80 ASCII grid.
test "bench/grid_json_24x80" (b : @bench.T) {
  let grid = Grid::new(24, 80)
  fill_grid_ascii(grid)
  b.bench(name="old_map_json", fn() { b.keep(serialize_grid_json_old(grid)) })
  b.bench(name="new_stringbuilder", fn() { b.keep(serialize_grid_json(grid)) })
}

///|
/// Compare for empty 24×80 grid.
test "bench/grid_json_empty_24x80" (b : @bench.T) {
  let grid = Grid::new(24, 80)
  b.bench(
    name="old_map_json", fn() { b.keep(serialize_grid_json_old(grid)) },
  )
  b.bench(name="new_stringbuilder", fn() { b.keep(serialize_grid_json(grid)) })
}

///|
/// Compare for larger 50×120 grid.
test "bench/grid_json_50x120" (b : @bench.T) {
  let grid = Grid::new(50, 120)
  fill_grid_ascii(grid)
  b.bench(name="old_map_json", fn() { b.keep(serialize_grid_json_old(grid)) })
  b.bench(name="new_stringbuilder", fn() { b.keep(serialize_grid_json(grid)) })
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
    let c = ((i % 94) + 0x21).unsafe_to_char()
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
    let color = (i % 8) + 30
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
