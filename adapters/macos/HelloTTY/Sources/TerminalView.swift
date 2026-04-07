import SwiftUI
import AppKit

// MARK: - Behind-Window Blur (NSVisualEffectView wrapper)

/// Wraps `NSVisualEffectView` for use in SwiftUI.
///
/// This is the ONLY way to get behind-window blur on macOS.
/// Setting `window.backgroundColor` to a semi-transparent color gives
/// transparency (see-through) but zero blur. The window compositor's
/// Gaussian blur is driven exclusively by `NSVisualEffectView` with
/// `blendingMode = .behindWindow`.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Terminal View (SwiftUI wrapper)

/// The main terminal rendering view (SwiftUI wrapper).
///
/// Chooses between GPU (wgpu/Metal) and CPU (CoreText) rendering based on
/// whether the wgpu GPU backend is available in the dylib.
struct TerminalView: NSViewRepresentable {
    @ObservedObject var state: TerminalState

    func makeNSView(context: Context) -> NSView {
        if MoonBitBridge.shared.hasGPU {
            let view = TerminalGPUView()
            view.terminalState = state
            return view
        } else {
            let view = TerminalNSView()
            view.terminalState = state
            return view
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let gpuView = nsView as? TerminalGPUView {
            gpuView.terminalState = state
        } else if let cpuView = nsView as? TerminalNSView {
            cpuView.terminalState = state
            cpuView.needsDisplay = true
        }
    }
}

// MARK: - TerminalState

/// Terminal state — bridges MoonBit core + PTY session to SwiftUI.
class TerminalState: ObservableObject {
    @Published var grid: TerminalGrid?
    @Published var title: String = "hello_tty"

    let bridge = MoonBitBridge.shared
    let theme: TerminalTheme

    /// Cell metrics computed from the font via CoreText for pixel-perfect rendering.
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var font: NSFont

    private var masterFd: Int32 = -1
    private var childPid: Int32 = 0
    private var ptyThread: Thread?
    private var running = false

    /// Current grid dimensions (tracked to avoid duplicate resize calls).
    private(set) var currentRows: Int = 24
    private(set) var currentCols: Int = 80

    init(theme: TerminalTheme = .midnight) {
        self.theme = theme
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Use CoreText glyph advance for precise cell width.
        let ctFont = font as CTFont
        var chars: [UniChar] = [UniChar(0x4D)] // 'M'
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, &advance, 1)
        cellWidth = advance.width > 0 ? advance.width : 8

        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        cellHeight = ceil(ascent + descent + leading)
    }

    func initialize(rows: Int = 24, cols: Int = 80) {
        currentRows = rows
        currentCols = cols
        _ = bridge.initialize(rows: rows, cols: cols)
    }

    /// Start the PTY session and the background read loop.
    /// Uses the current rows/cols (may have been updated by resize before start).
    func startShell(shell: String = "/bin/zsh") {
        let rows = currentRows
        let cols = currentCols
        guard let result = bridge.ptyStart(shell: shell, rows: rows, cols: cols) else {
            NSLog("hello_tty: failed to start PTY session")
            return
        }
        masterFd = result.masterFd
        childPid = result.pid
        running = true
        NSLog("hello_tty: PTY started, master_fd=%d pid=%d rows=%d cols=%d",
              masterFd, childPid, rows, cols)

        ptyThread = Thread {
            self.ptyReadLoop()
        }
        ptyThread?.name = "hello_tty.pty_reader"
        ptyThread?.start()
    }

    /// Background PTY read loop.
    ///
    /// IMPORTANT: MoonBit's GC is NOT thread-safe. Only pure-C functions
    /// (ptyPoll, ptyRead) may be called from this background thread.
    private func ptyReadLoop() {
        let fd = masterFd
        while running {
            let pollResult = bridge.ptyPoll(masterFd: fd, timeoutMs: 16)
            if pollResult > 0 {
                guard let data = bridge.ptyRead(masterFd: fd) else {
                    running = false
                    break
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.running else { return }
                    if let str = String(data: data, encoding: .utf8) {
                        _ = self.bridge.processOutput(str)
                        self.refresh()
                    }
                }
            } else if pollResult == -2 {
                running = false
                break
            }
        }
        NSLog("hello_tty: PTY read loop ended")
    }

