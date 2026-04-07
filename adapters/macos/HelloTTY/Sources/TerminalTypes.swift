import Foundation
import AppKit

/// Parsed terminal grid state from the MoonBit core.
struct TerminalGrid {
    let rows: Int
    let cols: Int
    let cursor: CursorState
    let cells: [CellData]

    struct CursorState {
        let row: Int
        let col: Int
        let visible: Bool
        let style: CursorStyle
    }

    enum CursorStyle: String {
        case block, underline, bar
    }

    struct CellData {
        let row: Int
        let col: Int
        let char: Character
        let fg: NSColor
        let bg: NSColor
        let attrs: Int  // Bitfield: 1=bold, 2=italic, 4=underline, 64=strikethrough, 128=dim, 16=inverse

        var isBold: Bool { attrs & 1 != 0 }
        var isItalic: Bool { attrs & 2 != 0 }
        var isUnderline: Bool { attrs & 4 != 0 }
        var isStrikethrough: Bool { attrs & 64 != 0 }
        var isDim: Bool { attrs & 128 != 0 }
        var isInverse: Bool { attrs & 16 != 0 }
    }

    /// Parse from JSON string produced by ffi_get_grid().
    ///
    /// Color resolution:
    ///   - `null` → theme default (fg or bg depending on position)
    ///   - `[r, g, b]` → RGB
    ///   - `[index]` → 256-color palette via theme
    static func fromJSON(_ jsonStr: String, theme: TerminalTheme) -> TerminalGrid? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rows = obj["rows"] as? Int ?? 24
        let cols = obj["cols"] as? Int ?? 80

        // Parse cursor
        let cursorObj = obj["cursor"] as? [String: Any] ?? [:]
        let cursor = CursorState(
            row: cursorObj["row"] as? Int ?? 0,
            col: cursorObj["col"] as? Int ?? 0,
            visible: cursorObj["visible"] as? Bool ?? true,
            style: CursorStyle(rawValue: cursorObj["style"] as? String ?? "block") ?? .block
        )

        // Parse cells
        let cellsArray = obj["cells"] as? [[String: Any]] ?? []
        let cells = cellsArray.compactMap { cellObj -> CellData? in
            guard let r = cellObj["r"] as? Int,
                  let c = cellObj["c"] as? Int,
                  let ch = cellObj["ch"] as? String,
                  let firstChar = ch.first
            else { return nil }

            let attrs = cellObj["a"] as? Int ?? 0
            let isInverse = attrs & 16 != 0

            var fg = parseColor(cellObj["fg"], default: theme.foreground, theme: theme)
            var bg = parseColor(cellObj["bg"], default: theme.background, theme: theme)

            // Inverse video: swap fg and bg
            if isInverse {
                swap(&fg, &bg)
            }

            return CellData(row: r, col: c, char: firstChar, fg: fg, bg: bg, attrs: attrs)
        }

        return TerminalGrid(rows: rows, cols: cols, cursor: cursor, cells: cells)
    }

    /// Parse a color from JSON.
    /// - `NSNull` / nil → `defaultColor` (theme fg or bg)
    /// - `[r, g, b]` → RGB
    /// - `[index]` → indexed via theme palette
    private static func parseColor(_ value: Any?, default defaultColor: NSColor, theme: TerminalTheme) -> NSColor {
        // null from JSON → NSNull or nil
        if value == nil || value is NSNull {
            return defaultColor
        }
        guard let arr = value as? [Int] else { return defaultColor }
        if arr.count == 3 {
            return NSColor(
                srgbRed: CGFloat(arr[0]) / 255.0,
                green: CGFloat(arr[1]) / 255.0,
                blue: CGFloat(arr[2]) / 255.0,
                alpha: 1.0
            )
        } else if arr.count == 1 {
            return theme.resolveIndexed(arr[0])
        }
        return defaultColor
    }
}
