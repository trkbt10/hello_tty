///|
/// UI chrome configuration.
///
/// Controls the appearance of the tab bar, panels, and other
/// non-terminal UI elements. These values are passed to the
/// platform adapter (Swift/GTK) via the bridge as JSON.
///
/// ## Corner radius model
///
/// The corner radius system uses a ratio-based approach to prevent
/// mismatched radii between nested elements. Given:
///
///   outer_radius = element_height * corner_ratio
///   inner_radius = max(outer_radius - padding, 0)
///
/// This ensures the inner shape follows the outer curvature correctly.
/// When padding >= outer_radius, inner corners become square (radius 0),
/// which is geometrically correct.
pub(all) struct UIConfig {
  /// Tab bar height in points.
  tab_bar_height : Float
  /// Corner radius as a ratio of the tab height (0.0–0.5).
  /// 0.5 = fully rounded (capsule), 0.0 = square corners.
  /// The actual corner radius is computed as: tab_height * corner_ratio.
  tab_corner_ratio : Float
  /// Horizontal padding inside a tab (points).
  tab_padding_horizontal : Float
  /// Vertical padding inside a tab (points).
  tab_padding_vertical : Float
  /// Leading padding of the tab bar (points).
  /// NSTitlebarAccessoryViewController (.top) places content below the
  /// titlebar, so traffic light buttons do not overlap — no extra inset needed.
  titlebar_leading_inset : Float
  /// Trailing padding of the tab bar (points).
  titlebar_trailing_inset : Float
  /// Padding from close button center to tab trailing edge (points).
  /// Must be >= outer corner radius to keep the button inside the rounded area.
  tab_close_button_inset : Float
  /// Width/height of the close button circle (points).
  tab_close_button_size : Float
  /// Tab bar separator line thickness (points).
  separator_thickness : Float
  /// Minimum inter-tab spacing (points).
  tab_spacing : Float
  /// Minimum tab width (points).
  tab_min_width : Float
  /// Maximum tab width (points).
  tab_max_width : Float
  /// Panel divider visible thickness (points).
  panel_divider_thickness : Float
  /// Panel divider hit area total thickness (points).
  panel_divider_hit_area : Float
  /// Corner radius for floating overlay panels (search bar, etc.) in points.
  overlay_corner_radius : Float
  /// Border width for floating overlay panels in points.
  overlay_border_width : Float
  /// Background opacity for floating overlay panels (0.0–1.0).
  /// Lower values let terminal content show through; higher values improve
  /// text readability on the overlay.
  overlay_bg_opacity : Float
} derive(Show)

///|
pub fn UIConfig::default() -> UIConfig {
  {
    tab_bar_height: 42.0,
    tab_corner_ratio: 0.31, // 26pt tab height × 0.31 ≈ 8pt radius
    tab_padding_horizontal: 12.0,
    tab_padding_vertical: 6.0,
    titlebar_leading_inset: 12.0,
    titlebar_trailing_inset: 12.0,
    tab_close_button_inset: 10.0,
    tab_close_button_size: 16.0,
    separator_thickness: 1.0,
    tab_spacing: 4.0,
    tab_min_width: 80.0,
    tab_max_width: 180.0,
    panel_divider_thickness: 1.0,
    panel_divider_hit_area: 4.0,
    overlay_corner_radius: 6.0,
    overlay_border_width: 0.5,
    overlay_bg_opacity: 0.95,
  }
}

///|
/// Compute the actual tab height from font metrics and padding.
/// font_line_height is approximately 14pt for a 12pt system font.
pub fn UIConfig::tab_content_height(self : UIConfig, font_line_height : Float) -> Float {
  font_line_height + self.tab_padding_vertical * 2.0
}

///|
/// Compute the outer corner radius from tab height.
pub fn UIConfig::outer_corner_radius(self : UIConfig, tab_height : Float) -> Float {
  tab_height * self.tab_corner_ratio
}

