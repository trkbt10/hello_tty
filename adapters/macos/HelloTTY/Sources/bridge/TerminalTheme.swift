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
    static func fromBridge(_ bridge: MoonBitBridge) -> TerminalTheme {
        guard let info = bridge.getTheme() else {
            return .fallback
        }
        return TerminalTheme(
            name: info.name,
            foreground: nsColor(info.fg),
            background: nsColor(info.bg, alpha: CGFloat(info.bgAlpha)),
            cursor: nsColor(info.cursor, alpha: 0.85),
            selection: nsColor(info.selection, alpha: 0.40),
            boldColor: NSColor(white: 1.0, alpha: 1),
            isDark: info.isDark,
            bgAlpha: CGFloat(info.bgAlpha)
        )
    }

    /// Fallback theme when bridge is not loaded.
    static let fallback = TerminalTheme(
        name: "Fallback",
        foreground: NSColor(white: 0.90, alpha: 1),
        background: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.82),
        cursor: NSColor(srgbRed: 0.40, green: 0.70, blue: 1.0, alpha: 0.85),
        selection: NSColor(srgbRed: 0.25, green: 0.45, blue: 0.75, alpha: 0.40),
        boldColor: NSColor(white: 1.0, alpha: 1),
        isDark: true,
        bgAlpha: 0.82
    )

    private static func nsColor(_ rgb: (Int, Int, Int), alpha: CGFloat = 1.0) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.0) / 255.0,
            green: CGFloat(rgb.1) / 255.0,
            blue: CGFloat(rgb.2) / 255.0,
            alpha: alpha
        )
    }
}