    func sendKey(keyCode: Int, modifiers: Int) {
        guard masterFd >= 0 else { return }

        guard let escapeSeq = bridge.handleKey(keyCode: keyCode, modifiers: modifiers),
              !escapeSeq.isEmpty,
              let data = escapeSeq.data(using: .utf8)
        else { return }

        var bytes = [UInt8](data)
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A { bytes[i] = 0x0D }
        }
        _ = bridge.ptyWrite(masterFd: masterFd, data: Data(bytes))
    }

    func sendText(_ text: String) {
        guard masterFd >= 0, let data = text.data(using: .utf8) else { return }
        var bytes = [UInt8](data)
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A { bytes[i] = 0x0D }
        }
        _ = bridge.ptyWrite(masterFd: masterFd, data: Data(bytes))
    }

    func refresh() {
        grid = bridge.getGrid(theme: theme)
        title = bridge.getTitle()
    }

    func resize(rows: Int, cols: Int) {
        guard rows != currentRows || cols != currentCols else { return }
        currentRows = rows
        currentCols = cols
        _ = bridge.resize(rows: rows, cols: cols)
        if masterFd >= 0 {
            bridge.ptyResize(masterFd: masterFd, rows: rows, cols: cols)
        }
        refresh()
    }

    func shutdown() {
        running = false
        if masterFd >= 0 {
            bridge.ptyClose(masterFd: masterFd)
            masterFd = -1
        }
        bridge.shutdown()
    }
}

// MARK: - TerminalNSView

/// Custom NSView for terminal grid rendering (CoreText CPU fallback).
/// Input handling delegated to shared InputHandler.
class TerminalNSView: NSView, NSTextInputClient {
    var terminalState: TerminalState? {
        didSet {
            if let s = terminalState { input = InputHandler(state: s) }
        }
    }

