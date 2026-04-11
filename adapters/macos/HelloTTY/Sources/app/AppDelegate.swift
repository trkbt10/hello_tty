import Cocoa
import SwiftUI

/// Application delegate managing the terminal lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    /// Accessible from NSView subclasses where NSApp.delegate is obscured by SwiftUI's adapter.
    static weak var shared: AppDelegate?

    let tabManager = TabManager()
    /// Injected by test scenarios to observe drag events. No-op in production.
    var tabDragEventObserver: TabDragEventObserver = NoOpTabDragEventObserver.shared
    /// Injected by test scenarios that need direct view access. Nil in production.
    var tabInteractionViewRegistry: TabInteractionViewRegistry?
    private(set) var lastTabDragOutcome: TabDragDropOutcome = .none
    private var detachedWindows: [Int32: NSWindow] = [:]
    private var reusableDetachedWindows: [NSWindow] = []
    private var titlebarAccessories: [ObjectIdentifier: TitlebarAccessoryHostingController] = [:]
    private var localTabDragMonitor: Any?
    private var globalTabDragMonitor: Any?
    private var pendingTabPress: (tabId: Int32, startPoint: CGPoint)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSLog("hello_tty: application launched")

        if MoonBitBridge.shared.isLoaded {
            NSLog("hello_tty: MoonBit bridge loaded successfully")
        } else {
            NSLog("hello_tty: WARNING — MoonBit bridge not loaded, running in demo mode")
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Configure windows for behind-window blur.
        DispatchQueue.main.async { [self] in
            for window in NSApp.windows {
                configure(
                    window: window,
                    workspaceId: self.tabManager.primaryWindowContext.workspaceId,
                    isPrimary: true,
                    windowContext: self.tabManager.primaryWindowContext
                )
            }

            // Test harness entry points — runners are responsible for their own argument parsing.
            if let runner = TabDragDropScenarioRunner.makeIfRequested(appDelegate: self, tabManager: self.tabManager) {
                runner.run()
                return
            }

            if CommandLine.arguments.contains("--self-test") {
                SelfTestRunner(tabManager: self.tabManager).run()
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// Intercept window close to handle Cmd+W gracefully.
    /// If there are still tabs with panels, close the focused panel instead
    /// of closing the entire window. Window only closes when no tabs remain.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let workspaceId = workspaceId(for: sender) ?? tabManager.primaryWindowContext.workspaceId
        guard let workspaceId else {
            return true
        }
        if tabManager.tabs(in: workspaceId).isEmpty {
            return true
        }
        tabManager.closeFocusedPanel(in: workspaceId)
        syncWorkspaceWindows()
        return tabManager.tabs(in: workspaceId).isEmpty
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let workspaceId = workspaceId(for: window) else { return }
        tabManager.activateWorkspace(workspaceId)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopObservingTabDrag()
        for window in detachedWindows.values {
            window.delegate = nil
            window.close()
        }
        for window in reusableDetachedWindows {
            window.delegate = nil
            window.close()
        }
        tabManager.closeAll()
        NSLog("hello_tty: application terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func beginObservingTabDrag() {
        if localTabDragMonitor != nil || globalTabDragMonitor != nil {
            return
        }
        localTabDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleObservedTabDragEvent(event)
            return event
        }
        globalTabDragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleObservedTabDragEvent(event)
        }
    }

    func completeObservedTabDrag(screenPoint: CGPoint? = nil) {
        guard tabManager.tabDragState != nil else {
            pendingTabPress = nil
            stopObservingTabDrag()
            return
        }
        let resolvedPoint = screenPoint ?? NSEvent.mouseLocation
        let outcome = tabManager.finishTabDrag(screenPoint: resolvedPoint)
        lastTabDragOutcome = outcome
        handleTabDragOutcome(outcome, screenPoint: resolvedPoint)
        pendingTabPress = nil
        stopObservingTabDrag()
    }

    func cancelObservedTabDrag() {
        tabManager.cancelTabDrag()
        pendingTabPress = nil
        stopObservingTabDrag()
    }

    func beginObservedTabDrag(tabId: Int32, screenPoint: CGPoint) {
        lastTabDragOutcome = .none
        beginObservingTabDrag()
        tabDragEventObserver.recordDragStart(tabId: tabId)
        tabManager.beginTabDrag(tabId: tabId)
        tabManager.updateTabDrag(screenPoint: screenPoint)
    }

    func updateObservedTabDrag(screenPoint: CGPoint) {
        guard tabManager.tabDragState != nil else { return }
        tabManager.updateTabDrag(screenPoint: screenPoint)
    }

    func showDetachedWindow(for workspaceId: Int32, near screenPoint: CGPoint? = nil) {
        if let window = detachedWindows[workspaceId] {
            if let screenPoint {
                position(window: window, near: screenPoint)
            }
            window.makeKeyAndOrderFront(nil)
            tabManager.activateWorkspace(workspaceId)
                return
        }

        let context = WorkspaceWindowContext(workspaceId: workspaceId)
        let contentView = MainWindowView(windowContext: context)
            .environmentObject(tabManager)
        let hosting = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        // Set an explicit initial size so SwiftUI has a non-zero frame to lay out into.
        window.setContentSize(NSSize(width: 720, height: 480))
        configure(window: window, workspaceId: workspaceId, isPrimary: false, windowContext: context)
        detachedWindows[workspaceId] = window
        if let screenPoint {
            position(window: window, near: screenPoint)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        tabManager.activateWorkspace(workspaceId)
    }

    func syncWorkspaceWindows() {
        let liveWorkspaceIds = Set(tabManager.workspaces.map(\.workspaceId))
        let staleWorkspaceIds = detachedWindows.keys.filter { !liveWorkspaceIds.contains($0) }
        for workspaceId in staleWorkspaceIds {
            guard let window = detachedWindows[workspaceId] else { continue }
            detachedWindows.removeValue(forKey: workspaceId)
            window.delegate = nil
            window.orderOut(nil)
            window.contentViewController = nil
            reusableDetachedWindows.append(window)
        }
    }

    private func configure(
        window: NSWindow,
        workspaceId: Int32?,
        isPrimary: Bool,
        windowContext: WorkspaceWindowContext
    ) {
        let theme = self.tabManager.theme
        window.appearance = theme.appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.delegate = self
        installTitlebarAccessory(on: window, windowContext: windowContext)
        if let workspaceId {
            window.identifier = NSUserInterfaceItemIdentifier("workspace-\(workspaceId)")
            if !isPrimary {
                detachedWindows[workspaceId] = window
            }
        } else if isPrimary {
            window.identifier = NSUserInterfaceItemIdentifier("workspace-primary")
        }
    }

    private func workspaceId(for window: NSWindow) -> Int32? {
        guard let raw = window.identifier?.rawValue else { return nil }
        if raw == "workspace-primary" {
            return tabManager.primaryWindowContext.workspaceId
        }
        guard raw.hasPrefix("workspace-") else { return nil }
        return Int32(String(raw.dropFirst("workspace-".count)))
    }

    private func handleObservedTabDragEvent(_ event: NSEvent) {
        // NSEvent monitor callbacks run on the main thread during Cocoa event
        // dispatch. Process synchronously to avoid 1-frame delay between mouse
        // movement and hover state update, which causes highlight flicker.
        guard tabManager.tabDragState != nil else { return }
        let point = screenPoint(for: event)
        switch event.type {
        case .leftMouseDragged:
            tabManager.updateTabDrag(screenPoint: point)
        case .leftMouseUp:
            completeObservedTabDrag(screenPoint: point)
        default:
            break
        }
    }

    private func handleTabDragOutcome(_ outcome: TabDragDropOutcome, screenPoint: CGPoint) {
        switch outcome {
        case .none:
            break
        case .detached(let workspaceId):
            showDetachedWindow(for: workspaceId, near: screenPoint)
            syncWorkspaceWindows()
        case .reordered, .attached, .merged:
            syncWorkspaceWindows()
        }
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        event.cgEvent?.location ?? NSEvent.mouseLocation
    }

    private func stopObservingTabDrag() {
        if let monitor = localTabDragMonitor {
            NSEvent.removeMonitor(monitor)
            localTabDragMonitor = nil
        }
        if let monitor = globalTabDragMonitor {
            NSEvent.removeMonitor(monitor)
            globalTabDragMonitor = nil
        }
        pendingTabPress = nil
    }

    private func position(window: NSWindow, near screenPoint: CGPoint) {
        let size = window.frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - size.width
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - size.height
        let origin = CGPoint(
            x: min(max(screenPoint.x - (size.width / 2), minX), maxX),
            y: min(max(screenPoint.y - (size.height / 2), minY), maxY)
        )
        window.setFrameOrigin(origin)
    }

    private func installTitlebarAccessory(on window: NSWindow, windowContext: WorkspaceWindowContext) {
        let key = ObjectIdentifier(window)
        let rootView = AnyView(
            TitlebarTabStripView(windowContext: windowContext)
                .environmentObject(tabManager)
        )

        if let accessory = titlebarAccessories[key] {
            accessory.update(rootView: rootView)
            return
        }

        let accessory = TitlebarAccessoryHostingController(
            rootView: rootView,
            tabBarHeight: tabManager.uiConfig.tabBarHeight
        )
        titlebarAccessories[key] = accessory
        window.addTitlebarAccessoryViewController(accessory)
    }
}

final class TitlebarAccessoryHostingController: NSTitlebarAccessoryViewController {
    private let hostingView: NonMovableHostingView<AnyView>

    init(rootView: AnyView, tabBarHeight: CGFloat = 42) {
        self.hostingView = NonMovableHostingView(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        self.layoutAttribute = .top
        self.fullScreenMinHeight = tabBarHeight
        self.view = hostingView
        self.view.translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(rootView: AnyView) {
        hostingView.rootView = rootView
    }
}

final class NonMovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
