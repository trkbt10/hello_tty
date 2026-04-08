import AppKit

/// Centralized keyboard/IME input handler for terminal views.
///
/// This is the single source of truth for input processing. Both
/// TerminalNSView (CoreText) and TerminalGPUView (wgpu) delegate
/// to this handler rather than implementing input logic themselves.
///
/// Responsibilities:
///   - Classify key events (special key vs printable)
///   - Route special keys directly to PTY via bridge
///   - Handle Cmd+C/V (copy/paste)
///   - Provide NSTextInputClient callback targets (insertText, setMarkedText)
///
/// NOT responsible for:
///   - NSView lifecycle (keyDown override, inputContext creation — view does this)
///   - Rendering
class InputHandler {
    weak var state: TerminalState?
    /// TabManager for panel/tab operations. Set by the view hierarchy.
    weak var tabManager: TabManager?

    // Stash the current event for doCommand(by:) which only receives a selector
    var currentEvent: NSEvent?

    // IME state
    var markedText: NSAttributedString?
    var markedNSRange: NSRange = NSRange(location: NSNotFound, length: 0)
    var selectedNSRange: NSRange = NSRange(location: 0, length: 0)

    // Selection state (shared across views)
    var selectionAnchor: (row: Int, col: Int)?
    var selectionEnd: (row: Int, col: Int)?

    /// Callback invoked when Cmd+F is pressed. Set by the view hierarchy.
    var onFindRequested: (() -> Void)?

    init(state: TerminalState) {
        self.state = state
    }

    // MARK: - Key Event Processing

    /// Process a keyDown event. Returns true if handled (view should not propagate).
    /// If false, the view should pass the event to `inputContext?.handleEvent`.
    ///
    /// Key classification is delegated to MoonBit (src/input/) — the SoT.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let state = state else { return false }

        let chars = event.charactersIgnoringModifiers ?? ""
        guard let firstChar = chars.unicodeScalars.first else {
            return false
        }
        let keyCode = Int(firstChar.value)

        var mods = 0
        if event.modifierFlags.contains(.shift)   { mods |= 1 }
        if event.modifierFlags.contains(.control)  { mods |= 2 }
        if event.modifierFlags.contains(.option)   { mods |= 4 }
        if event.modifierFlags.contains(.command)  { mods |= 8 }

        // Ask MoonBit to classify this key
        let classification = state.bridge.classifyKey(
            keyCode: keyCode, modifiers: mods, hasMarkedText: hasMarkedText)

