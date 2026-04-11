import AppKit

/// Terminal color theme — thin Swift wrapper around MoonBit theme SoT.
///
/// The canonical theme definition lives in MoonBit (src/theme/).
/// This struct holds only the platform-native NSColor conversions
/// needed by the macOS adapter for window chrome, selection overlay,
/// and the CPU fallback renderer.
struct TerminalTheme {
    let name: String
    let foreground: NSColor
    let background: NSColor
    let cursor: NSColor
    let selection: NSColor
    let boldColor: NSColor?
    let isDark: Bool
    let bgAlpha: CGFloat

    /// The NSAppearance that matches this theme's background.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Load theme from MoonBit bridge (SoT).
    /// All color values including alpha come from MoonBit — no hardcoded overrides.
    static func fromBridge(_ bridge: MoonBitBridge) -> TerminalTheme {
        guard let info = bridge.getTheme() else {
            fatalError("hello_tty: failed to load theme from MoonBit bridge — dylib not loaded")
        }
        return TerminalTheme(
            name: info.name,
            foreground: nsColor(info.fg),
            background: nsColor(info.bg, alphaOverride: CGFloat(info.bgAlpha)),
            cursor: nsColor(info.cursor),
            selection: nsColor(info.selection),
            boldColor: NSColor(white: 1.0, alpha: 1),
            isDark: info.isDark,
            bgAlpha: CGFloat(info.bgAlpha)
        )
    }

    /// Convert RGBA tuple to NSColor. Alpha comes from the tuple's 4th element.
    /// alphaOverride: if set, overrides the tuple's alpha (used for bg with bgAlpha).
    private static func nsColor(_ rgba: (Int, Int, Int, Int), alphaOverride: CGFloat? = nil) -> NSColor {
        let alpha = alphaOverride ?? (CGFloat(rgba.3) / 255.0)
        return NSColor(
            srgbRed: CGFloat(rgba.0) / 255.0,
            green: CGFloat(rgba.1) / 255.0,
            blue: CGFloat(rgba.2) / 255.0,
            alpha: alpha
        )
    }
}
