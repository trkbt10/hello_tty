import AppKit

/// Base class for NSView subclasses that need to track their screen frame.
///
/// Subclasses implement `reportFrame()` to receive the converted frame.
/// This base class installs the `layout`, `setFrameSize`, and `setFrameOrigin`
/// overrides that call `reportFrame()` on every geometry change — avoiding
/// identical boilerplate in every frame-tracking view.
class FrameReportingNSView: NSView {
    /// Called whenever the view's screen-space frame may have changed.
    /// Subclasses override this to act on the new frame.
    func reportFrame() {}

    override func layout() {
        super.layout()
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

    /// Compute the view's bounds converted to screen coordinates.
    /// Returns nil if the view has no window yet.
    func screenFrame() -> CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