///|
/// Compute the inner corner radius for horizontal padding.
/// inner_r = max(outer_r - h_padding, 0)
pub fn UIConfig::inner_corner_radius_h(self : UIConfig, tab_height : Float) -> Float {
  let outer = self.outer_corner_radius(tab_height)
  let inner = outer - self.tab_padding_horizontal
  if inner > 0.0 {
    inner
  } else {
    0.0
  }
}

///|
/// Compute the inner corner radius for vertical padding.
/// inner_r = max(outer_r - v_padding, 0)
pub fn UIConfig::inner_corner_radius_v(self : UIConfig, tab_height : Float) -> Float {
  let outer = self.outer_corner_radius(tab_height)
  let inner = outer - self.tab_padding_vertical
  if inner > 0.0 {
    inner
  } else {
    0.0
  }
}

///|
/// Validate and clamp close button inset to be >= outer corner radius.
/// Returns the effective inset.
pub fn UIConfig::effective_close_button_inset(
  self : UIConfig,
  tab_height : Float
) -> Float {
  let outer_r = self.outer_corner_radius(tab_height)
  if self.tab_close_button_inset >= outer_r {
    self.tab_close_button_inset
  } else {
    outer_r
  }
}

///|
/// Serialize UI config to JSON for passing across FFI to the platform adapter.
/// The adapter uses these values instead of hardcoded constants.
pub fn UIConfig::to_json(self : UIConfig, font_line_height : Float) -> Json {
  let tab_height = self.tab_content_height(font_line_height)
  let outer_r = self.outer_corner_radius(tab_height)
  let inner_r_h = self.inner_corner_radius_h(tab_height)
  let inner_r_v = self.inner_corner_radius_v(tab_height)
  let close_inset = self.effective_close_button_inset(tab_height)
  // Extra trailing padding when close button is visible:
  // button_size + close_inset - horizontal_padding
  let close_extra_padding = self.tab_close_button_size + close_inset -
    self.tab_padding_horizontal
  let close_extra = if close_extra_padding > 0.0 {
    close_extra_padding
  } else {
    0.0
  }
  let map : Map[String, Json] = {
    // Computed values from ratio
    "tab_height": tab_height.to_double().to_json(),
    "outer_corner_radius": outer_r.to_double().to_json(),
    "inner_corner_radius_h": inner_r_h.to_double().to_json(),
    "inner_corner_radius_v": inner_r_v.to_double().to_json(),
    "close_button_inset": close_inset.to_double().to_json(),
    "close_button_extra_trailing": close_extra.to_double().to_json(),
    // Direct config values
    "tab_bar_height": self.tab_bar_height.to_double().to_json(),
    "tab_corner_ratio": self.tab_corner_ratio.to_double().to_json(),
    "tab_padding_horizontal": self.tab_padding_horizontal.to_double().to_json(),
    "tab_padding_vertical": self.tab_padding_vertical.to_double().to_json(),
    "titlebar_leading_inset": self.titlebar_leading_inset.to_double().to_json(),
    "titlebar_trailing_inset": self.titlebar_trailing_inset.to_double().to_json(),
    "tab_close_button_size": self.tab_close_button_size.to_double().to_json(),
    "separator_thickness": self.separator_thickness.to_double().to_json(),
    "tab_spacing": self.tab_spacing.to_double().to_json(),
    "tab_min_width": self.tab_min_width.to_double().to_json(),
    "tab_max_width": self.tab_max_width.to_double().to_json(),
    "panel_divider_thickness": self.panel_divider_thickness.to_double().to_json(),
    "panel_divider_hit_area": self.panel_divider_hit_area.to_double().to_json(),
    "overlay_corner_radius": self.overlay_corner_radius.to_double().to_json(),
    "overlay_border_width": self.overlay_border_width.to_double().to_json(),
    "overlay_bg_opacity": self.overlay_bg_opacity.to_double().to_json(),
  }
  map.to_json()
}
