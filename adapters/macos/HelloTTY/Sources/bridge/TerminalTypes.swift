import Foundation
import AppKit

/// Parsed terminal grid state from the MoonBit core.
///
/// Colors are FULLY RESOLVED by MoonBit (src/theme/) before crossing FFI.
/// This struct only converts [r,g,b] arrays to NSColor — no palette resolution.
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
        let width: Int  // Cell width in columns (1=normal, 2=wide CJK/emoji)
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
    /// Colors are pre-resolved as [r,g,b] by MoonBit — no theme needed.
    static func fromJSON(_ jsonStr: String) -> TerminalGrid? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rows = obj["rows"] as? Int ?? 24
        let cols = obj["cols"] as? Int ?? 80

        let cursorObj = obj["cursor"] as? [String: Any] ?? [:]
        let cursor = CursorState(
            row: cursorObj["row"] as? Int ?? 0,
            col: cursorObj["col"] as? Int ?? 0,
            visible: cursorObj["visible"] as? Bool ?? true,
            style: CursorStyle(rawValue: cursorObj["style"] as? String ?? "block") ?? .block
        )

        let cellsArray = obj["cells"] as? [[String: Any]] ?? []
        let cells = cellsArray.compactMap { cellObj -> CellData? in
            guard let r = cellObj["r"] as? Int,
                  let c = cellObj["c"] as? Int,
                  let ch = cellObj["ch"] as? String,
                  let firstChar = ch.first
            else { return nil }

            let attrs = cellObj["a"] as? Int ?? 0
            let width = cellObj["w"] as? Int ?? 1
            let fg = parseRGB(cellObj["fg"])
            let bg = parseRGB(cellObj["bg"])

            return CellData(row: r, col: c, char: firstChar, width: width, fg: fg, bg: bg, attrs: attrs)
        }

        return TerminalGrid(rows: rows, cols: cols, cursor: cursor, cells: cells)
    }

    /// Parse an [r, g, b] array to NSColor. Falls back to white/black.
    private static func parseRGB(_ value: Any?) -> NSColor {
        guard let arr = value as? [Int], arr.count == 3 else {
            return NSColor(white: 0.9, alpha: 1)
        }
        return NSColor(
            srgbRed: CGFloat(arr[0]) / 255.0,
            green: CGFloat(arr[1]) / 255.0,
            blue: CGFloat(arr[2]) / 255.0,
            alpha: 1.0
        )
    }
}
