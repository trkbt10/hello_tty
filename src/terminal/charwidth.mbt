///|
/// Unicode character width for terminal grid — POSIX wcwidth() equivalent.
///
/// Returns the number of terminal cells a character occupies:
///   0: non-spacing (combining marks, zero-width chars, default ignorables)
///   1: normal width (ASCII, Latin, most scripts)
///   2: wide (CJK Unified Ideographs, fullwidth forms, some symbols)
///
/// This MUST match the system's wcwidth() behavior so that the terminal grid
/// stays in sync with the PTY-side programs (bash, vim, ncurses) that use
/// the same width tables.
pub fn char_width(c : Char) -> Int {
  let cp = c.to_int()
  // C0/C1 control characters — non-printable
  if cp < 0x20 || (cp >= 0x7F && cp < 0xA0) {
    return 0
  }
  // Soft hyphen
  if cp == 0x00AD {
    return 1
  }
  // Zero-width characters
  if is_zero_width(cp) {
    return 0
  }
  // Wide characters (2 cells)
  if is_wide(cp) {
    return 2
  }
  // Everything else: 1 cell
  1
}

///|
/// Zero-width character ranges: combining marks, zero-width joiners,
/// variation selectors, default ignorables, etc.
fn is_zero_width(cp : Int) -> Bool {
  // Combining Diacritical Marks
  (cp >= 0x0300 && cp <= 0x036F) ||
  // Combining Diacritical Marks Extended
  (cp >= 0x1AB0 && cp <= 0x1AFF) ||
  // Combining Diacritical Marks Supplement
  (cp >= 0x1DC0 && cp <= 0x1DFF) ||
  // Combining Diacritical Marks for Symbols
  (cp >= 0x20D0 && cp <= 0x20FF) ||
  // Combining Half Marks
  (cp >= 0xFE20 && cp <= 0xFE2F) ||
  // Arabic combining marks
  (cp >= 0x0610 && cp <= 0x061A) ||
  (cp >= 0x064B && cp <= 0x065F) ||
  cp == 0x0670 ||
  (cp >= 0x06D6 && cp <= 0x06DC) ||
  (cp >= 0x06DF && cp <= 0x06E4) ||
  (cp >= 0x06E7 && cp <= 0x06E8) ||
  (cp >= 0x06EA && cp <= 0x06ED) ||
  // Devanagari etc. combining marks
  (cp >= 0x0900 && cp <= 0x0903) ||
  (cp >= 0x093A && cp <= 0x094F) ||
  (cp >= 0x0951 && cp <= 0x0957) ||
  (cp >= 0x0962 && cp <= 0x0963) ||
  // Bengali
  (cp >= 0x0981 && cp <= 0x0983) ||
  (cp >= 0x09BC && cp <= 0x09CD) ||
  (cp >= 0x09D7 && cp <= 0x09D7) ||
  (cp >= 0x09E2 && cp <= 0x09E3) ||
  // Thai
  (cp >= 0x0E31 && cp <= 0x0E31) ||
  (cp >= 0x0E34 && cp <= 0x0E3A) ||
  (cp >= 0x0E47 && cp <= 0x0E4E) ||
  // Hangul Jamo combining
  (cp >= 0x1160 && cp <= 0x11FF) ||
  // Zero-width space / non-joiner / joiner
  cp == 0x200B || cp == 0x200C || cp == 0x200D ||
  // Left-to-right / right-to-left marks
  cp == 0x200E || cp == 0x200F ||
  // Direction formatting
  (cp >= 0x202A && cp <= 0x202E) ||
  (cp >= 0x2060 && cp <= 0x2064) ||
  (cp >= 0x2066 && cp <= 0x206F) ||
  // Word joiner
  cp == 0x2060 ||
  // Zero-width no-break space (BOM) — deprecated as ZWNBSP but still zero-width
  cp == 0xFEFF ||
  // Variation selectors
  (cp >= 0xFE00 && cp <= 0xFE0F) ||
  // Variation selectors supplement
  (cp >= 0xE0100 && cp <= 0xE01EF) ||
  // Tags
  (cp >= 0xE0001 && cp <= 0xE007F) ||
  // Mongolian free variation selectors
  (cp >= 0x180B && cp <= 0x180E) ||
  // Interlinear annotation anchors
  (cp >= 0xFFF9 && cp <= 0xFFFB)
}

///|
/// Wide character ranges (2 cells): CJK, fullwidth forms, etc.
/// Based on Unicode East Asian Width property W and F categories.
fn is_wide(cp : Int) -> Bool {
  // CJK Radicals Supplement + Kangxi Radicals
  (cp >= 0x2E80 && cp <= 0x2FDF) ||
  // CJK Symbols and Punctuation (excluding a few narrow ones)
  (cp >= 0x2FF0 && cp <= 0x303E) ||
  // Hiragana
  (cp >= 0x3041 && cp <= 0x3096) ||
  (cp >= 0x3099 && cp <= 0x309F) ||
  // Katakana
  (cp >= 0x30A0 && cp <= 0x30FF) ||
  // Bopomofo
  (cp >= 0x3105 && cp <= 0x312F) ||
  // Hangul Compatibility Jamo
  (cp >= 0x3131 && cp <= 0x318E) ||
  // Bopomofo Extended
  (cp >= 0x31A0 && cp <= 0x31BF) ||
  // CJK Strokes
  (cp >= 0x31C0 && cp <= 0x31EF) ||
  // Katakana Phonetic Extensions
  (cp >= 0x31F0 && cp <= 0x31FF) ||
  // Enclosed CJK Letters and Months
  (cp >= 0x3200 && cp <= 0x32FF) ||
  // CJK Compatibility
  (cp >= 0x3300 && cp <= 0x33FF) ||
  // CJK Unified Ideographs Extension A
  (cp >= 0x3400 && cp <= 0x4DBF) ||
  // CJK Unified Ideographs
  (cp >= 0x4E00 && cp <= 0x9FFF) ||
  // Yi Syllables + Yi Radicals
  (cp >= 0xA000 && cp <= 0xA4CF) ||
  // Hangul Syllables
  (cp >= 0xAC00 && cp <= 0xD7AF) ||
  // CJK Compatibility Ideographs
  (cp >= 0xF900 && cp <= 0xFAFF) ||
  // Vertical forms
  (cp >= 0xFE10 && cp <= 0xFE19) ||
  // CJK Compatibility Forms
  (cp >= 0xFE30 && cp <= 0xFE6F) ||
  // Fullwidth Forms (Fullwidth ASCII variants, Fullwidth punctuation)
  (cp >= 0xFF01 && cp <= 0xFF60) ||
  (cp >= 0xFFE0 && cp <= 0xFFE6) ||
  // CJK Unified Ideographs Extension B..H, Supplementary
  (cp >= 0x20000 && cp <= 0x2FA1F) ||
  // CJK Compatibility Ideographs Supplement
  (cp >= 0x2F800 && cp <= 0x2FA1F) ||
  // Tertiary Ideographic Plane
  (cp >= 0x30000 && cp <= 0x323AF) ||
  // Emoji presentation (common wide emoji ranges)
  // Note: Not all emoji are wide. Only those with default emoji presentation
  // or that programs conventionally treat as wide.
  (cp >= 0x1F300 && cp <= 0x1F9FF) ||
  (cp >= 0x1FA00 && cp <= 0x1FA6F) ||
  (cp >= 0x1FA70 && cp <= 0x1FAFF)
}