    private var cursorVisible = true
    private var cursorTimer: Timer?
    private var input: InputHandler?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startCursorBlink()
    }

    override func removeFromSuperview() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        super.removeFromSuperview()
    }

    private func startCursorBlink() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cursorVisible.toggle()
            self.needsDisplay = true
        }
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGridSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        recalculateGridSize()
    }

    private func recalculateGridSize() {
        guard let state = terminalState else { return }
        let newCols = max(1, Int(bounds.width / state.cellWidth))
        let newRows = max(1, Int(bounds.height / state.cellHeight))
        state.resize(rows: newRows, cols: newCols)
    }

    // MARK: - Selection helpers (delegate to InputHandler)

    private func isCellSelected(row: Int, col: Int) -> Bool {
        guard let anchor = input?.selectionAnchor, let end = input?.selectionEnd else { return false }
        let (r1, c1, r2, c2): (Int, Int, Int, Int)
        if anchor.row < end.row || (anchor.row == end.row && anchor.col <= end.col) {
            (r1, c1, r2, c2) = (anchor.row, anchor.col, end.row, end.col)
        } else {
            (r1, c1, r2, c2) = (end.row, end.col, anchor.row, anchor.col)
        }
        if row < r1 || row > r2 { return false }
        if row == r1 && row == r2 { return col >= c1 && col <= c2 }
        if row == r1 { return col >= c1 }
        if row == r2 { return col <= c2 }
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let state = terminalState
        else { return }

        let theme = state.theme
        let cellW = state.cellWidth
        let cellH = state.cellHeight
        let font = state.font

        // Background tint overlay on top of NSVisualEffectView blur.
        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(bounds)

        guard let grid = state.grid else { return }

        // Build cell lookup map
        var cellMap: [Int: [Int: TerminalGrid.CellData]] = [:]
        for cell in grid.cells {
            if cellMap[cell.row] == nil { cellMap[cell.row] = [:] }
            cellMap[cell.row]![cell.col] = cell
        }

        for row in 0..<grid.rows {
            let y = bounds.height - CGFloat(row + 1) * cellH
            if y + cellH < dirtyRect.minY || y > dirtyRect.maxY { continue }

            for col in 0..<grid.cols {
                let x = CGFloat(col) * cellW
                if x + cellW < dirtyRect.minX || x > dirtyRect.maxX { continue }

                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                let selected = isCellSelected(row: row, col: col)

                if let cell = cellMap[row]?[col] {
                    // Cell background
                    if selected {
                        ctx.setFillColor(theme.selection.cgColor)
                        ctx.fill(rect)
                    } else if cell.bg != theme.background {
                        ctx.setFillColor(cell.bg.cgColor)
                        ctx.fill(rect)
                    }

                    let ch = cell.char
                    if ch != " " && ch != "\u{0}" {
                        let str = String(ch)
                        let cellFont: NSFont
                        if cell.isBold {
                            cellFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
                        } else {
                            cellFont = font
                        }

                        var fgColor = cell.fg
                        if cell.isDim {
                            fgColor = fgColor.withAlphaComponent(0.5)
                        }
                        if cell.isBold, let bc = theme.boldColor {
                            fgColor = bc
                        }

                        // Build attributes — only add underline/strikethrough when actually set
                        // to avoid NSAttributedString applying default underlines.
                        var attrs: [NSAttributedString.Key: Any] = [
                            .font: cellFont,
                            .foregroundColor: fgColor,
                        ]
                        if cell.isUnderline {
                            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        }
                        if cell.isStrikethrough {
                            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                        }

                        let attrStr = NSAttributedString(string: str, attributes: attrs)
                        let line = CTLineCreateWithAttributedString(attrStr)
                        ctx.textPosition = CGPoint(x: x, y: y + font.descender.magnitude)
                        CTLineDraw(line, ctx)
                    }
                } else if selected {
                    ctx.setFillColor(theme.selection.cgColor)
                    ctx.fill(rect)
                }
            }
        }

        // Cursor
        if grid.cursor.visible && cursorVisible {
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

            ctx.setFillColor(theme.cursor.cgColor)
            ctx.fill(cursorRect)
        }

        // IME marked text (composition preview)
        if let marked = input?.markedText, marked.length > 0,
           let grid = state.grid {
            let cursorX = CGFloat(grid.cursor.col) * cellW
            let cursorY = bounds.height - CGFloat(grid.cursor.row + 1) * cellH

            // Draw composition text with underline
            let compositionAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.foreground,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.cursor,
            ]
            let compositionStr = NSAttributedString(string: marked.string, attributes: compositionAttrs)

            // Background for composition
            let compositionSize = compositionStr.size()
            let compositionRect = CGRect(x: cursorX, y: cursorY, width: compositionSize.width, height: cellH)
            ctx.setFillColor(theme.background.withAlphaComponent(0.95).cgColor)
            ctx.fill(compositionRect)

            let compositionLine = CTLineCreateWithAttributedString(compositionStr)
            ctx.textPosition = CGPoint(x: cursorX, y: cursorY + font.descender.magnitude)
            CTLineDraw(compositionLine, ctx)
        }
    }

    // MARK: - Mouse (delegate to InputHandler)

    override func mouseDown(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        input.selectionAnchor = (max(0, Int((bounds.height - p.y) / state.cellHeight)),
                                  max(0, Int(p.x / state.cellWidth)))
        input.selectionEnd = input.selectionAnchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        input.selectionEnd = (max(0, Int((bounds.height - p.y) / state.cellHeight)),
                              max(0, Int(p.x / state.cellWidth)))
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

    // MARK: - Keyboard (delegate to InputHandler)

    override func keyDown(with event: NSEvent) {
        guard let input = input else { return }
        input.currentEvent = event
        if !input.handleKeyDown(event) {
            inputContext?.handleEvent(event)
        }
        input.currentEvent = nil
    }

    // MARK: - NSTextInputClient (delegate to InputHandler)

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

    func selectedRange() -> NSRange { input?.selectedNSRange ?? NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { input?.markedNSRange ?? NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { input?.hasMarkedText ?? false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.font, .foregroundColor] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        input?.firstRect(in: self) ?? .zero
    }

    override func doCommand(by selector: Selector) {
        input?.handleDoCommand(input?.currentEvent)
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
