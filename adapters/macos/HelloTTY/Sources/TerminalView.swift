import SwiftUI
import AppKit

/// The main terminal rendering view.
///
/// Renders the terminal grid using CoreText for glyph drawing and
/// CoreGraphics for cell backgrounds. This is a custom NSView wrapped
/// in SwiftUI via NSViewRepresentable, for performance-critical rendering.
struct TerminalView: NSViewRepresentable {
    @ObservedObject var state: TerminalState

    func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView()
        view.terminalState = state
        return view
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        nsView.terminalState = state
        nsView.needsDisplay = true
    }
}

/// The terminal state observable, bridging MoonBit core to SwiftUI.
class TerminalState: ObservableObject {
    @Published var grid: TerminalGrid?
    @Published var title: String = "hello_tty"

    let bridge = MoonBitBridge.shared
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var font: NSFont

    init() {
        font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        // Calculate cell dimensions from font metrics
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let mSize = ("M" as NSString).size(withAttributes: attrs)
        cellWidth = ceil(mSize.width)
        cellHeight = ceil(font.ascender - font.descender + font.leading)
    }

    func initialize(rows: Int = 24, cols: Int = 80) {
        _ = bridge.initialize(rows: rows, cols: cols)
    }

    func processOutput(_ data: String) {
        _ = bridge.processOutput(data)
        refresh()
    }

    func handleKey(keyCode: Int, modifiers: Int) -> String? {
        let result = bridge.handleKey(keyCode: keyCode, modifiers: modifiers)
        refresh()
        return result
    }

    func resize(rows: Int, cols: Int) {
        _ = bridge.resize(rows: rows, cols: cols)
        refresh()
    }

    func refresh() {
        grid = bridge.getGrid()
        title = bridge.getTitle()
    }

    func shutdown() {
        bridge.shutdown()
    }
}

/// Custom NSView for terminal grid rendering via CoreGraphics/CoreText.
///
/// This avoids SwiftUI's overhead for per-cell rendering.
/// Each cell's background is drawn as a filled rect, then the glyph
/// is drawn on top using CoreText with the cell's foreground color.
class TerminalNSView: NSView {
    var terminalState: TerminalState?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let state = terminalState,
              let grid = state.grid
        else { return }

        let cellW = state.cellWidth
        let cellH = state.cellHeight
        let font = state.font

        // Clear background
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        // Build a lookup for cells by (row, col)
        var cellMap: [Int: [Int: TerminalGrid.CellData]] = [:]
        for cell in grid.cells {
            if cellMap[cell.row] == nil {
                cellMap[cell.row] = [:]
            }
            cellMap[cell.row]![cell.col] = cell
        }

        // Draw cell backgrounds and characters
        for row in 0..<grid.rows {
            let y = bounds.height - CGFloat(row + 1) * cellH  // Flip Y (macOS)
            for col in 0..<grid.cols {
                let x = CGFloat(col) * cellW
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)

                if let cell = cellMap[row]?[col] {
                    // Background
                    ctx.setFillColor(cell.bg.cgColor)
                    ctx.fill(rect)

                    // Character
                    let str = String(cell.char)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: cell.isBold
                            ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
                            : font,
                        .foregroundColor: cell.isDim
                            ? cell.fg.withAlphaComponent(0.5)
                            : cell.fg,
                        .underlineStyle: cell.isUnderline
                            ? NSUnderlineStyle.single.rawValue
                            : 0,
                        .strikethroughStyle: cell.isStrikethrough
                            ? NSUnderlineStyle.single.rawValue
                            : 0,
                    ]
                    let attrStr = NSAttributedString(string: str, attributes: attrs)
                    let line = CTLineCreateWithAttributedString(attrStr)
                    ctx.textPosition = CGPoint(x: x, y: y + font.descender.magnitude)
                    CTLineDraw(line, ctx)
                }
            }
        }

        // Draw cursor
        if grid.cursor.visible {
            let cursorX = CGFloat(grid.cursor.col) * cellW
            let cursorY = bounds.height - CGFloat(grid.cursor.row + 1) * cellH
            var cursorRect = CGRect(x: cursorX, y: cursorY, width: cellW, height: cellH)

            switch grid.cursor.style {
            case .underline:
                cursorRect = CGRect(x: cursorX, y: cursorY, width: cellW, height: 2)
            case .bar:
                cursorRect = CGRect(x: cursorX, y: cursorY, width: 2, height: cellH)
            case .block:
                break
            }

            ctx.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.fill(cursorRect)
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let state = terminalState else { return }

        let chars = event.charactersIgnoringModifiers ?? ""
        guard let firstChar = chars.unicodeScalars.first else { return }
        let keyCode = Int(firstChar.value)

        var mods = 0
        if event.modifierFlags.contains(.shift)   { mods |= 1 }
        if event.modifierFlags.contains(.control)  { mods |= 2 }
        if event.modifierFlags.contains(.option)   { mods |= 4 }
        if event.modifierFlags.contains(.command)   { mods |= 8 }

        if let ptyData = state.handleKey(keyCode: keyCode, modifiers: mods) {
            // In a full implementation, send ptyData to the PTY reader via IPC.
            // For now, feed it back as if the terminal echoed it.
            _ = ptyData
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String, let state = terminalState else { return }
        for ch in str.unicodeScalars {
            _ = state.handleKey(keyCode: Int(ch.value), modifiers: 0)
        }
    }

    func doCommandBySelector(_ selector: Selector) {
        // Suppress system beep
    }
}
