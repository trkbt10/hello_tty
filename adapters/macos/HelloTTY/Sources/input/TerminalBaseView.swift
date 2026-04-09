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
            if let s = terminalState {
                input = InputHandler(state: s)
                input?.tabManager = tabManager
                input?.workspaceId = workspaceId
                searchController = TerminalSearchController(state: s, inputHandler: input!)
                input?.onFindRequested = { [weak self] in
                    self?.showSearchBar()
                }
            }
        }
    }

    /// TabManager reference for panel/tab keybinding operations.
    /// Set by the view hierarchy (TerminalView's NSViewRepresentable coordinator).
    weak var tabManager: TabManager? {
        didSet { input?.tabManager = tabManager }
    }

    var workspaceId: Int32? {
        didSet { input?.workspaceId = workspaceId }
    }

    private(set) var input: InputHandler?
    private(set) var searchController: TerminalSearchController?
    private var searchBarView: SearchBarView?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: - Resize
    //
    // MoonBit LayoutManager is the SoT for all panel grid dimensions.
    // Swift does NOT compute grid sizes — it sends the total available
    // pixel dimensions to MoonBit, which distributes space via the layout
    // tree and resizes each session's terminal grid.

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // In multi-panel mode, layout resize is driven by the container
        // (PanelSplitView) which knows the total available space.
        // Individual panel views must NOT call resizeLayout with their own
        // partial bounds — that would shrink all panels to one panel's size.
        //
        // In legacy single-panel mode (no TabManager), this view IS the
        // only view, so its bounds ARE the total — safe to resize directly.
        if tabManager == nil, let state = terminalState {
            state.resizePx(widthPx: Int(bounds.width), heightPx: Int(bounds.height))
        }
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

    // MARK: - Scroll (viewport)

    override func scrollWheel(with event: NSEvent) {
        guard let state = terminalState else { return }
        let delta = Int(event.scrollingDeltaY * 3.0)
        if delta > 0 {
            _ = state.bridge.scrollViewportUp(sessionId: state.sessionId, lines: delta)
        } else if delta < 0 {
            _ = state.bridge.scrollViewportDown(sessionId: state.sessionId, lines: -delta)
        }
        // Trigger re-render
        if let gpuView = self as? TerminalGPUView {
            gpuView.setNeedsRender()
        } else {
            needsDisplay = true
        }
    }

    // MARK: - Mouse (selection + input region click-to-move)

    /// Track whether the current mouse gesture is a click-to-move-cursor
    /// within the shell input region (OSC 133).
    private var isInputRegionClick = false

    override func mouseDown(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cell = state.bridge.pixelToGrid(
            xPx: Int(p.x), yPx: Int(p.y), viewHeightPx: Int(bounds.height))

        // Check if click is within the shell input region (MoonBit SoT)
        if state.bridge.isInInputRegion(
            sessionId: state.sessionId, row: cell.row, col: cell.col
        ) {
            isInputRegionClick = true
            input.moveCursorToCell(row: cell.row, col: cell.col, state: state)
            return
        }

        // Normal selection behavior
        isInputRegionClick = false
        input.selectionAnchor = (cell.row, cell.col)
        input.selectionEnd = (cell.row, cell.col)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }

        let p = convert(event.locationInWindow, from: nil)
        let cell = state.bridge.pixelToGrid(
            xPx: Int(p.x), yPx: Int(p.y), viewHeightPx: Int(bounds.height))

        if isInputRegionClick {
            // Drag within input region: move cursor to follow the drag
            if state.bridge.isInInputRegion(
                sessionId: state.sessionId, row: cell.row, col: cell.col
            ) {
                input.moveCursorToCell(row: cell.row, col: cell.col, state: state)
            }
            return
        }

        // Normal drag selection
        input.selectionEnd = (cell.row, cell.col)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let input = input else { return }

        if isInputRegionClick {
            isInputRegionClick = false
            return
        }

        if let a = input.selectionAnchor, let e = input.selectionEnd,
           a.row == e.row && a.col == e.col {
            input.clearSelection()
        }
        needsDisplay = true
    }

    // MARK: - Search Bar

    func showSearchBar() {
        guard let sc = searchController else { return }

        if let existing = searchBarView {
            existing.activate()
            return
        }

        sc.isActive = true

        let bar = SearchBarView(frame: .zero)
        bar.searchController = sc
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onClose = { [weak self] in
            self?.hideSearchBar()
        }
        addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 32),
            bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])

        searchBarView = bar

        // Delay first responder change slightly to avoid interfering with current event
        DispatchQueue.main.async {
            bar.activate()
        }
    }

    func hideSearchBar() {
        searchBarView?.removeFromSuperview()
        searchBarView = nil
        searchController?.close()
        // Return focus to terminal
        window?.makeFirstResponder(self)
        // Trigger redraw to clear selection highlights
        if let gpuView = self as? TerminalGPUView {
            gpuView.setNeedsRender()
        } else {
            needsDisplay = true
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copyAction), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(pasteAction), keyEquivalent: "v"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(selectAllAction), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Find…", action: #selector(findAction), keyEquivalent: "f"))
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

    @objc private func selectAllAction() {
        input?.selectAll()
        if let gpuView = self as? TerminalGPUView {
            gpuView.setNeedsRender()
        } else {
            needsDisplay = true
        }
    }

    @objc private func findAction() {
        showSearchBar()
    }
}
