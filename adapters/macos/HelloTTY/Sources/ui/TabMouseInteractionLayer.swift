import AppKit
import SwiftUI

struct TabMouseInteractionLayer: NSViewRepresentable {
    let tabId: Int32
    let onClick: () -> Void
    let onFrameChange: (CGRect?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick, onFrameChange: onFrameChange)
    }

    func makeNSView(context: Context) -> TabMouseInteractionView {
        let view = TabMouseInteractionView()
        view.coordinator = context.coordinator
        view.tabId = tabId
        return view
    }

    func updateNSView(_ nsView: TabMouseInteractionView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.onFrameChange = onFrameChange
        nsView.coordinator = context.coordinator
        let oldTabId = nsView.tabId
        nsView.tabId = tabId
        if oldTabId != tabId, nsView.window != nil {
            let registry = AppDelegate.shared?.tabInteractionViewRegistry
            registry?.unregister(for: oldTabId, view: nsView)
            registry?.register(nsView, for: tabId)
        }
        DispatchQueue.main.async {
            nsView.reportFrame()
        }
    }

    final class Coordinator {
        var onClick: () -> Void
        var onFrameChange: (CGRect?) -> Void

        init(onClick: @escaping () -> Void, onFrameChange: @escaping (CGRect?) -> Void) {
            self.onClick = onClick
            self.onFrameChange = onFrameChange
        }
    }
}

final class TabMouseInteractionView: NSView {
    weak var coordinator: TabMouseInteractionLayer.Coordinator?
    var tabId: Int32 = -1

    var mouseDownScreenPoint: CGPoint?
    var didDragBeyondClickThreshold = false
    private lazy var panRecognizer: NSPanGestureRecognizer = {
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        recognizer.buttonMask = 0x1
        return recognizer
    }()

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if !gestureRecognizers.contains(panRecognizer) {
            addGestureRecognizer(panRecognizer)
        }
    }

    override func mouseDown(with event: NSEvent) {
        AppDelegate.shared?.tabDragEventObserver.tabMouseDown()
        mouseDownScreenPoint = screenPoint(for: event)
        didDragBeyondClickThreshold = false
    }

    override func mouseDragged(with event: NSEvent) {
        AppDelegate.shared?.tabDragEventObserver.tabMouseDragged()
        guard let start = mouseDownScreenPoint else { return }
        let point = screenPoint(for: event)
        if hypot(point.x - start.x, point.y - start.y) >= 4 {
            didDragBeyondClickThreshold = true
        }
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        event.cgEvent?.location ?? window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? .zero
    }

    override func mouseUp(with event: NSEvent) {
        AppDelegate.shared?.tabDragEventObserver.tabMouseUp()
        if !didDragBeyondClickThreshold {
            coordinator?.onClick()
        }
        mouseDownScreenPoint = nil
        didDragBeyondClickThreshold = false
    }

    @objc
    private func handlePanGesture(_ recognizer: NSPanGestureRecognizer) {
        let pointInWindow = recognizer.location(in: nil)
        let screenPoint = window?.convertToScreen(NSRect(origin: pointInWindow, size: .zero)).origin ?? .zero
        applyDragPhase(recognizer.state, screenPoint: screenPoint)
    }

    func applyDragPhase(_ state: NSGestureRecognizer.State, screenPoint: CGPoint) {
        let appDelegate = AppDelegate.shared
        switch state {
        case .began:
            appDelegate?.tabDragEventObserver.tabPanBegan()
            let start = mouseDownScreenPoint ?? screenPoint
            didDragBeyondClickThreshold = true
            appDelegate?.beginObservedTabDrag(tabId: tabId, screenPoint: start)
            appDelegate?.updateObservedTabDrag(screenPoint: screenPoint)
        case .changed:
            appDelegate?.tabDragEventObserver.tabPanChanged()
            if didDragBeyondClickThreshold {
                appDelegate?.updateObservedTabDrag(screenPoint: screenPoint)
            }
        case .ended:
            appDelegate?.tabDragEventObserver.tabPanEnded()
            if didDragBeyondClickThreshold {
                appDelegate?.completeObservedTabDrag(screenPoint: screenPoint)
            }
            mouseDownScreenPoint = nil
            didDragBeyondClickThreshold = false
        case .cancelled, .failed:
            if didDragBeyondClickThreshold {
                appDelegate?.cancelObservedTabDrag()
            }
            mouseDownScreenPoint = nil
            didDragBeyondClickThreshold = false
        default:
            break
        }
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let registry = AppDelegate.shared?.tabInteractionViewRegistry
        if window != nil {
            registry?.register(self, for: tabId)
        } else {
            registry?.unregister(for: tabId, view: self)
        }
        reportFrame()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            AppDelegate.shared?.tabInteractionViewRegistry?.unregister(for: tabId, view: self)
        }
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
        guard let coordinator else { return }
        guard let window else {
            coordinator.onFrameChange(nil)
            return
        }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        coordinator.onFrameChange(frame)
    }
}
