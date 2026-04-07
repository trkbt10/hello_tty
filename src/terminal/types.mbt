///|
/// Terminal color representation.
/// Supports indexed (256-color), RGB true color, and the 8 default colors.
pub(all) enum Color {
  /// Default foreground or background color.
  Default
  /// Standard 8/16 ANSI color index (0-15).
  Indexed(Int)
  /// 256-color palette index (0-255).
  Palette(Int)
  /// 24-bit RGB true color.
  Rgb(Byte, Byte, Byte)
} derive(Show, Eq)

///|
/// Cell attributes (bold, italic, underline, etc.).
/// Stored as a bitfield for compact representation.
pub struct CellAttrs {
  mut flags : Int
} derive(Show, Eq)

///|
// Attribute flag constants
pub let attr_bold : Int = 1

///|
pub let attr_italic : Int = 2

///|
pub let attr_underline : Int = 4

///|
pub let attr_blink : Int = 8

///|
pub let attr_inverse : Int = 16

///|
pub let attr_hidden : Int = 32

///|
pub let attr_strikethrough : Int = 64

///|
pub let attr_dim : Int = 128

///|
pub let attr_double_underline : Int = 256

///|
pub let attr_curly_underline : Int = 512

///|
/// Create default cell attributes (no flags set).
pub fn CellAttrs::default() -> CellAttrs {
  { flags: 0 }
}

///|
pub fn CellAttrs::has(self : CellAttrs, flag : Int) -> Bool {
  self.flags.land(flag) != 0
}

///|
pub fn CellAttrs::set(self : CellAttrs, flag : Int) -> Unit {
  self.flags = self.flags.lor(flag)
}

///|
pub fn CellAttrs::unset(self : CellAttrs, flag : Int) -> Unit {
  self.flags = self.flags.land(flag.lnot())
}

///|
pub fn CellAttrs::clear(self : CellAttrs) -> Unit {
  self.flags = 0
}

///|
/// Cursor style for rendering.
pub(all) enum CursorStyle {
  Block
  Underline
  Bar
} derive(Show, Eq)

///|
/// Character set designation (G0-G3).
pub(all) enum CharSet {
  /// ASCII / US
  Ascii
  /// DEC Special Graphics (line drawing)
  DecSpecialGraphics
  /// UK
  Uk
} derive(Show, Eq)

///|
/// Terminal mode flags controlled by SM/RM and DECSET/DECRST sequences.
pub struct TermModes {
  /// DECCKM: Cursor key mode (application vs normal)
  mut cursor_keys_application : Bool
  /// DECANM: ANSI/VT52 mode
  ansi_mode : Bool
  /// DECCOLM: 132/80 column mode
  mut column_132 : Bool
  /// DECSCLM: Smooth scroll
  mut smooth_scroll : Bool
  /// DECSCNM: Screen reverse video
  mut reverse_video : Bool
  /// DECOM: Origin mode
  mut origin_mode : Bool
  /// DECAWM: Auto-wrap mode
  mut auto_wrap : Bool
  /// DECARM: Auto-repeat keys
  mut auto_repeat : Bool
  /// DECTCEM: Text cursor enable (show/hide cursor)
  mut cursor_visible : Bool
  /// Alternate screen buffer
  mut alternate_screen : Bool
  /// Bracketed paste mode
  mut bracketed_paste : Bool
  /// Mouse tracking modes
  mut mouse_tracking : Bool
  mut mouse_sgr_mode : Bool
  /// Focus tracking
  mut focus_tracking : Bool
  /// LNM: Line feed/new line mode
  mut linefeed_mode : Bool
  /// IRM: Insert/Replace mode
  mut insert_mode : Bool
} derive(Show)

///|
pub fn TermModes::default() -> TermModes {
  {
    cursor_keys_application: false,
    ansi_mode: true,
    column_132: false,
    smooth_scroll: false,
    reverse_video: false,
    origin_mode: false,
    auto_wrap: true,
    auto_repeat: true,
    cursor_visible: true,
    alternate_screen: false,
    bracketed_paste: false,
    mouse_tracking: false,
    mouse_sgr_mode: false,
    focus_tracking: false,
    linefeed_mode: false,
    insert_mode: false,
  }
}
