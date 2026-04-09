import CoreGraphics

/// Observer for tab drag lifecycle events injected into TabMouseInteractionView.
/// The production default is `NoOpTabDragEventObserver`; test scenarios
/// supply their own implementation via AppDelegate.tabDragEventObserver.
protocol TabDragEventObserver: AnyObject {
    func tabMouseDown()
    func tabMouseDragged()
    func tabMouseUp()
    func tabPanBegan()
    func tabPanChanged()
    func tabPanEnded()
}

/// No-op implementation used in production.
final class NoOpTabDragEventObserver: TabDragEventObserver {
    static let shared = NoOpTabDragEventObserver()
    func tabMouseDown() {}
    func tabMouseDragged() {}
    func tabMouseUp() {}
    func tabPanBegan() {}
    func tabPanChanged() {}
    func tabPanEnded() {}
}
