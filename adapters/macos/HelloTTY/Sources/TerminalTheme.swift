import AppKit

/// Terminal color theme.
///
/// Defines foreground, background, cursor, selection, and the 256-color
/// ANSI palette.  The theme is the single source of truth for all color
/// decisions in the rendering pipeline; the MoonBit core sends `null`
/// for "default" colors, and the Swift layer resolves them here.
struct TerminalTheme {
    let name: String

    /// Default foreground color (when MoonBit sends null fg).
    let foreground: NSColor
    /// Default background color (when MoonBit sends null bg).
    let background: NSColor
    /// Cursor color.
    let cursor: NSColor
    /// Selection highlight.
    let selection: NSColor
    /// Bold text color override (nil = same as foreground).
    let boldColor: NSColor?

    /// The 16 ANSI palette colors (indices 0–15).
    let ansi: [NSColor]

    /// Whether this theme has a dark background.
    /// Used to set the window appearance so that the system toolbar chrome
    /// (traffic lights, title text, toolbar glass tint) matches the terminal.
    var isDark: Bool {
        guard let c = background.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance < 0.5
    }

    /// The NSAppearance that matches this theme's background.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // MARK: - Full 256-color resolution

    /// Resolve a palette index (0–255) to a concrete color.
    func resolveIndexed(_ index: Int) -> NSColor {
        if index >= 0 && index < 16 {
            return ansi[index]
        }
        // 216-color cube (indices 16–231)
        if index >= 16 && index < 232 {
            let ci = index - 16
            // Standard xterm cube levels: 0, 95, 135, 175, 215, 255
            let cubeValues: [CGFloat] = [0, 95.0/255.0, 135.0/255.0, 175.0/255.0, 215.0/255.0, 1.0]
            let ri = ci / 36
            let gi = (ci / 6) % 6
            let bi = ci % 6
            return NSColor(
                srgbRed: cubeValues[ri],
                green: cubeValues[gi],
                blue: cubeValues[bi],
                alpha: 1
            )
        }
        // Grayscale ramp (indices 232–255)
        if index >= 232 && index < 256 {
            let gray = CGFloat(8 + (index - 232) * 10) / 255.0
            return NSColor(white: gray, alpha: 1)
        }
        return foreground
    }
}

// MARK: - Built-in themes

extension TerminalTheme {
    /// A dark theme inspired by modern macOS terminal aesthetics.
    /// Semi-transparent background for Liquid Glass vibrancy.
    static let midnight = TerminalTheme(
        name: "Midnight",
        foreground: NSColor(white: 0.90, alpha: 1),
        background: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.82),
        cursor: NSColor(srgbRed: 0.40, green: 0.70, blue: 1.0, alpha: 0.85),
        selection: NSColor(srgbRed: 0.25, green: 0.45, blue: 0.75, alpha: 0.40),
        boldColor: NSColor(white: 1.0, alpha: 1),
        ansi: [
            // Normal colors (0–7)
            NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1),  // 0  Black
            NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1),  // 1  Red
            NSColor(srgbRed: 0.35, green: 0.80, blue: 0.40, alpha: 1),  // 2  Green
            NSColor(srgbRed: 0.90, green: 0.75, blue: 0.35, alpha: 1),  // 3  Yellow
            NSColor(srgbRed: 0.40, green: 0.60, blue: 0.95, alpha: 1),  // 4  Blue
            NSColor(srgbRed: 0.75, green: 0.45, blue: 0.85, alpha: 1),  // 5  Magenta
            NSColor(srgbRed: 0.35, green: 0.80, blue: 0.80, alpha: 1),  // 6  Cyan
            NSColor(srgbRed: 0.75, green: 0.75, blue: 0.78, alpha: 1),  // 7  White

            // Bright colors (8–15)
            NSColor(srgbRed: 0.40, green: 0.40, blue: 0.45, alpha: 1),  // 8  Bright Black
            NSColor(srgbRed: 1.00, green: 0.45, blue: 0.45, alpha: 1),  // 9  Bright Red
            NSColor(srgbRed: 0.50, green: 0.95, blue: 0.55, alpha: 1),  // 10 Bright Green
            NSColor(srgbRed: 1.00, green: 0.90, blue: 0.50, alpha: 1),  // 11 Bright Yellow
            NSColor(srgbRed: 0.55, green: 0.75, blue: 1.00, alpha: 1),  // 12 Bright Blue
            NSColor(srgbRed: 0.90, green: 0.60, blue: 1.00, alpha: 1),  // 13 Bright Magenta
            NSColor(srgbRed: 0.50, green: 0.95, blue: 0.95, alpha: 1),  // 14 Bright Cyan
            NSColor(white: 0.95, alpha: 1),                              // 15 Bright White
        ]
    )

    /// Classic opaque dark theme (no transparency).
    static let classic = TerminalTheme(
        name: "Classic",
        foreground: NSColor(white: 0.85, alpha: 1),
        background: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1.0),
        cursor: NSColor(white: 0.85, alpha: 0.80),
        selection: NSColor(srgbRed: 0.20, green: 0.35, blue: 0.60, alpha: 0.45),
        boldColor: nil,
        ansi: TerminalTheme.midnight.ansi
    )
}
