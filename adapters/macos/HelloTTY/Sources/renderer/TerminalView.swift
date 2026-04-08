import SwiftUI
import AppKit

// MARK: - Behind-Window Blur (NSVisualEffectView wrapper)

/// Wraps `NSVisualEffectView` for use in SwiftUI.
///
/// This is the ONLY way to get behind-window blur on macOS.
/// The window compositor's Gaussian blur is driven exclusively by
/// `NSVisualEffectView` with `blendingMode = .behindWindow`.
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
        let view: TerminalBaseView
        if MoonBitBridge.shared.hasGPU {
            view = TerminalGPUView()
        } else {
            view = TerminalNSView()
        }
        view.terminalState = state
        state.terminalView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let baseView = nsView as? TerminalBaseView else { return }
        baseView.terminalState = state
        state.terminalView = baseView
    }
}

// MARK: - TerminalState

/// Terminal state — bridges MoonBit core + PTY session to SwiftUI.
class TerminalState: ObservableObject {
    @Published var title: String = "hello_tty"

    /// Grid is fetched on-demand by the renderer, not eagerly on every refresh.
    /// CPU renderer calls `fetchGrid()` in its `draw()`.
    /// GPU renderer never needs it (MoonBit renders directly via wgpu).
    var grid: TerminalGrid?

    let bridge = MoonBitBridge.shared
    let theme: TerminalTheme

    /// Cell metrics computed from the font via CoreText for pixel-perfect rendering.
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var font: NSFont

    private var masterFd: Int32 = -1
    private var ptyThread: Thread?
    private var running = false

    /// Current grid dimensions (tracked to avoid duplicate resize calls).
    private(set) var currentRows: Int = 24
    private(set) var currentCols: Int = 80

    init(theme: TerminalTheme = .fallback) {
        self.theme = theme
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

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

    /// Start the PTY I/O read loop with an already-spawned master_fd.
    /// The PTY was spawned by MoonBit (SessionManager) — Swift only drives I/O.
    func startPtyLoop(masterFd: Int32) {
        self.masterFd = masterFd
        running = true
        NSLog("hello_tty: PTY loop started, master_fd=%d", masterFd)

        ptyThread = Thread {
            self.ptyReadLoop()
        }
        ptyThread?.name = "hello_tty.pty_reader"
        ptyThread?.start()
    }

    /// Stop the PTY I/O loop.
    func stopPtyLoop() {
        running = false
        if masterFd >= 0 {
            // PTY fd is owned by MoonBit Session — don't close here.
            // MoonBit's destroy_session handles cleanup.
            masterFd = -1
        }
    }

    /// Whether a main-thread refresh is already scheduled.
    private var refreshPending = false

    /// Background PTY read loop.
    /// IMPORTANT: MoonBit's GC is NOT thread-safe. Only pure-C functions
    /// (ptyPoll, ptyRead) may be called from this background thread.
    /// Batches rapid consecutive reads into a single main-thread dispatch.
    private func ptyReadLoop() {
        let fd = masterFd
        while running {
            let pollResult = bridge.ptyPoll(masterFd: fd, timeoutMs: 16)
            if pollResult > 0 {
                // Drain all available data before dispatching
                var accumulated = Data()
                while true {
                    guard let data = bridge.ptyRead(masterFd: fd) else {
                        running = false
                        break
                    }
                    accumulated.append(data)
                    // Check if more data is immediately available
                    let moreResult = bridge.ptyPoll(masterFd: fd, timeoutMs: 0)
                    if moreResult <= 0 { break }
                }
                if !running { break }
                if accumulated.isEmpty { continue }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.running else { return }
                    if let str = String(data: accumulated, encoding: .utf8) {
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

    /// Attached view (GPU or CPU) — notified on state changes.
    weak var terminalView: TerminalBaseView?

    /// Cursor position — always kept up to date via lightweight FFI.
    var cursorRow: Int = 0
    var cursorCol: Int = 0

    /// Whether the grid data is stale (CPU renderer should refetch on next draw).
    var gridDirty: Bool = false

    /// Refresh terminal state after PTY output.
    /// Only fetches cursor position (lightweight). Grid is fetched lazily
    /// by the renderer when it actually draws.
    func refresh() {
        title = bridge.getTitle()
        if let cursor = bridge.getCursor() {
            cursorRow = cursor.row
            cursorCol = cursor.col
        }
        gridDirty = true
        if let gpuView = terminalView as? TerminalGPUView {
            gpuView.setNeedsRender()
        } else {
            terminalView?.needsDisplay = true
        }
    }

    /// Fetch the grid with differential updates.
    /// On partial updates, merges new cells into the existing grid.
    /// On full updates or first fetch, replaces the grid entirely.
    func fetchGrid() -> TerminalGrid? {
        if gridDirty {
            if let newGrid = bridge.getGrid() {
                switch newGrid.dirty {
                case .none:
                    // Nothing changed — keep existing grid, just update cursor
                    if var existing = grid {
                        existing = TerminalGrid(
                            rows: existing.rows, cols: existing.cols,
                            cursor: newGrid.cursor, cells: existing.cells)
                        grid = existing
                    }

                case .all:
                    // Full update — replace entirely
                    grid = newGrid

                case .rect(let top, let left, let bottom, let right):
                    if var existing = grid,
                       existing.rows == newGrid.rows && existing.cols == newGrid.cols {
                        // Remove old cells in the dirty rect
                        var kept = existing.cells.filter { cell in
                            !(cell.row >= top && cell.row <= bottom &&
                              cell.col >= left && cell.col <= right)
                        }
                        // Add new cells from the dirty rect
                        kept.append(contentsOf: newGrid.cells)
                        grid = TerminalGrid(
                            rows: existing.rows, cols: existing.cols,
                            cursor: newGrid.cursor, cells: kept)
                    } else {
                        // Grid size changed — can't merge, treat as full
                        grid = newGrid
                    }
                }
            }
            gridDirty = false
        }
        return grid
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
}

// MARK: - TerminalNSView (CPU fallback renderer)

/// CoreText CPU fallback renderer.
/// Input handling inherited from TerminalBaseView.
/// Only adds: cursor blink timer, CoreText drawing, selection highlight.
class TerminalNSView: TerminalBaseView {
    private var cursorVisible = true
    private var cursorTimer: Timer?

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

    // MARK: - Resize (also recalculates grid via base class)

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        recalculateGridSize()
    }

    // MARK: - Selection helpers

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

        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(bounds)

        guard let grid = state.fetchGrid() else { return }

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
            let cursorX = CGFloat(state.cursorCol) * cellW
            let cursorY = bounds.height - CGFloat(state.cursorRow + 1) * cellH
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
        if let marked = input?.markedText, marked.length > 0 {
            let cursorX = CGFloat(state.cursorCol) * cellW
            let cursorY = bounds.height - CGFloat(state.cursorRow + 1) * cellH

            let compositionAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.foreground,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.cursor,
            ]
            let compositionStr = NSAttributedString(string: marked.string, attributes: compositionAttrs)

            let compositionSize = compositionStr.size()
            let compositionRect = CGRect(x: cursorX, y: cursorY, width: compositionSize.width, height: cellH)
            ctx.setFillColor(theme.background.withAlphaComponent(0.95).cgColor)
            ctx.fill(compositionRect)

            let compositionLine = CTLineCreateWithAttributedString(compositionStr)
            ctx.textPosition = CGPoint(x: cursorX, y: cursorY + font.descender.magnitude)
            CTLineDraw(compositionLine, ctx)
        }
    }
}
