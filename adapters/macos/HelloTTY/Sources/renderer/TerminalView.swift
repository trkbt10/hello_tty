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
    var tabManager: TabManager?

    func makeNSView(context: Context) -> NSView {
        let view: TerminalBaseView
        if MoonBitBridge.shared.hasGPU {
            view = TerminalGPUView()
        } else {
            view = TerminalNSView()
        }
        view.tabManager = tabManager
        view.terminalState = state
        state.terminalView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let baseView = nsView as? TerminalBaseView else { return }
        let stateChanged = baseView.terminalState !== state
        baseView.tabManager = tabManager
        baseView.terminalState = state
        state.terminalView = baseView
        // If the state changed (different panel), rebind the existing GPU
        // surface to the new session — no surface destruction needed.
        if stateChanged, let gpuView = baseView as? TerminalGPUView {
            gpuView.rebindSurface()
        }
    }
}

// MARK: - TerminalState

/// Terminal state coordinator — thin layer bridging domain objects to SwiftUI.
///
/// Domain objects:
///   - PtyConnection: PTY I/O loop, read/write, fd ownership
///   - TerminalGridCache: grid fetch/cache/differential-update, cursor
///
/// TerminalState itself only handles:
///   - SwiftUI @Published properties (title)
///   - Font metrics (cell size for layout calculations)
///   - View notification (refresh → needsDisplay / setNeedsRender)
///   - Coordinating between PTY output and grid updates
class TerminalState: ObservableObject {
    @Published var title: String = "hello_tty"

    let bridge = MoonBitBridge.shared
    let theme: TerminalTheme
    let sessionId: Int32

    /// PTY connection — owns the fd and I/O loop.
    let pty = PtyConnection()

    /// Grid cache — owns the grid data and differential update logic.
    let gridCache: TerminalGridCache

    /// Cell metrics — SoT is MoonBit's FontEngine (via getCellMetrics).
    /// Initial values are fallbacks until GPU init provides real metrics.
    /// These represent the cell size in logical points (not pixels).
    /// The GPU renderer uses these same values * dpi_scale for pixel rendering.
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var dpiScale: CGFloat = 2.0
    /// Font for CPU fallback rendering (TerminalNSView).
    /// Sized to match MoonBit's cell metrics.
    var font: NSFont

    /// Attached view (GPU or CPU) — notified on state changes.
    /// When nil, state changes are buffered (pendingRefresh) so the next
    /// view attachment triggers an immediate render.
    weak var terminalView: TerminalBaseView? {
        didSet {
            if terminalView != nil && pendingRefresh {
                pendingRefresh = false
                notifyView()
            }
        }
    }

    /// Whether a refresh happened while no view was attached.
    private var pendingRefresh = false

    /// PTY master fd — delegated to PtyConnection.
    var masterFd: Int32 { pty.masterFd }

    /// Current grid dimensions.
    var currentRows: Int { gridCache.rows }
    var currentCols: Int { gridCache.cols }

    // Backward-compatible accessors for code that reads these directly
    var cursorRow: Int { gridCache.cursorRow }
    var cursorCol: Int { gridCache.cursorCol }
    var grid: TerminalGrid? { gridCache.grid }
    var gridDirty: Bool {
        get { gridCache.dirty }
        set { gridCache.dirty = newValue }
    }

