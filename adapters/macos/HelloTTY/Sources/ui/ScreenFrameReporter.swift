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
        // Report frame synchronously. The previous async dispatch caused
        // a 1-frame delay in frame registration, creating a feedback loop
        // with DnD hover evaluation: render → async frame report → re-trigger
        // hover update → re-render → async frame report → flicker.
        nsView.reportFrame()
    }
}

final class ReportingView: FrameReportingNSView {
    var onFrameChange: ((CGRect?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func reportFrame() {
        guard let onFrameChange else { return }
        onFrameChange(screenFrame())
    }
}
