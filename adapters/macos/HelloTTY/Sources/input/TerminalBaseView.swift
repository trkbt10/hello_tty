import AppKit

/// Base NSView for terminal rendering — owns all input/IME/selection logic.
///
/// NSTextInputClient must be conformed by the NSView itself (macOS requirement).
/// This base class implements it once, delegating to InputHandler.
/// Subclasses only override rendering and resize behavior.
///
/// Subclasses:
///   - TerminalGPUView: CAMetalLayer + CVDisplayLink + bridge.renderFrame()
///   - TerminalNSView: CoreText CPU fallback with draw(_:)
class TerminalBaseView: NSView, NSTextInputClient {
    var terminalState: TerminalState? {
        didSet {
            if let s = terminalState { input = InputHandler(state: s) }
        }
    }

    private(set) var input: InputHandler?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: - Resize (subclasses must call recalculateGridSize)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGridSize()
    }

    func recalculateGridSize() {
        guard let state = terminalState else { return }
        let newCols = max(1, Int(bounds.width / state.cellWidth))
        let newRows = max(1, Int(bounds.height / state.cellHeight))
        state.resize(rows: newRows, cols: newCols)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let input = input else { return }
        input.currentEvent = event
        if !input.handleKeyDown(event) {
            inputContext?.handleEvent(event)
        }
        input.currentEvent = nil
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        input?.handleInsertText(string)
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        input?.handleSetMarkedText(string, selectedRange: selectedRange)
        needsDisplay = true
    }

    func unmarkText() {
        input?.handleUnmarkText()
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        input?.selectedNSRange ?? NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        input?.markedNSRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        input?.hasMarkedText ?? false
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor]
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        input?.firstRect(in: self) ?? .zero
    }

    override func doCommand(by selector: Selector) {
        input?.handleDoCommand(input?.currentEvent)
    }

    // MARK: - Mouse (selection)

    override func mouseDown(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        let row = max(0, Int((bounds.height - p.y) / state.cellHeight))
        let col = max(0, Int(p.x / state.cellWidth))
        input.selectionAnchor = (row, col)
        input.selectionEnd = (row, col)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        let row = max(0, Int((bounds.height - p.y) / state.cellHeight))
        let col = max(0, Int(p.x / state.cellWidth))
        input.selectionEnd = (row, col)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let input = input else { return }
        if let a = input.selectionAnchor, let e = input.selectionEnd,
           a.row == e.row && a.col == e.col {
            input.clearSelection()
        }
        needsDisplay = true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copyAction), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(pasteAction), keyEquivalent: "v"))
        return menu
    }

    @objc private func copyAction() {
        if let text = input?.selectedText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func pasteAction() {
        if let text = NSPasteboard.general.string(forType: .string) {
            terminalState?.sendText(text)
        }
    }
}
