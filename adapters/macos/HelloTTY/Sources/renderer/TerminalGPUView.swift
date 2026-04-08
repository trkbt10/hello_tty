import AppKit
import QuartzCore

/// GPU-accelerated terminal rendering view using wgpu (Metal backend on macOS).
///
/// Responsibilities (rendering only):
///   1. Provide a CAMetalLayer surface to wgpu
///   2. Drive the frame loop (CVDisplayLink -> bridge.renderFrame())
///   3. Handle GPU-specific resize (drawableSize + bridge resize)
///
/// Input, IME, selection, context menu — all inherited from TerminalBaseView.
class TerminalGPUView: TerminalBaseView {
    private var metalLayer: CAMetalLayer?
    private var gpuInitialized = false
    private var displayLink: CVDisplayLink?

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

    // MARK: - Resize (GPU-specific + base grid recalc)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let state = terminalState, gpuInitialized else { return }
        let scale = metalLayer?.contentsScale ?? 2.0
        let pw = Int(bounds.width * scale)
        let ph = Int(bounds.height * scale)
        guard pw > 0 && ph > 0 else { return }
        metalLayer?.drawableSize = CGSize(width: pw, height: ph)
        state.bridge.gpuResizeBridge(width: pw, height: ph)
    }

    // MARK: - Rendering

    /// Dirty flag: set when terminal state changes, cleared after render.
    private var needsRender = true

    private func renderFrame() {
        guard gpuInitialized, let state = terminalState else { return }
        // Only re-render when terminal state has changed
        guard needsRender else { return }
        needsRender = false
        _ = state.bridge.renderFrame()
        // Draw IME composition overlay if needed (CoreGraphics on top of Metal)
        DispatchQueue.main.async { [weak self] in
            self?.updateIMEOverlay()
        }
    }

    /// Mark that the terminal state changed and needs re-rendering.
    func setNeedsRender() {
        needsRender = true
    }

    // MARK: - IME Composition Overlay

    private var imeOverlayLayer: CALayer?

    private func updateIMEOverlay() {
        guard let input = input,
              let marked = input.markedText,
              marked.length > 0,
              let state = terminalState
        else {
            imeOverlayLayer?.removeFromSuperlayer()
            imeOverlayLayer = nil
            return
        }

        let cellW = state.cellWidth
        let cellH = state.cellHeight
        let scale = metalLayer?.contentsScale ?? 2.0

        // Cursor position — use lightweight cursor info (no grid JSON needed)
        let cursorX = CGFloat(state.cursorCol) * cellW
        let cursorY = bounds.height - CGFloat(state.cursorRow + 1) * cellH

        // Measure composition text
        let font = state.font
        let compositionAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: state.theme.foreground,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: state.theme.cursor,
        ]
        let compositionStr = NSAttributedString(string: marked.string, attributes: compositionAttrs)
        let compositionSize = compositionStr.size()

        // Create or reuse overlay layer
        let overlay: CALayer
        if let existing = imeOverlayLayer {
            overlay = existing
        } else {
            overlay = CALayer()
            overlay.zPosition = 100
            self.layer?.addSublayer(overlay)
            imeOverlayLayer = overlay
        }

        let layerRect = CGRect(x: cursorX, y: cursorY,
                               width: compositionSize.width + 4, height: cellH)
        overlay.frame = layerRect
        overlay.contentsScale = scale

        // Render composition text into the layer
        let imgSize = CGSize(width: layerRect.width * scale, height: layerRect.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(imgSize.width),
                                  height: Int(imgSize.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }

        ctx.scaleBy(x: scale, y: scale)
        // Background
        ctx.setFillColor(state.theme.background.withAlphaComponent(0.95).cgColor)
        ctx.fill(CGRect(origin: .zero, size: layerRect.size))
        // Text
        let line = CTLineCreateWithAttributedString(compositionStr)
        ctx.textPosition = CGPoint(x: 2, y: font.descender.magnitude)
        CTLineDraw(line, ctx)

        if let image = ctx.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.contents = image
            CATransaction.commit()
        }
    }

    // MARK: - Input events trigger re-render

    override func keyDown(with event: NSEvent) {
        needsRender = true
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        needsRender = true
        super.insertText(string, replacementRange: replacementRange)
        // Clear IME overlay after text insertion
        imeOverlayLayer?.removeFromSuperlayer()
        imeOverlayLayer = nil
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        needsRender = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updateIMEOverlay()
    }

    override func unmarkText() {
        super.unmarkText()
        imeOverlayLayer?.removeFromSuperlayer()
        imeOverlayLayer = nil
    }
}
