///|
/// TOML configuration file parser.
///
/// Loads config from ~/.config/hello_tty/config.toml.
/// Missing keys fall back to Config::default().

///|
/// Parse a TOML string into a Config, falling back to defaults for missing keys.
pub fn Config::from_toml(toml_str : String) -> Config {
  let defaults = Config::default()
  let parsed = try {
    @toml.parse(toml_str)
  } catch {
    _ => return defaults
  }
  guard parsed is @toml.TomlTable(root) else { return defaults }
  let terminal = match root.get("terminal") {
    Some(@toml.TomlTable(t)) => parse_terminal_config(t, defaults.terminal)
    _ => defaults.terminal
  }
  let renderer = match root.get("renderer") {
    Some(@toml.TomlTable(t)) => parse_renderer_config(t, defaults.renderer)
    _ => defaults.renderer
  }
  let theme_name = match root.get("theme") {
    Some(@toml.TomlTable(t)) =>
      match t.get("name") {
        Some(@toml.TomlString(s)) => s
        _ => defaults.theme_name
      }
    _ => defaults.theme_name
  }
  let theme_overrides = match root.get("theme") {
    Some(@toml.TomlTable(t)) => parse_theme_overrides(t)
    _ => defaults.theme_overrides
  }
  let ui = match root.get("ui") {
    Some(@toml.TomlTable(t)) => parse_ui_config(t, defaults.ui)
    _ => defaults.ui
  }
  { terminal, renderer, theme_name, theme_overrides, ui }
}

///|
fn parse_terminal_config(
  t : Map[String, @toml.TomlValue],
  defaults : TerminalConfig
) -> TerminalConfig {
  {
    rows: get_int(t, "rows").unwrap_or(defaults.rows),
    cols: get_int(t, "cols").unwrap_or(defaults.cols),
    shell: get_string(t, "shell").unwrap_or(defaults.shell),
    max_scrollback: get_int(t, "max_scrollback").unwrap_or(defaults.max_scrollback),
  }
}

///|
fn parse_renderer_config(
  t : Map[String, @toml.TomlValue],
  defaults : RendererConfigValues
) -> RendererConfigValues {
  {
    font_size: get_int(t, "font_size").unwrap_or(defaults.font_size),
    dpi_scale: get_float(t, "dpi_scale").unwrap_or(defaults.dpi_scale),
    atlas_size: get_int(t, "atlas_size").unwrap_or(defaults.atlas_size),
  }
}

///|
fn parse_theme_overrides(t : Map[String, @toml.TomlValue]) -> ThemeOverrides {
  {
    fg: get_rgba(t, "fg"),
    bg: get_rgba(t, "bg"),
    cursor: get_rgba(t, "cursor"),
    selection: get_rgba(t, "selection"),
    bg_alpha: get_float_opt(t, "bg_alpha"),
  }
}

