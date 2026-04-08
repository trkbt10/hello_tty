///|
/// Keybinding table — maps key combinations to actions.
///
/// This is the single source of truth for all Cmd+key (super+key) bindings.
/// The default bindings follow iTerm2/Ghostty conventions.
///
/// To add or override a binding at runtime (e.g., from config):
///   keymap.bindings[combo] = action
///
/// To remove a binding:
///   keymap.bindings.remove(combo)
pub(all) struct Keymap {
  bindings : Map[KeyCombo, KeyClassification]
}

///|
/// The global keymap instance (initialized with defaults).
/// This is mutable so config can override bindings at startup.
let global_keymap : Keymap = Keymap::defaults()

///|
/// Look up a key action in the keymap.
/// Returns None if no binding exists for this combo.
pub fn Keymap::lookup(
  self : Keymap,
  key_code : Int,
  modifiers : Int,
) -> KeyClassification? {
  self.bindings.get({ key_code, modifiers })
}

///|
/// Override or add a binding.
pub fn Keymap::bind(
  self : Keymap,
  key_code : Int,
  modifiers : Int,
  action : KeyClassification,
) -> Unit {
  self.bindings[{ key_code, modifiers }] = action
}

///|
/// Remove a binding.
pub fn Keymap::unbind(self : Keymap, key_code : Int, modifiers : Int) -> Unit {
  self.bindings.remove({ key_code, modifiers })
}

///|
/// Get a reference to the global keymap for config overrides.
pub fn get_keymap() -> Keymap {
  global_keymap
}

///|
/// Create the default keybinding table.
///
/// Conventions (matching iTerm2/Ghostty):
///   - Cmd+D / Cmd+Shift+D: split right / down
///   - Cmd+W: close panel (cascades to tab → window)
///   - Cmd+1-8: go to tab by index, Cmd+9: go to last tab
///   - Cmd+Shift+]/[: next/prev tab
///   - Cmd+T: new tab
///   - Cmd+C/V: copy/paste
///   - Cmd+]: next split, Cmd+[: prev split
///   - Cmd+Alt+Arrow: directional split focus
///   - Cmd+\: split right (VSCode compat, kept as alias)
///   - Cmd+Shift+\: split down (VSCode compat, kept as alias)
fn Keymap::defaults() -> Keymap {
  let m : Map[KeyCombo, KeyClassification] = {}
  // ---- Clipboard ----
  // Cmd+C (0x63 = 'c')
  m[{ key_code: 0x63, modifiers: mod_super }] = ClipboardCopy
  // Cmd+V (0x76 = 'v')
  m[{ key_code: 0x76, modifiers: mod_super }] = ClipboardPaste
  // ---- Split management ----
  // Cmd+D (0x64 = 'd') → split right (iTerm2/Ghostty standard)
  m[{ key_code: 0x64, modifiers: mod_super }] = SplitRight
  // Cmd+Shift+D → split down (iTerm2/Ghostty standard)
  m[{ key_code: 0x64, modifiers: mod_super.lor(mod_shift) }] = SplitDown
  // Cmd+\ (0x5C) → split right (VSCode compat alias)
  m[{ key_code: 0x5C, modifiers: mod_super }] = SplitRight
  // Cmd+Shift+\ → split down (VSCode compat alias)
  m[{ key_code: 0x5C, modifiers: mod_super.lor(mod_shift) }] = SplitDown
  // Cmd+] (0x5D) → next split pane
  m[{ key_code: 0x5D, modifiers: mod_super }] = NextSplit
  // Cmd+[ (0x5B) → prev split pane
  m[{ key_code: 0x5B, modifiers: mod_super }] = PrevSplit
  // Cmd+Alt+Arrow → directional split focus
  let cmd_alt = mod_super.lor(mod_alt)
  m[{ key_code: 0xF700, modifiers: cmd_alt }] = FocusDirection(0) // Up
  m[{ key_code: 0xF701, modifiers: cmd_alt }] = FocusDirection(1) // Down
  m[{ key_code: 0xF702, modifiers: cmd_alt }] = FocusDirection(2) // Left
  m[{ key_code: 0xF703, modifiers: cmd_alt }] = FocusDirection(3) // Right
  // ---- Tab management ----
  // Cmd+T (0x74 = 't')
  m[{ key_code: 0x74, modifiers: mod_super }] = NewTab
  // Cmd+W (0x77 = 'w') → close panel (cascades to tab)
  m[{ key_code: 0x77, modifiers: mod_super }] = ClosePanel
  // Cmd+Shift+] → next tab
  m[{ key_code: 0x5D, modifiers: mod_super.lor(mod_shift) }] = NextTab
  // Cmd+Shift+[ → prev tab
  m[{ key_code: 0x5B, modifiers: mod_super.lor(mod_shift) }] = PrevTab
  // Cmd+1..8 → go to tab (0-indexed)
  for i in 0..<8 {
    m[{ key_code: 0x31 + i, modifiers: mod_super }] = GotoTab(i)
  }
  // Cmd+9 → go to last tab (index = -1 means "last")
  m[{ key_code: 0x39, modifiers: mod_super }] = GotoTab(-1)
  Keymap::{ bindings: m }
}
