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
            (AppDelegate.shared)?.unregisterTabInteractionView(for: oldTabId, view: nsView)
            (AppDelegate.shared)?.registerTabInteractionView(nsView, for: tabId)
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

    private var mouseDownScreenPoint: CGPoint?
    private var didDragBeyondClickThreshold = false
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
        (AppDelegate.shared)?.recordDebugTabMouseDown()
        mouseDownScreenPoint = screenPoint(for: event)
        didDragBeyondClickThreshold = false
    }

    override func mouseDragged(with event: NSEvent) {
        (AppDelegate.shared)?.recordDebugTabMouseDragged()
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
        (AppDelegate.shared)?.recordDebugTabMouseUp()
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

    /// Shared drag logic used by both the live pan gesture recognizer and the test-only
    /// simulateDragForTesting path. Keeping one implementation ensures tests exercise the
    /// same code that runs during real user interaction.
    private func applyDragPhase(_ state: NSGestureRecognizer.State, screenPoint: CGPoint) {
        let appDelegate = AppDelegate.shared
        switch state {
        case .began:
            appDelegate?.recordDebugTabPanBegan()
            let start = mouseDownScreenPoint ?? screenPoint
            didDragBeyondClickThreshold = true
            appDelegate?.beginObservedTabDrag(tabId: tabId, screenPoint: start)
            appDelegate?.updateObservedTabDrag(screenPoint: screenPoint)
        case .changed:
            appDelegate?.recordDebugTabPanChanged()
            if didDragBeyondClickThreshold {
                appDelegate?.updateObservedTabDrag(screenPoint: screenPoint)
            }
        case .ended:
            appDelegate?.recordDebugTabPanEnded()
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

    /// Directly exercise the drag state machine without going through the system event tap.
    /// Use this only from test scenarios — never from production code.
    func simulateDragForTesting(from startScreen: CGPoint, to endScreen: CGPoint, steps: Int = 12, completion: @escaping () -> Void) {
        let appDelegate = AppDelegate.shared
        appDelegate?.recordDebugTabMouseDown()
        mouseDownScreenPoint = startScreen
        didDragBeyondClickThreshold = false

        applyDragPhase(.began, screenPoint: startScreen)

        var interpolated: [CGPoint] = []
        for step in 1...max(steps, 1) {
            let t = CGFloat(step) / CGFloat(max(steps, 1))
            interpolated.append(CGPoint(
                x: startScreen.x + (endScreen.x - startScreen.x) * t,
                y: startScreen.y + (endScreen.y - startScreen.y) * t
            ))
        }

        func sendNext(index: Int) {
            guard index < interpolated.count else {
                appDelegate?.recordDebugTabMouseDragged()
                applyDragPhase(.ended, screenPoint: endScreen)
                appDelegate?.recordDebugTabMouseUp()
                completion()
                return
            }
            applyDragPhase(.changed, screenPoint: interpolated[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                sendNext(index: index + 1)
            }
        }

        sendNext(index: 0)
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            AppDelegate.shared?.registerTabInteractionView(self, for: tabId)
        } else {
            AppDelegate.shared?.unregisterTabInteractionView(for: tabId, view: self)
        }
        reportFrame()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            (AppDelegate.shared)?.unregisterTabInteractionView(for: tabId, view: self)
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
