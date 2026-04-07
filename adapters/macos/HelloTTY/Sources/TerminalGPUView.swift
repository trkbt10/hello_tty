import AppKit
import QuartzCore

/// GPU-accelerated terminal rendering view using wgpu (Metal backend on macOS).
///
/// This view's responsibilities are minimal:
///   1. Provide a CAMetalLayer surface to wgpu
///   2. Drive the frame loop (CVDisplayLink → bridge.renderFrame())
///   3. Forward raw NSEvents to the shared InputHandler
///   4. Forward mouse events for text selection
///
/// All rendering logic runs in MoonBit. All input logic lives in InputHandler.
class TerminalGPUView: NSView, NSTextInputClient {
    var terminalState: TerminalState? {
        didSet {
            if let s = terminalState {
                input = InputHandler(state: s)
            }
        }
    }

    private var metalLayer: CAMetalLayer?
    private var gpuInitialized = false
    private var displayLink: CVDisplayLink?
    private var input: InputHandler?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer = layer
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            metalLayer?.contentsScale = window.backingScaleFactor
        }
        initGPUIfNeeded()
        startDisplayLink()
    }

    override func removeFromSuperview() {
        stopDisplayLink()
        super.removeFromSuperview()
    }

    // MARK: - GPU Init

    private func initGPUIfNeeded() {
        guard !gpuInitialized, let layer = metalLayer, let state = terminalState else { return }
        let scale = metalLayer?.contentsScale ?? 2.0
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard w > 0 && h > 0 else { return }

        let layerPtr = Unmanaged.passUnretained(layer).toOpaque()
        guard state.bridge.gpuInitDirect(metalLayer: layerPtr, width: w, height: h) else {
            NSLog("hello_tty: GPU direct init failed")
            return
        }
        guard state.bridge.gpuInitBridge(surfaceHandle: 0, width: w, height: h) else {
            NSLog("hello_tty: GPU bridge init failed")
            return
        }
        gpuInitialized = true
        NSLog("hello_tty: GPU rendering initialized (%dx%d)", w, h)
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        CVDisplayLinkSetOutputHandler(dl) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async { self?.renderFrame() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(dl)
    }

    private func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
            displayLink = nil
        }
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let state = terminalState, gpuInitialized else { return }
        let scale = metalLayer?.contentsScale ?? 2.0
        let pw = Int(bounds.width * scale)
        let ph = Int(bounds.height * scale)
        guard pw > 0 && ph > 0 else { return }
        metalLayer?.drawableSize = CGSize(width: pw, height: ph)
        state.bridge.gpuResizeBridge(width: pw, height: ph)
        let newCols = max(1, Int(bounds.width / state.cellWidth))
        let newRows = max(1, Int(bounds.height / state.cellHeight))
        state.resize(rows: newRows, cols: newCols)
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard gpuInitialized, let state = terminalState else { return }
        _ = state.bridge.renderFrame()
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

    // MARK: - NSTextInputClient (thin delegation to InputHandler)

    func insertText(_ string: Any, replacementRange: NSRange) {
        input?.handleInsertText(string)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        input?.handleSetMarkedText(string, selectedRange: selectedRange)
        needsDisplay = true
    }

    func unmarkText() {
        input?.handleUnmarkText()
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
        // Called by IME for non-text keys (Enter, Backspace, arrows, etc.)
        input?.handleDoCommand(input?.currentEvent)
    }

    // MARK: - Mouse (delegate selection to InputHandler)

    override func mouseDown(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        let row = max(0, Int((bounds.height - p.y) / state.cellHeight))
        let col = max(0, Int(p.x / state.cellWidth))
        input.selectionAnchor = (row, col)
        input.selectionEnd = (row, col)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let input = input, let state = terminalState else { return }
        let p = convert(event.locationInWindow, from: nil)
        let row = max(0, Int((bounds.height - p.y) / state.cellHeight))
        let col = max(0, Int(p.x / state.cellWidth))
        input.selectionEnd = (row, col)
    }

    override func mouseUp(with event: NSEvent) {
        guard let input = input else { return }
        if let a = input.selectionAnchor, let e = input.selectionEnd,
           a.row == e.row && a.col == e.col {
            input.clearSelection()
        }
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
