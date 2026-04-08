///|
/// Tests for translate_key_input — control code mapping correctness.
///
/// These tests guard against regressions where Ctrl+C, Ctrl+D, etc.
/// fail to produce the correct bytes for the PTY.
///
/// The two code paths tested:
///   Path A: Platform gives letter key_code (0x40-0x7E) + ctrl modifier
///   Path B: Platform gives raw control code (0x00-0x1F) + ctrl modifier
///           (macOS charactersIgnoringModifiers behavior)

// ---- Path A: Ctrl + letter key_code ----

test "Ctrl+C via letter (0x63) produces 0x03" {
  let result = @input.translate_key_input(0x63, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[3]")
}

///|
test "Ctrl+D via letter (0x64) produces 0x04" {
  let result = @input.translate_key_input(0x64, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[4]")
}

///|
test "Ctrl+Z via letter (0x7A) produces 0x1A" {
  let result = @input.translate_key_input(0x7A, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[26]")
}

///|
test "Ctrl+\\ via letter (0x5C) produces 0x1C" {
  let result = @input.translate_key_input(0x5C, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[28]")
}

///|
test "Ctrl+A via letter (0x61) produces 0x01" {
  let result = @input.translate_key_input(0x61, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[1]")
}

// ---- Path B: Ctrl + raw control code ----
// macOS charactersIgnoringModifiers with Ctrl held returns the control
// code directly (e.g., 0x03 for Ctrl+C, not 'c' = 0x63).

///|
test "Ctrl+C via raw code (0x03) produces 0x03" {
  let result = @input.translate_key_input(0x03, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[3]")
}

///|
test "Ctrl+D via raw code (0x04) produces 0x04" {
  let result = @input.translate_key_input(0x04, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[4]")
}

///|
test "Ctrl+Z via raw code (0x1A) produces 0x1A" {
  let result = @input.translate_key_input(0x1A, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[26]")
}

///|
test "Ctrl+S via raw code (0x13) produces 0x13" {
  let result = @input.translate_key_input(0x13, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[19]")
}

///|
test "Ctrl+Q via raw code (0x11) produces 0x11" {
  let result = @input.translate_key_input(0x11, @input.mod_ctrl, false)
  inspect(result.to_array().map(fn(c) { c.to_int() }), content="[17]")
}

// ---- classify_key tests ----

///|
test "Ctrl+C is classified as DirectToPty" {
  // Path A: letter
  let r1 = @input.classify_key(0x63, @input.mod_ctrl, false)
  inspect(r1, content="DirectToPty")
  // Path B: raw control code
  let r2 = @input.classify_key(0x03, @input.mod_ctrl, false)
  inspect(r2, content="DirectToPty")
}

///|
test "Cmd+D is classified as SplitRight" {
  let r = @input.classify_key(0x64, @input.mod_super, false)
  inspect(r, content="SplitRight")
}

///|
test "Cmd+W is classified as ClosePanel" {
  let r = @input.classify_key(0x77, @input.mod_super, false)
  inspect(r, content="ClosePanel")
}

///|
test "Cmd+1 is classified as GotoTab(0)" {
  let r = @input.classify_key(0x31, @input.mod_super, false)
  inspect(r, content="GotoTab(0)")
}

///|
test "Cmd+9 is classified as GotoTab(-1) (last tab)" {
  let r = @input.classify_key(0x39, @input.mod_super, false)
  inspect(r, content="GotoTab(-1)")
}

///|
test "Cmd+Shift+D is classified as SplitDown" {
  let r = @input.classify_key(
    0x64,
    @input.mod_super.lor(@input.mod_shift),
    false,
  )
  inspect(r, content="SplitDown")
}