        switch classification {
        case .directToPty:
            clearSelection()
            state.sendKey(keyCode: keyCode, modifiers: mods)
            return true

        case .clipboardCopy:
            if let text = selectedText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true

        case .clipboardCut:
            if let text = selectedText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            clearSelection()
            return true

        case .clipboardPaste:
            if let text = NSPasteboard.general.string(forType: .string) {
                state.sendText(text)
            }
            return true

        case .selectAll:
            selectAll()
            return true

        case .findInTerminal:
            onFindRequested?()
            return true

        case .forwardToIme:
            clearSelection()
            return false // caller passes to inputContext

        // ---- Split operations ----
        case .splitRight:
            tabManager?.splitFocusedPanel(direction: 0) // vertical
            return true

        case .splitDown:
            tabManager?.splitFocusedPanel(direction: 1) // horizontal
            return true

        case .nextSplit:
            tabManager?.focusNextSplit()
            return true

        case .prevSplit:
            tabManager?.focusPrevSplit()
            return true

        case .focusDirection(let dir):
            tabManager?.focusDirection(dir)
            return true

        // ---- Tab operations ----
        case .newTab:
            tabManager?.newTab()
            return true

        case .closePanel:
            tabManager?.closeFocusedPanel()
            return true

        case .nextTab:
            tabManager?.nextTab()
            return true

        case .prevTab:
            tabManager?.prevTab()
            return true

        case .gotoTab(let index):
            tabManager?.gotoTab(index)
            return true
        }
    }

    // MARK: - NSTextInputClient Callbacks

    /// Handle doCommand(by:) from IME — called for keys that aren't text input
    /// (Enter, Tab, Backspace, Delete, Escape, arrows via IME path).
    func handleDoCommand(_ event: NSEvent?) {
        guard let state = state, let event = event else { return }
        let chars = event.charactersIgnoringModifiers ?? ""
        guard let firstChar = chars.unicodeScalars.first else { return }
        let keyCode = Int(firstChar.value)
        var mods = 0
        if event.modifierFlags.contains(.shift)   { mods |= 1 }
        if event.modifierFlags.contains(.control)  { mods |= 2 }
        if event.modifierFlags.contains(.option)   { mods |= 4 }
        if event.modifierFlags.contains(.command)  { mods |= 8 }
        state.sendKey(keyCode: keyCode, modifiers: mods)
    }

    func handleInsertText(_ string: Any) {
        markedText = nil
        markedNSRange = NSRange(location: NSNotFound, length: 0)

        let str: String
        if let s = string as? String { str = s }
        else if let s = string as? NSAttributedString { str = s.string }
        else { return }

        state?.sendText(str)
    }

    func handleSetMarkedText(_ string: Any, selectedRange: NSRange) {
        if let s = string as? String {
            markedText = NSAttributedString(string: s)
        } else if let s = string as? NSAttributedString {
            markedText = s
        }
        markedNSRange = NSRange(location: 0, length: markedText?.length ?? 0)
        selectedNSRange = selectedRange
    }

    func handleUnmarkText() {
        markedText = nil
        markedNSRange = NSRange(location: NSNotFound, length: 0)
    }

    var hasMarkedText: Bool {
        markedText != nil && markedText!.length > 0
    }

    // MARK: - Selection

    func clearSelection() {
        selectionAnchor = nil
        selectionEnd = nil
    }

    /// Select all visible grid content.
    func selectAll() {
        guard let state = state else { return }
        selectionAnchor = (row: 0, col: 0)
        selectionEnd = (row: state.currentRows - 1, col: state.currentCols - 1)
    }

    func selectedText() -> String? {
        guard let state = state,
              let grid = state.fetchGrid(),
              let anchor = selectionAnchor,
              let end = selectionEnd
        else { return nil }

        let (r1, c1, r2, c2): (Int, Int, Int, Int)
        if anchor.row < end.row || (anchor.row == end.row && anchor.col <= end.col) {
            (r1, c1, r2, c2) = (anchor.row, anchor.col, end.row, end.col)
        } else {
            (r1, c1, r2, c2) = (end.row, end.col, anchor.row, anchor.col)
        }

        // Build cell lookup
        var cellMap: [Int: [Int: TerminalGrid.CellData]] = [:]
        for cell in grid.cells {
            if cellMap[cell.row] == nil { cellMap[cell.row] = [:] }
            cellMap[cell.row]![cell.col] = cell
        }

        var lines: [String] = []
        for row in r1...r2 {
            var lineChars: [Character] = []
            let cStart = (row == r1) ? c1 : 0
            let cEnd = (row == r2) ? c2 : (grid.cols - 1)
            for col in cStart...cEnd {
                if let cell = cellMap[row]?[col] {
                    lineChars.append(cell.char)
                } else {
                    lineChars.append(" ")
                }
            }
            let line = String(lineChars)
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    // MARK: - Input Region Cursor Movement (OSC 133)

    /// Move the shell cursor to the target cell by sending arrow key sequences.
    ///
    /// Delegates to MoonBit (SoT) which computes the delta from the current
    /// cursor position and generates the correct escape sequences, respecting
    /// application cursor key mode.
    func moveCursorToCell(row: Int, col: Int, state: TerminalState) {
        guard let seq = state.bridge.cursorMoveSequence(
            sessionId: state.sessionId, row: row, col: col
        ) else { return }
        state.sendText(seq)
    }

    // MARK: - Cursor rect for IME popup

    func firstRect(in view: NSView) -> NSRect {
        guard let state = state else { return .zero }
        let col: Int
        let row: Int
        if let grid = state.grid {
            col = grid.cursor.col
            row = grid.cursor.row
        } else {
            // GPU path: use lightweight cursor info
            col = state.cursorCol
            row = state.cursorRow
        }
        let x = CGFloat(col) * state.cellWidth
        let y = view.bounds.height - CGFloat(row + 1) * state.cellHeight
        let rect = CGRect(x: x, y: y, width: state.cellWidth, height: state.cellHeight)
        guard let window = view.window else { return rect }
        return window.convertToScreen(view.convert(rect, to: nil))
    }
}
