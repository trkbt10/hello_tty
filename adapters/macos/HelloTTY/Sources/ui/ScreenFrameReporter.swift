import AppKit
import SwiftUI

/// Reports the view's bounds converted into screen coordinates.
struct ScreenFrameReporter: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onFrameChange = onFrameChange
        DispatchQueue.main.async {
            nsView.reportFrame()
        }
    }
}

final class ReportingView: NSView {
    var onFrameChange: ((CGRect?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportFrame()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reportFrame()
    }

    func reportFrame() {
        guard let onFrameChange else { return }
        guard let window else {
            onFrameChange(nil)
            return
        }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        onFrameChange(frame)
    }
}
