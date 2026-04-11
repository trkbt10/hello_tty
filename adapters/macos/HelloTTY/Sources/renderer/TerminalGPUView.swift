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
    /// The GPU surface_id owned by this view. -1 if not created.
    private var surfaceId: Int32 = -1

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
        // Pre-fill with theme background so the layer never shows a bare black
        // frame during tab switch (between DisplayLink stop and first render).
        if let bg = terminalState?.theme.background {
            layer.backgroundColor = bg.cgColor
        }
        metalLayer = layer
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            metalLayer?.contentsScale = window.backingScaleFactor
            initGPUIfNeeded()
            startDisplayLink()
        } else {
            // View temporarily removed from window (tab switch, layout rebuild).
            // Stop rendering but do NOT destroy the surface — SwiftUI may
            // re-add this view shortly. Surface destruction is only done
            // in removeFromSuperview (permanent removal).
            stopDisplayLink()
        }
    }

    override func removeFromSuperview() {
        stopDisplayLink()
        destroySurface()
        super.removeFromSuperview()
    }

    // MARK: - GPU Init (per-panel surface)

    /// Destroy this view's GPU surface.
    /// Uses surfaceId (not sessionId) to avoid destroying a surface
    /// that was recreated by a newer view for the same session.
    private func destroySurface() {
        if surfaceId >= 0 {
            // Directly destroy the C-level surface by ID
            MoonBitBridge.shared.gpuSurfaceDestroyById(surfaceId: surfaceId)
            // Only remove from surface_map if our surfaceId still matches
            if let state = terminalState {
                state.bridge.gpuSurfaceUnregisterIfMatches(
                    sessionId: state.sessionId, expectedSurfaceId: surfaceId)
            }
            surfaceId = -1
        }
        gpuInitialized = false
    }

    /// Create or recreate the GPU surface for this view's CAMetalLayer.
    /// Called on first appearance, when the view is re-added to the window,
    /// and when the terminalState changes (panel reassignment).
    private func initGPUIfNeeded() {
        guard let layer = metalLayer, let state = terminalState else { return }
        let scale = metalLayer?.contentsScale ?? 2.0
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard w > 0 && h > 0 else { return }

        // If already initialized for this session, just ensure render is triggered
        if gpuInitialized && surfaceId >= 0 {
            needsRender = true
            return
        }

        // Destroy any stale surface from a previous incarnation
        destroySurface()

        let layerPtr = Unmanaged.passUnretained(layer).toOpaque()

        if state.sessionId >= 0 {
            // gpuSurfaceCreate does two things:
            //   1. Creates wgpu surface via direct C FFI (uint64_t handle)
            //   2. Registers session→surface mapping in MoonBit bridge
            //      (also ensures renderer/font/atlas are initialized)
            let sid = state.bridge.gpuSurfaceCreate(
                sessionId: state.sessionId,
                metalLayer: layerPtr,
                width: w, height: h)
            if sid < 0 {
                NSLog("hello_tty: GPU surface creation failed for session %d", state.sessionId)
                return
            }
            surfaceId = sid
            gpuInitialized = true
            needsRender = true
            NSLog("hello_tty: GPU surface %d created for session %d (%dx%d)",
                  sid, state.sessionId, w, h)
        } else {
            guard state.bridge.gpuInitDirect(metalLayer: layerPtr, width: w, height: h) else {
                NSLog("hello_tty: GPU direct init failed")
                return
            }
            guard state.bridge.gpuInitBridge(surfaceHandle: 0, width: w, height: h) else {
                NSLog("hello_tty: GPU bridge init failed")
                return
            }
            gpuInitialized = true
            needsRender = true
            NSLog("hello_tty: GPU rendering initialized (legacy) (%dx%d)", w, h)
        }
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

    // MARK: - Resize (GPU surface pixel resize only)
    //
    // Layout resize (grid rows/cols) is driven by PanelSplitView's container
    // GeometryReader → TabManager.applyLayoutResize(). This view only handles
    // the GPU surface's pixel dimensions (drawableSize + wgpu surface config).

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let state = terminalState, gpuInitialized else { return }
        let scale = metalLayer?.contentsScale ?? 2.0
        let pw = Int(bounds.width * scale)
        let ph = Int(bounds.height * scale)
        guard pw > 0 && ph > 0 else { return }
        metalLayer?.drawableSize = CGSize(width: pw, height: ph)
        if state.sessionId >= 0 {
            state.bridge.gpuSurfaceResize(sessionId: state.sessionId, width: pw, height: ph)
        } else {
            state.bridge.gpuResizeBridge(width: pw, height: ph)
        }
        needsRender = true
    }

    // MARK: - Rendering

    /// Dirty flag: set when terminal state changes, cleared after render.
    private var needsRender = true

    private func renderFrame() {
        guard gpuInitialized, let state = terminalState else { return }
        guard needsRender else { return }
        needsRender = false
        let result: Bool
        if state.sessionId >= 0 {
            result = state.bridge.renderFrameFor(sessionId: state.sessionId)
        } else {
            result = state.bridge.renderFrame()
        }
        if !result {
            NSLog("hello_tty: renderFrame FAILED for session %d, surfaceId %d", state.sessionId, surfaceId)
        }
        // Draw overlays on top of Metal (selection highlight, IME composition)
        DispatchQueue.main.async { [weak self] in
            self?.updateSelectionOverlay()
            self?.updateIMEOverlay()
        }
    }

    /// Rebind this view's existing GPU surface to a new session.
    /// Called when TerminalView.updateNSView detects that the TerminalState
    /// changed (e.g. tab switch, panel reassignment).
    ///
    /// Instead of destroying and recreating the wgpu surface (which causes
    /// a black flash), we keep the same CAMetalLayer surface and just update
    /// MoonBit's session→surface mapping. The next renderFrame will draw the
    /// new session's content into the existing surface.
    func rebindSurface() {
        guard let state = terminalState, surfaceId >= 0 else {
            // No existing surface — need full init
            initGPUIfNeeded()
            return
        }
        // Re-register: point the new session at our existing surface
        state.bridge.gpuRegisterSurface(sessionId: state.sessionId, surfaceId: surfaceId)
        needsRender = true
    }

    /// Mark that the terminal state changed and needs re-rendering.
    func setNeedsRender() {
        needsRender = true
    }

    // MARK: - Selection Overlay

    private var selectionOverlayLayer: CALayer?

    private func updateSelectionOverlay() {
        guard let input = input,
              let anchor = input.selectionAnchor,
              let end = input.selectionEnd,
              let state = terminalState
        else {
            selectionOverlayLayer?.removeFromSuperlayer()
            selectionOverlayLayer = nil
            return
        }

        let cellW = state.cellWidth
        let cellH = state.cellHeight

        // Normalize selection direction
        let (r1, c1, r2, c2): (Int, Int, Int, Int)
        if anchor.row < end.row || (anchor.row == end.row && anchor.col <= end.col) {
            (r1, c1, r2, c2) = (anchor.row, anchor.col, end.row, end.col)
        } else {
            (r1, c1, r2, c2) = (end.row, end.col, anchor.row, anchor.col)
        }

        let overlay: CALayer
        if let existing = selectionOverlayLayer {
            overlay = existing
            // Remove old sublayers
            overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        } else {
            overlay = CALayer()
            overlay.zPosition = 50
            self.layer?.addSublayer(overlay)
            selectionOverlayLayer = overlay
        }

        overlay.frame = bounds

        // Selection color from theme (semi-transparent blue)
        let selColor = state.theme.selection

        // Draw selection rectangles for each row
        for row in r1...r2 {
            let cStart: Int
            let cEnd: Int
            if row == r1 && row == r2 {
                cStart = c1; cEnd = c2
            } else if row == r1 {
                cStart = c1; cEnd = state.currentCols - 1
            } else if row == r2 {
                cStart = 0; cEnd = c2
            } else {
                cStart = 0; cEnd = state.currentCols - 1
            }

            let x = CGFloat(cStart) * cellW
            let y = bounds.height - CGFloat(row + 1) * cellH
            let w = CGFloat(cEnd - cStart + 1) * cellW

            let rect = CALayer()
            rect.frame = CGRect(x: x, y: y, width: w, height: cellH)
            rect.backgroundColor = selColor.cgColor
            overlay.addSublayer(rect)
        }
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

    // MARK: - Mouse events trigger selection overlay update

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        needsRender = true
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        updateSelectionOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        updateSelectionOverlay()
    }
}
