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
        let attrs: Int  // Bitfield: 1=bold, 2=italic, 4=underline, etc.

        var isBold: Bool { attrs & 1 != 0 }
        var isItalic: Bool { attrs & 2 != 0 }
        var isUnderline: Bool { attrs & 4 != 0 }
        var isStrikethrough: Bool { attrs & 64 != 0 }
        var isDim: Bool { attrs & 128 != 0 }
        var isInverse: Bool { attrs & 16 != 0 }
    }

    /// Parse from JSON string produced by ffi_get_grid().
    static func fromJSON(_ jsonStr: String) -> TerminalGrid? {
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

            let fg = parseColor(cellObj["fg"])
            let bg = parseColor(cellObj["bg"])
            let attrs = cellObj["a"] as? Int ?? 0

            return CellData(row: r, col: c, char: firstChar, fg: fg, bg: bg, attrs: attrs)
        }

        return TerminalGrid(rows: rows, cols: cols, cursor: cursor, cells: cells)
    }

    /// Parse a color from JSON array.
    /// [r, g, b] → RGB color
    /// [index]   → indexed color (resolve via palette)
    /// null/missing → default color
    private static func parseColor(_ value: Any?) -> NSColor {
        guard let arr = value as? [Int] else { return .white }
        if arr.count == 3 {
            return NSColor(
                red: CGFloat(arr[0]) / 255.0,
                green: CGFloat(arr[1]) / 255.0,
                blue: CGFloat(arr[2]) / 255.0,
                alpha: 1.0
            )
        } else if arr.count == 1 {
            return resolveIndexedColor(arr[0])
        }
        return .white
    }

    /// Resolve a 256-color palette index to NSColor.
    private static func resolveIndexedColor(_ index: Int) -> NSColor {
        // Standard 16 ANSI colors
        let ansiColors: [NSColor] = [
            .black,                                                     // 0
            NSColor(red: 0.67, green: 0, blue: 0, alpha: 1),           // 1 Red
            NSColor(red: 0, green: 0.67, blue: 0, alpha: 1),           // 2 Green
            NSColor(red: 0.67, green: 0.33, blue: 0, alpha: 1),        // 3 Yellow
            NSColor(red: 0, green: 0, blue: 0.67, alpha: 1),           // 4 Blue
            NSColor(red: 0.67, green: 0, blue: 0.67, alpha: 1),        // 5 Magenta
            NSColor(red: 0, green: 0.67, blue: 0.67, alpha: 1),        // 6 Cyan
            NSColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1),     // 7 White
            NSColor(red: 0.33, green: 0.33, blue: 0.33, alpha: 1),     // 8 Bright Black
            NSColor(red: 1, green: 0.33, blue: 0.33, alpha: 1),        // 9 Bright Red
            NSColor(red: 0.33, green: 1, blue: 0.33, alpha: 1),        // 10 Bright Green
            NSColor(red: 1, green: 1, blue: 0.33, alpha: 1),           // 11 Bright Yellow
            NSColor(red: 0.33, green: 0.33, blue: 1, alpha: 1),        // 12 Bright Blue
            NSColor(red: 1, green: 0.33, blue: 1, alpha: 1),           // 13 Bright Magenta
            NSColor(red: 0.33, green: 1, blue: 1, alpha: 1),           // 14 Bright Cyan
            .white,                                                      // 15 Bright White
        ]

        if index >= 0 && index < 16 {
            return ansiColors[index]
        }

        // 216 color cube (16-231)
        if index >= 16 && index < 232 {
            let ci = index - 16
            let cubeValues: [CGFloat] = [0, 0.37, 0.53, 0.69, 0.84, 1.0]
            let ri = ci / 36
            let gi = (ci / 6) % 6
            let bi = ci % 6
            return NSColor(red: cubeValues[ri], green: cubeValues[gi], blue: cubeValues[bi], alpha: 1)
        }

        // Grayscale (232-255)
        if index >= 232 && index < 256 {
            let gray = CGFloat(8 + (index - 232) * 10) / 255.0
            return NSColor(white: gray, alpha: 1)
        }

        return .white
    }
}
