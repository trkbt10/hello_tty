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

    private func renderFrame() {
        guard gpuInitialized, let state = terminalState else { return }
        _ = state.bridge.renderFrame()
    }
}