///|
fn parse_ui_config(
  t : Map[String, @toml.TomlValue],
  defaults : UIConfig
) -> UIConfig {
  {
    tab_bar_height: get_float(t, "tab_bar_height").unwrap_or(defaults.tab_bar_height),
    tab_corner_ratio: get_float(t, "tab_corner_ratio").unwrap_or(
      defaults.tab_corner_ratio,
    ),
    tab_padding_horizontal: get_float(t, "tab_padding_horizontal").unwrap_or(
      defaults.tab_padding_horizontal,
    ),
    tab_padding_vertical: get_float(t, "tab_padding_vertical").unwrap_or(
      defaults.tab_padding_vertical,
    ),
    titlebar_leading_inset: get_float(t, "titlebar_leading_inset").unwrap_or(
      defaults.titlebar_leading_inset,
    ),
    titlebar_trailing_inset: get_float(t, "titlebar_trailing_inset").unwrap_or(
      defaults.titlebar_trailing_inset,
    ),
    tab_close_button_inset: get_float(t, "tab_close_button_inset").unwrap_or(
      defaults.tab_close_button_inset,
    ),
    tab_close_button_size: get_float(t, "tab_close_button_size").unwrap_or(
      defaults.tab_close_button_size,
    ),
    separator_thickness: get_float(t, "separator_thickness").unwrap_or(
      defaults.separator_thickness,
    ),
    tab_spacing: get_float(t, "tab_spacing").unwrap_or(defaults.tab_spacing),
    tab_min_width: get_float(t, "tab_min_width").unwrap_or(defaults.tab_min_width),
    tab_max_width: get_float(t, "tab_max_width").unwrap_or(defaults.tab_max_width),
    panel_divider_thickness: get_float(t, "panel_divider_thickness").unwrap_or(
      defaults.panel_divider_thickness,
    ),
    panel_divider_hit_area: get_float(t, "panel_divider_hit_area").unwrap_or(
      defaults.panel_divider_hit_area,
    ),
    overlay_corner_radius: get_float(t, "overlay_corner_radius").unwrap_or(
      defaults.overlay_corner_radius,
    ),
    overlay_border_width: get_float(t, "overlay_border_width").unwrap_or(
      defaults.overlay_border_width,
    ),
    overlay_bg_opacity: get_float(t, "overlay_bg_opacity").unwrap_or(
      defaults.overlay_bg_opacity,
    ),
  }
}

// ========== TOML value extraction helpers ==========

///|
fn get_int(t : Map[String, @toml.TomlValue], key : String) -> Int? {
  match t.get(key) {
    Some(@toml.TomlInteger(n)) => Some(n.to_int())
    _ => None
  }
}

///|
fn get_float(t : Map[String, @toml.TomlValue], key : String) -> Float? {
  match t.get(key) {
    Some(@toml.TomlFloat(f)) => Some(Float::from_double(f))
    Some(@toml.TomlInteger(n)) => Some(Float::from_int(n.to_int()))
    _ => None
  }
}

///|
fn get_float_opt(t : Map[String, @toml.TomlValue], key : String) -> Float? {
  get_float(t, key)
}

///|
fn get_string(t : Map[String, @toml.TomlValue], key : String) -> String? {
  match t.get(key) {
    Some(@toml.TomlString(s)) => Some(s)
    _ => None
  }
}

///|
/// Parse an RGBA color from a TOML string like "#RRGGBB" or "#RRGGBBAA".
fn get_rgba(
  t : Map[String, @toml.TomlValue],
  key : String
) -> @theme.RgbaColor? {
  match t.get(key) {
    Some(@toml.TomlString(s)) => parse_hex_color(s)
    _ => None
  }
}

///|
/// Parse a hex color string "#RRGGBB" or "#RRGGBBAA" into RgbaColor.
fn parse_hex_color(s : String) -> @theme.RgbaColor? {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  if chars.length() < 7 || chars[0] != '#' {
    return None
  }
  guard hex_byte(chars, 1) is Some(r) else { return None }
  guard hex_byte(chars, 3) is Some(g) else { return None }
  guard hex_byte(chars, 5) is Some(b) else { return None }
  let a = if chars.length() >= 9 {
    hex_byte(chars, 7).unwrap_or(b'\xFF')
  } else {
    b'\xFF'
  }
  Some(@theme.RgbaColor::new(r, g, b, a))
}

///|
/// Parse two hex characters at offset into a byte.
fn hex_byte(chars : Array[Char], offset : Int) -> Byte? {
  guard hex_digit(chars[offset]) is Some(hi) else { return None }
  guard hex_digit(chars[offset + 1]) is Some(lo) else { return None }
  Some((hi * 16 + lo).to_byte())
}

///|
fn hex_digit(c : Char) -> Int? {
  let code = c.to_int()
  if code >= 0x30 && code <= 0x39 {
    Some(code - 0x30)
  } else if code >= 0x41 && code <= 0x46 {
    Some(code - 0x41 + 10)
  } else if code >= 0x61 && code <= 0x66 {
    Some(code - 0x61 + 10)
  } else {
    None
  }
}