    init(theme: TerminalTheme = .fallback, sessionId: Int32 = -1) {
        self.theme = theme
        self.sessionId = sessionId
        self.gridCache = TerminalGridCache(sessionId: sessionId)

        // Fetch cell metrics from MoonBit (SoT).
        // getCellMetrics ensures GPU init, so font engine is initialized.
        // The metrics are in pixel space; divide by dpiScale for logical points.
        if let metrics = MoonBitBridge.shared.getCellMetrics() {
            let dpi = metrics.dpiScale > 0 ? metrics.dpiScale : 2.0
            self.cellWidth = metrics.cellWidth / dpi
            self.cellHeight = metrics.cellHeight / dpi
            self.dpiScale = dpi
        }

        // CPU fallback font — font size comes from MoonBit (SoT).
        if let metrics = MoonBitBridge.shared.getCellMetrics() {
            let dpi = metrics.dpiScale > 0 ? metrics.dpiScale : 2.0
            font = NSFont.monospacedSystemFont(
                ofSize: metrics.fontSize / dpi, weight: .regular)
        } else {
            font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        // Wire PTY output → session processing → grid refresh
        pty.onOutput = { [weak self] str in
            guard let self = self else { return }
            if self.sessionId >= 0 {
                _ = self.bridge.processOutputFor(sessionId: self.sessionId, data: str)
            } else {
                _ = self.bridge.processOutput(str)
            }
            self.refresh()
        }
    }

    func startPtyLoop(masterFd: Int32) {
        pty.start(masterFd: masterFd)
    }

    func stopPtyLoop() {
        pty.stop()
    }

    func sendKey(keyCode: Int, modifiers: Int) {
        guard pty.isConnected else { return }
        let escapeSeq: String?
        if sessionId >= 0 {
            escapeSeq = bridge.handleKeyFor(sessionId: sessionId,
                                            keyCode: keyCode, modifiers: modifiers)
        } else {
            escapeSeq = bridge.handleKey(keyCode: keyCode, modifiers: modifiers)
        }
        guard let seq = escapeSeq, !seq.isEmpty else { return }
        pty.writeEscapeSequence(seq)
    }

    func sendText(_ text: String) {
        guard pty.isConnected else { return }
        pty.writeText(text)
    }

    /// Refresh after PTY output. Lightweight: cursor only, grid is lazy.
    func refresh() {
        title = bridge.getTitle()
        gridCache.refreshCursor()
        gridCache.markDirty()
        if terminalView != nil {
            notifyView()
        } else {
            pendingRefresh = true
        }
    }

    private func notifyView() {
        if let gpuView = terminalView as? TerminalGPUView {
            gpuView.setNeedsRender()
        } else {
            terminalView?.needsDisplay = true
        }
    }

    func fetchGrid() -> TerminalGrid? {
        gridCache.fetch()
    }

    func forceRefreshGrid() -> TerminalGrid? {
        gridCache.forceRefresh()
    }

    /// Legacy resize for single-panel mode (when TabManager is not available).
    /// In multi-panel mode, resizing is handled by PanelSplitView's container
    /// GeometryReader → TabManager.applyLayoutResize() (MoonBit SoT).
    func resize(rows: Int, cols: Int) {
        guard rows != currentRows || cols != currentCols else { return }
        gridCache.updateDimensions(rows: rows, cols: cols)
        if sessionId >= 0 {
            _ = bridge.resizeSession(sessionId: sessionId, rows: rows, cols: cols)
        } else {
            _ = bridge.resize(rows: rows, cols: cols)
        }
        if pty.isConnected {
            bridge.ptyResize(masterFd: pty.masterFd, rows: rows, cols: cols)
        }
        refresh()
    }

    /// Legacy resize using pixel dimensions.
    /// MoonBit converts pixels → grid cells using its own cell metrics (SoT).
    func resizePx(widthPx: Int, heightPx: Int) {
        // Use MoonBit's layout resize which handles pixel→grid conversion
        let panelDims = bridge.resizeLayoutPx(widthPx: widthPx, heightPx: heightPx)
        // In legacy mode there's only one panel — apply the first result
        if let dim = panelDims.first {
            gridCache.updateDimensions(rows: dim.rows, cols: dim.cols)
            if pty.isConnected {
                bridge.ptyResize(masterFd: pty.masterFd, rows: dim.rows, cols: dim.cols)
            }
            refresh()
        }
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

    // MARK: - Resize
    // Layout resize is driven by PanelSplitView (container), not individual panel views.
    // setBoundsSize no longer triggers notifyLayoutResize.

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
