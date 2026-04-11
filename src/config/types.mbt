///|
/// Application configuration loaded from TOML file.
///
/// This is the unified configuration structure that replaces scattered
/// hardcoded defaults across AppConfig, RendererConfig, and Theme.
pub(all) struct Config {
  /// Terminal settings.
  terminal : TerminalConfig
  /// Renderer settings.
  renderer : RendererConfigValues
  /// Theme name to use (e.g. "midnight", "classic").
  theme_name : String
  /// Custom theme color overrides (applied on top of named theme).
  theme_overrides : ThemeOverrides
  /// UI chrome settings (tab bar, panels, etc.).
  ui : UIConfig
} derive(Show)

///|
pub(all) struct TerminalConfig {
  rows : Int
  cols : Int
  shell : String
  max_scrollback : Int
} derive(Show)

///|
pub(all) struct RendererConfigValues {
  font_size : Int
  dpi_scale : Float
  atlas_size : Int
} derive(Show)

///|
/// Optional overrides for theme colors.
/// None means "use the named theme's default".
pub(all) struct ThemeOverrides {
  fg : @theme.RgbaColor?
  bg : @theme.RgbaColor?
  cursor : @theme.RgbaColor?
  selection : @theme.RgbaColor?
  bg_alpha : Float?
} derive(Show)

///|
pub fn Config::default() -> Config {
  {
    terminal: {
      rows: 24,
      cols: 80,
      shell: "/bin/zsh",
      max_scrollback: 10000,
    },
    renderer: { font_size: 14, dpi_scale: 1.0, atlas_size: 1024 },
    theme_name: "midnight",
    theme_overrides: { fg: None, bg: None, cursor: None, selection: None, bg_alpha: None },
    ui: UIConfig::default(),
  }
}

///|
/// Convert config to AppConfig for backward compatibility.
pub fn Config::to_app_config(self : Config) -> @renderer.RendererConfig {
  {
    cell_width: 8,
    cell_height: 16,
    font_size: self.renderer.font_size,
    dpi_scale: self.renderer.dpi_scale,
    atlas_size: self.renderer.atlas_size,
  }
}

///|
/// Resolve theme from config: start with named theme, apply overrides.
pub fn Config::resolve_theme(self : Config) -> @theme.Theme {
  let base = match self.theme_name {
    "classic" => @theme.Theme::classic()
    _ => @theme.Theme::midnight()
  }
  let overrides = self.theme_overrides
  {
    ..base,
    fg: overrides.fg.unwrap_or(base.fg),
    bg: overrides.bg.unwrap_or(base.bg),
    cursor: overrides.cursor.unwrap_or(base.cursor),
    selection: overrides.selection.unwrap_or(base.selection),
    bg_alpha: overrides.bg_alpha.unwrap_or(base.bg_alpha),
  }
}
