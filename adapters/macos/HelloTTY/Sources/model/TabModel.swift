import Foundation
import SwiftUI
import Combine

/// Represents a single terminal panel within a tab.
///
/// Each panel maps 1:1 to a MoonBit Session (independent PTY, grid, parser).
/// The panel owns a TerminalState which drives the PTY I/O loop.
final class TerminalPanel: Identifiable, ObservableObject {
    let panelId: Int32
    let sessionId: Int32
    @Published var isFocused: Bool = false
    let state: TerminalState

    init(panelId: Int32, sessionId: Int32, state: TerminalState) {
        self.panelId = panelId
        self.sessionId = sessionId
        self.state = state
    }

    var id: Int32 { panelId }
}

/// Represents a single terminal tab containing one or more panels.
///
/// The layout tree (split structure) is managed by MoonBit LayoutManager.
/// This is a thin Swift wrapper providing Combine/SwiftUI observability.
final class TerminalTab: Identifiable, ObservableObject {
    let tabId: Int32
    @Published var title: String = "Terminal"
    @Published var isActive: Bool = true
    @Published var panels: [TerminalPanel] = []

    private var titleSink: AnyCancellable?

    init(tabId: Int32) {
        self.tabId = tabId
    }

    var id: Int32 { tabId }

    func addPanel(_ panel: TerminalPanel) {
        panels.append(panel)
        if panel.isFocused {
            observeTitle(of: panel)
        }
    }

    func removePanel(panelId: Int32) {
        panels.removeAll(where: { $0.panelId == panelId })
    }

    func panel(forPanelId panelId: Int32) -> TerminalPanel? {
        panels.first(where: { $0.panelId == panelId })
    }

    func panel(forSessionId sessionId: Int32) -> TerminalPanel? {
        panels.first(where: { $0.sessionId == sessionId })
    }

    func setFocusedPanel(_ panelId: Int32) {
        for panel in panels {
            panel.isFocused = (panel.panelId == panelId)
        }
        if let focused = panel(forPanelId: panelId) {
            observeTitle(of: focused)
        }
    }

    private func observeTitle(of panel: TerminalPanel) {
        titleSink = panel.state.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self else { return }
                if !newTitle.isEmpty {
                    self.title = newTitle
                }
            }
    }

    var label: String {
        title.isEmpty ? "Terminal" : title
    }

    var state: TerminalState? {
        panels.first(where: { $0.isFocused })?.state ?? panels.first?.state
    }
}

/// One native macOS window workspace containing an ordered tab strip.
final class TerminalWorkspace: Identifiable, ObservableObject {
    let workspaceId: Int32
    @Published var orderedTabIds: [Int32] = []
    @Published var selectedTabId: Int32?
    @Published var isActive: Bool = false

    init(workspaceId: Int32) {
        self.workspaceId = workspaceId
    }

    var id: Int32 { workspaceId }
}

/// Shared coordinator between the root window and detached windows.
final class WorkspaceWindowContext: ObservableObject, Identifiable {
    let id = UUID()
    @Published var workspaceId: Int32?
    let isPrimary: Bool

    init(workspaceId: Int32? = nil, isPrimary: Bool = false) {
        self.workspaceId = workspaceId
        self.isPrimary = isPrimary
    }
}

enum TabDragHoverTarget: Equatable {
    /// Cursor is over the tab bar of a workspace. The insertion index is resolved
    /// dynamically from x position when needed — the UI does not compute it.
    case tabBar(workspaceId: Int32)
    /// Resolved insertion slot within a tab bar (computed from x position).
    case tabInsertion(workspaceId: Int32, index: Int)
    case workspaceContent(workspaceId: Int32)
    case panel(workspaceId: Int32, panelId: Int32)
}

struct TabDragState: Equatable {
    let tabId: Int32
    let sourceWorkspaceId: Int32
    var screenPoint: CGPoint
}

private struct RegisteredTabDropTarget {
    let id: String
    let target: TabDragHoverTarget
    var frame: CGRect
}

enum TabDragDropOutcome: Equatable {
    case none
    case reordered(workspaceId: Int32)
    case attached(workspaceId: Int32)
    case merged(workspaceId: Int32, panelId: Int32)
    case detached(newWorkspaceId: Int32)
}

/// Manages the collection of workspaces, tabs, and their panel runtimes.
///
/// MoonBit owns the durable structure:
///   - workspace membership
///   - tab ordering
///   - focused panel and layout tree
///
/// Swift owns only UI/runtime concerns:
///   - SwiftUI observability
///   - PTY I/O loop objects
///   - NSView first-responder coordination
final class TabManager: ObservableObject {
    @Published private(set) var workspaces: [TerminalWorkspace] = []
    @Published private(set) var activeWorkspaceId: Int32?
    @Published private(set) var tabDragState: TabDragState?
    /// Current hover target during tab drag. Separated from tabDragState so that
    /// frame registration can update hover silently without triggering the
    /// @Published notification on tabDragState (which would cause a feedback loop
    /// with ScreenFrameReporter re-registration during SwiftUI body evaluation).
    @Published private(set) var dragHoverTarget: TabDragHoverTarget?

    let bridge = MoonBitBridge.shared
    let theme: TerminalTheme
    /// UI config from MoonBit — computed corner radii, paddings, etc.
    /// Loaded once at init from bridge; updated on config reload.
    private(set) var uiConfig: MoonBitBridge.UIConfigInfo

    /// During divider drag, stores the pixel size of the first pane.
    /// Keyed by panelId (the firstLeafId of the split being dragged).
    /// LayoutNodeView uses this to bypass ratio-based frame calculation,
    /// avoiding the feedback loop between DragGesture and re-parsed ratio.
    var dividerDragFirstSize: [Int32: CGFloat] = [:]

    private var tabsById: [Int32: TerminalTab] = [:]
    private var workspaceSizes: [Int32: CGSize] = [:]
    private var dropTargets: [String: RegisteredTabDropTarget] = [:]
    private var tabFrames: [Int32: CGRect] = [:]
    /// tabBarFrames[workspaceId] = screen frame of the entire tab bar strip.
    private var tabBarFrames: [Int32: CGRect] = [:]
    private(set) var primaryWindowContext = WorkspaceWindowContext(isPrimary: true)

    init() {
        self.theme = TerminalTheme.fromBridge(MoonBitBridge.shared)
        let font = NSFont.systemFont(ofSize: 12)
        let fontLineHeight = font.ascender - font.descender + font.leading
        guard let ui = MoonBitBridge.shared.getUIConfig(fontLineHeight: CGFloat(fontLineHeight)) else {
            fatalError("hello_tty: failed to load UI config from MoonBit bridge — dylib not loaded")
        }
        self.uiConfig = ui
        _ = syncWorkspacesFromBridge()
    }

    var tabs: [TerminalTab] { tabs(in: activeWorkspaceId) }
    var selectedTabId: Int32? { workspace(for: activeWorkspaceId)?.selectedTabId }
    var selectedTab: TerminalTab? { selectedTab(in: activeWorkspaceId) }
    var focusedPanel: TerminalPanel? { focusedPanel(in: activeWorkspaceId) }

    func workspace(for workspaceId: Int32?) -> TerminalWorkspace? {
        guard let workspaceId else { return nil }
        return workspaces.first(where: { $0.workspaceId == workspaceId })
    }

    func tab(for tabId: Int32) -> TerminalTab? {
        tabsById[tabId]
    }

    func workspaceId(forTabId tabId: Int32) -> Int32? {
        workspaces.first(where: { $0.orderedTabIds.contains(tabId) })?.workspaceId
    }

    func registerDropTarget(id: String, target: TabDragHoverTarget, frame: CGRect) {
        let old = dropTargets[id]
        dropTargets[id] = RegisteredTabDropTarget(id: id, target: target, frame: frame)
        if tabDragState != nil, old?.frame != frame {
            recomputeHoverTarget()
        }
    }

    func unregisterDropTarget(id: String) {
        guard dropTargets.removeValue(forKey: id) != nil else { return }
        if tabDragState != nil {
            recomputeHoverTarget()
        }
    }

    func registerTabFrame(tabId: Int32, frame: CGRect) {
        tabFrames[tabId] = frame
    }

    func unregisterTabFrame(tabId: Int32) {
        tabFrames.removeValue(forKey: tabId)
    }

    func frameForTab(tabId: Int32) -> CGRect? {
        tabFrames[tabId]
    }

    func registerTabBarFrame(workspaceId: Int32, frame: CGRect) {
        let old = tabBarFrames[workspaceId]
        tabBarFrames[workspaceId] = frame
        if tabDragState != nil, old != frame {
            recomputeHoverTarget()
        }
    }

    func unregisterTabBarFrame(workspaceId: Int32) {
        tabBarFrames.removeValue(forKey: workspaceId)
    }

    /// Given a screen x coordinate within a workspace's tab bar, return the insertion
    /// index that cursor position maps to. Tabs are sorted left-to-right by their
    /// registered frame; the cursor x splits each tab at its midpoint.
    func tabInsertionIndex(workspaceId: Int32, screenX: CGFloat) -> Int {
        let orderedTabIds = workspace(for: workspaceId)?.orderedTabIds ?? []
        let framesInOrder: [(tabId: Int32, minX: CGFloat)] = orderedTabIds.compactMap { tabId in
            guard let frame = tabFrames[tabId] else { return nil }
            return (tabId, frame.minX)
        }.sorted { $0.minX < $1.minX }

        for (offset, entry) in framesInOrder.enumerated() {
            guard let frame = tabFrames[entry.tabId] else { continue }
            if screenX < frame.midX {
                return offset
            }
        }
        return framesInOrder.count
    }

    func frameForDropTarget(_ target: TabDragHoverTarget) -> CGRect? {
        switch target {
        case .tabBar(let workspaceId):
            return tabBarFrames[workspaceId]
        case .tabInsertion(let workspaceId, _):
            // tabInsertion is now resolved dynamically from the tab bar frame.
            // Return the tab bar frame so callers can find a valid drop destination.
            return tabBarFrames[workspaceId]
        default:
            return dropTargets.values.first(where: { $0.target == target })?.frame
        }
    }

    func tabId(at screenPoint: CGPoint) -> Int32? {
        let candidates = tabFrames.filter { $0.value.contains(screenPoint) }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            (lhs.value.width * lhs.value.height) < (rhs.value.width * rhs.value.height)
        }?.key
    }

    func beginTabDrag(tabId: Int32) {
        guard let sourceWorkspaceId = workspaceId(forTabId: tabId) else { return }
        tabDragState = TabDragState(
            tabId: tabId,
            sourceWorkspaceId: sourceWorkspaceId,
            screenPoint: NSEvent.mouseLocation
        )
        dragHoverTarget = nil
        updateTabDrag(screenPoint: NSEvent.mouseLocation)
    }

    func updateTabDrag(screenPoint: CGPoint) {
        guard var dragState = tabDragState else { return }
        dragState.screenPoint = screenPoint
        tabDragState = dragState
        // Update hover target separately. This is also @Published, but
        // the key difference is that frame registration methods below
        // call recomputeHoverTarget() which only writes to dragHoverTarget
        // (not tabDragState), preventing a full re-render cascade.
        dragHoverTarget = hoveredTarget(at: screenPoint)
    }

    /// Recompute hover target from current drag position and frame data.
    /// Called by registerDropTarget / registerTabBarFrame when frames change
    /// during a drag. Only updates dragHoverTarget, not tabDragState.
    private func recomputeHoverTarget() {
        guard let dragState = tabDragState else { return }
        let newTarget = hoveredTarget(at: dragState.screenPoint)
        if dragHoverTarget != newTarget {
            dragHoverTarget = newTarget
        }
    }

    func cancelTabDrag() {
        tabDragState = nil
        dragHoverTarget = nil
    }

    func finishTabDrag(screenPoint: CGPoint) -> TabDragDropOutcome {
        guard let dragState = tabDragState else { return .none }
        updateTabDrag(screenPoint: screenPoint)
        let resolvedState = tabDragState ?? dragState
        let resolvedTarget = dragHoverTarget
        defer {
            tabDragState = nil
            dragHoverTarget = nil
        }

        switch resolvedTarget {
        case .tabBar(let workspaceId):
            let index = tabInsertionIndex(workspaceId: workspaceId, screenX: resolvedState.screenPoint.x)
            let sourceWorkspaceId = resolvedState.sourceWorkspaceId
            if sourceWorkspaceId == workspaceId {
                reorderTab(tabId: resolvedState.tabId, in: workspaceId, to: index)
                return .reordered(workspaceId: workspaceId)
            }
            attachTab(tabId: resolvedState.tabId, to: workspaceId, targetIndex: index)
            return .attached(workspaceId: workspaceId)

        case .tabInsertion(let workspaceId, let index):
            let sourceWorkspaceId = resolvedState.sourceWorkspaceId
            if sourceWorkspaceId == workspaceId {
                reorderTab(tabId: resolvedState.tabId, in: workspaceId, to: index)
                return .reordered(workspaceId: workspaceId)
            }
            attachTab(tabId: resolvedState.tabId, to: workspaceId, targetIndex: index)
            return .attached(workspaceId: workspaceId)

        case .panel(let workspaceId, let panelId):
            let dir = panelDropEdge(workspaceId: workspaceId, panelId: panelId)?.direction ?? 0
            if dropTabOnPanel(
                tabId: resolvedState.tabId,
                to: workspaceId,
                targetPanelId: panelId,
                direction: dir
            ) {
                return .merged(workspaceId: workspaceId, panelId: panelId)
            }
            return .none

        case .workspaceContent(let workspaceId):
            guard let targetPanelId = focusedPanel(in: workspaceId)?.panelId
                ?? selectedTab(in: workspaceId)?.panels.first?.panelId
            else {
                return .none
            }
            let dir = panelDropEdge(workspaceId: workspaceId, panelId: targetPanelId)?.direction ?? 0
            if dropTabOnPanel(
                tabId: resolvedState.tabId,
                to: workspaceId,
                targetPanelId: targetPanelId,
                direction: dir
            ) {
                return .merged(workspaceId: workspaceId, panelId: targetPanelId)
            }
            return .none

        case .none:
            if shouldDetachDraggedTabOutsideWindows(resolvedState),
               let newWorkspaceId = detachTabToNewWindow(tabId: resolvedState.tabId) {
                return .detached(newWorkspaceId: newWorkspaceId)
            }
            return .none
        }
    }

    func isTabBeingDragged(_ tabId: Int32) -> Bool {
        tabDragState?.tabId == tabId
    }

    func isHoveringTabInsertion(workspaceId: Int32?, index: Int) -> Bool {
        guard let workspaceId, let dragState = tabDragState else { return false }
        switch dragHoverTarget {
        case .tabInsertion(let wid, let idx):
            return wid == workspaceId && idx == index
        case .tabBar(let wid) where wid == workspaceId:
            return tabInsertionIndex(workspaceId: workspaceId, screenX: dragState.screenPoint.x) == index
        default:
            return false
        }
    }

    func isHoveringPanel(workspaceId: Int32, panelId: Int32) -> Bool {
        let hoverTarget = dragHoverTarget
        if hoverTarget == .panel(workspaceId: workspaceId, panelId: panelId) {
            return true
        }
        if hoverTarget == .workspaceContent(workspaceId: workspaceId) {
            return focusedPanel(in: workspaceId)?.panelId == panelId
                || selectedTab(in: workspaceId)?.panels.first?.panelId == panelId
        }
        return false
    }

    /// Split direction when dropping a tab on a panel.
    /// Determined by which edge of the panel frame the cursor is nearest to.
    ///
    /// Returns: 0 = vertical (left/right), 1 = horizontal (top/bottom).
    /// The Bool indicates which half: false = first half (left or top),
    /// true = second half (right or bottom).
    func panelDropEdge(workspaceId: Int32, panelId: Int32) -> (direction: Int32, secondHalf: Bool)? {
        guard let dragState = tabDragState,
              isHoveringPanel(workspaceId: workspaceId, panelId: panelId) else {
            return nil
        }
        let targetId = "workspace-\(workspaceId)-panel-\(panelId)"
        guard let frame = dropTargets[targetId]?.frame else { return nil }

        let point = dragState.screenPoint
        // Normalized position within the panel (0..1)
        let nx = (point.x - frame.minX) / frame.width
        let ny = (point.y - frame.minY) / frame.height

        // Distance from each edge (0 = at edge, 0.5 = center)
        let distLeft = nx
        let distRight = 1 - nx
        let distBottom = ny          // macOS screen coords: y=0 at bottom
        let distTop = 1 - ny
        let minDist = min(distLeft, distRight, distBottom, distTop)

        if minDist == distLeft || minDist == distRight {
            // Horizontal distance is smallest → vertical split (left/right)
            return (direction: 0, secondHalf: nx > 0.5)
        } else {
            // Vertical distance is smallest → horizontal split (top/bottom)
            return (direction: 1, secondHalf: ny < 0.5)  // y inverted: smaller y = bottom of screen = bottom half
        }
    }

    func tabs(in workspaceId: Int32?) -> [TerminalTab] {
        guard let workspace = workspace(for: workspaceId) else { return [] }
        return workspace.orderedTabIds.compactMap { tabsById[$0] }
    }

    func selectedTab(in workspaceId: Int32?) -> TerminalTab? {
        guard let workspace = workspace(for: workspaceId) else { return nil }
        let tabId = workspace.selectedTabId ?? workspace.orderedTabIds.first
        guard let tabId else { return nil }
        return tabsById[tabId]
    }

    func focusedPanel(in workspaceId: Int32?) -> TerminalPanel? {
        selectedTab(in: workspaceId)?.panels.first(where: { $0.isFocused })
    }

    @discardableResult
    func newTab(in workspaceId: Int32? = nil, rows: Int = 24, cols: Int = 80) -> TerminalTab {
        if let workspaceId {
            _ = bridge.activateWorkspace(workspaceId: workspaceId)
        }
        guard let result = bridge.createTab(rows: rows, cols: cols) else {
            NSLog("hello_tty: failed to create tab")
            let tab = TerminalTab(tabId: -1)
            tabsById[tab.tabId] = tab
            return tab
        }

        let tab = tabsById[result.tabId] ?? TerminalTab(tabId: result.tabId)
        tabsById[result.tabId] = tab
        let state = TerminalState(theme: theme, sessionId: result.sessionId)
        let panel = TerminalPanel(
            panelId: result.panelId,
            sessionId: result.sessionId,
            state: state
        )
        panel.isFocused = true
        tab.addPanel(panel)

        if result.masterFd >= 0 {
            state.startPtyLoop(masterFd: result.masterFd)
        }

        _ = syncWorkspacesFromBridge()
        if let workspaceId = activeWorkspaceId {
            forceLayoutResize(for: workspaceId)
        }
        return tab
    }

    func closeTab(_ tab: TerminalTab, in workspaceId: Int32? = nil) {
        activateWorkspaceIfNeeded(workspaceId)
        for panel in tab.panels {
            panel.state.stopPtyLoop()
        }
        bridge.closeTab(id: tab.tabId)
        _ = syncWorkspacesFromBridge()
    }

    func selectTab(_ tab: TerminalTab, in workspaceId: Int32? = nil) {
        activateWorkspaceIfNeeded(workspaceId)
        _ = bridge.switchTab(id: tab.tabId)
        _ = syncWorkspacesFromBridge()
        if let workspaceId = workspaceId ?? activeWorkspaceId {
            forceLayoutResize(for: workspaceId)
        }
    }

    func activateWorkspace(_ workspaceId: Int32) {
        guard bridge.activateWorkspace(workspaceId: workspaceId) else { return }
        _ = syncWorkspacesFromBridge()
        forceLayoutResize(for: workspaceId)
    }

    func nextTab(in workspaceId: Int32? = nil) {
        activateWorkspaceIfNeeded(workspaceId)
        _ = bridge.nextTab()
        _ = syncWorkspacesFromBridge()
        if let workspaceId = workspaceId ?? activeWorkspaceId {
            forceLayoutResize(for: workspaceId)
        }
    }

    func prevTab(in workspaceId: Int32? = nil) {
        activateWorkspaceIfNeeded(workspaceId)
        _ = bridge.prevTab()
        _ = syncWorkspacesFromBridge()
        if let workspaceId = workspaceId ?? activeWorkspaceId {
            forceLayoutResize(for: workspaceId)
        }
    }

    func reorderTab(tabId: Int32, in workspaceId: Int32, to targetIndex: Int) {
        activateWorkspaceIfNeeded(workspaceId)
        guard bridge.reorderTab(tabId: tabId, targetIndex: targetIndex) else { return }
        _ = syncWorkspacesFromBridge()
    }

    @discardableResult
    func detachTabToNewWorkspace(tabId: Int32) -> Int32 {
        let workspaceId = bridge.detachTabToNewWorkspace(tabId: tabId)
        _ = syncWorkspacesFromBridge()
        return workspaceId
    }

    func canDetachTabToNewWindow(tabId: Int32) -> Bool {
        guard let workspaceId = workspaceId(forTabId: tabId) else { return false }
        return tabs(in: workspaceId).count > 1
    }

    @discardableResult
    func detachTabToNewWindow(tabId: Int32) -> Int32? {
        guard canDetachTabToNewWindow(tabId: tabId) else { return nil }
        let workspaceId = detachTabToNewWorkspace(tabId: tabId)
        return workspaceId >= 0 ? workspaceId : nil
    }

    func attachTab(tabId: Int32, to workspaceId: Int32, targetIndex: Int) {
        guard bridge.attachTabToWorkspace(
            tabId: tabId,
            workspaceId: workspaceId,
            targetIndex: targetIndex
        ) else { return }
        _ = syncWorkspacesFromBridge()
    }

    func dropTabOnPanel(
        tabId: Int32,
        to workspaceId: Int32,
        targetPanelId: Int32,
        direction: Int32 = 0
    ) -> Bool {
        guard let sourceTab = tabsById[tabId] else { return false }
        activateWorkspaceIfNeeded(workspaceId)
        guard let targetTab = selectedTab(in: workspaceId),
              targetTab.tabId != tabId else { return false }

        let movedPanels = sourceTab.panels
        let movedFocusedPanelId = movedPanels.first(where: { $0.isFocused })?.panelId ?? movedPanels.first?.panelId
        guard bridge.mergeTabIntoPanel(
            tabId: tabId,
            targetPanelId: targetPanelId,
            direction: direction
        ) else { return false }

        sourceTab.panels = []
        for panel in movedPanels {
            targetTab.addPanel(panel)
        }
        if let movedFocusedPanelId {
            targetTab.setFocusedPanel(movedFocusedPanelId)
        }

        _ = syncWorkspacesFromBridge()
        forceLayoutResize(for: workspaceId)
        makeFocusedPanelFirstResponder(in: workspaceId)
        return true
    }

    func splitFocusedPanel(in workspaceId: Int32, direction: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId),
              let focused = focusedPanel(in: workspaceId) else { return }

        guard let result = bridge.splitPanel(panelId: focused.panelId, direction: direction) else {
            NSLog("hello_tty: panel too small to split")
            return
        }

        let newState = TerminalState(theme: theme, sessionId: result.sessionId)
        let newPanel = TerminalPanel(
            panelId: result.panelId,
            sessionId: result.sessionId,
            state: newState
        )
        tab.addPanel(newPanel)

        if result.masterFd >= 0 {
            newState.startPtyLoop(masterFd: result.masterFd)
        }

        tab.setFocusedPanel(result.panelId)
        forceLayoutResize(for: workspaceId)
        objectWillChange.send()
        makeFocusedPanelFirstResponder(in: workspaceId)
    }

    func splitFocusedPanel(direction: Int32) {
        if let activeWorkspaceId {
            splitFocusedPanel(in: activeWorkspaceId, direction: direction)
        }
    }

    /// Detach a panel from its tab's split and create a new tab for it.
    /// The panel's PTY session is preserved.
    func detachPanelToTab(in workspaceId: Int32, panelId: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId),
              let panel = tab.panel(forPanelId: panelId) else { return }
        // Must have more than one panel to detach from
        guard tab.panels.count > 1 else { return }

        let newTabId = bridge.detachPanelToTab(panelId: panelId)
        guard newTabId >= 0 else { return }

        // Move the panel from the source tab to the new tab in Swift state
        tab.removePanel(panelId: panelId)
        let newTab = tabsById[newTabId] ?? TerminalTab(tabId: newTabId)
        tabsById[newTabId] = newTab
        newTab.addPanel(panel)
        panel.isFocused = true

        _ = syncWorkspacesFromBridge()
        forceLayoutResize(for: workspaceId)
        makeFocusedPanelFirstResponder(in: workspaceId)
    }

    func closeFocusedPanel(in workspaceId: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId),
              let focused = focusedPanel(in: workspaceId) else { return }

        if tab.panels.count <= 1 {
            closeTab(tab, in: workspaceId)
            return
        }

        focused.state.stopPtyLoop()
        let newFocusedSessionId = bridge.closePanel(panelId: focused.panelId)
        tab.removePanel(panelId: focused.panelId)

        if newFocusedSessionId >= 0, let newFocused = tab.panel(forSessionId: newFocusedSessionId) {
            tab.setFocusedPanel(newFocused.panelId)
        }

        forceLayoutResize(for: workspaceId)
        objectWillChange.send()
        makeFocusedPanelFirstResponder(in: workspaceId)
    }

    func closeFocusedPanel() {
        if let activeWorkspaceId {
            closeFocusedPanel(in: activeWorkspaceId)
        }
    }

    func focusPanel(in workspaceId: Int32, panelId: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId) else { return }
        if bridge.focusPanel(panelId: panelId) {
            tab.setFocusedPanel(panelId)
            objectWillChange.send()
        }
    }

    func focusPanel(panelId: Int32) {
        if let activeWorkspaceId {
            focusPanel(in: activeWorkspaceId, panelId: panelId)
        }
    }

    func focusPanelByIndex(in workspaceId: Int32, _ index: Int) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId) else { return }
        if bridge.focusPanelByIndex(Int32(index)) {
            let newFocusedId = bridge.getFocusedPanelId()
            if newFocusedId >= 0 {
                tab.setFocusedPanel(newFocusedId)
                objectWillChange.send()
            }
        }
    }

    func focusPanelByIndex(_ index: Int) {
        if let activeWorkspaceId {
            focusPanelByIndex(in: activeWorkspaceId, index)
        }
    }

    func focusDirection(in workspaceId: Int32, _ direction: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId) else { return }
        if bridge.focusDirection(direction) {
            let newFocusedId = bridge.getFocusedPanelId()
            if newFocusedId >= 0 {
                tab.setFocusedPanel(newFocusedId)
                makeFocusedPanelFirstResponder(in: workspaceId)
                objectWillChange.send()
            }
        }
    }

    func focusDirection(_ direction: Int32) {
        if let activeWorkspaceId {
            focusDirection(in: activeWorkspaceId, direction)
        }
    }

    func focusNextSplit(in workspaceId: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId) else { return }
        let panels = tab.panels
        guard panels.count > 1,
              let currentIdx = panels.firstIndex(where: { $0.isFocused }) else { return }
        let nextPanel = panels[(currentIdx + 1) % panels.count]
        if bridge.focusPanel(panelId: nextPanel.panelId) {
            tab.setFocusedPanel(nextPanel.panelId)
            makeFocusedPanelFirstResponder(in: workspaceId)
            objectWillChange.send()
        }
    }

    func focusNextSplit() {
        if let activeWorkspaceId {
            focusNextSplit(in: activeWorkspaceId)
        }
    }

    func focusPrevSplit(in workspaceId: Int32) {
        activateWorkspaceIfNeeded(workspaceId)
        guard let tab = selectedTab(in: workspaceId) else { return }
        let panels = tab.panels
        guard panels.count > 1,
              let currentIdx = panels.firstIndex(where: { $0.isFocused }) else { return }
        let prevPanel = panels[(currentIdx - 1 + panels.count) % panels.count]
        if bridge.focusPanel(panelId: prevPanel.panelId) {
            tab.setFocusedPanel(prevPanel.panelId)
            makeFocusedPanelFirstResponder(in: workspaceId)
            objectWillChange.send()
        }
    }

    func focusPrevSplit() {
        if let activeWorkspaceId {
            focusPrevSplit(in: activeWorkspaceId)
        }
    }

    func gotoTab(in workspaceId: Int32, _ index: Int) {
        let tabs = tabs(in: workspaceId)
        let targetTab: TerminalTab?
        if index == -1 {
            targetTab = tabs.last
        } else if index >= 0 && index < tabs.count {
            targetTab = tabs[index]
        } else {
            return
        }
        guard let tab = targetTab else { return }
        selectTab(tab, in: workspaceId)
    }

    func gotoTab(_ index: Int) {
        if let activeWorkspaceId {
            gotoTab(in: activeWorkspaceId, index)
        }
    }

    @discardableResult
    func applyLayoutResize(
        in workspaceId: Int32,
        totalWidth: CGFloat,
        totalHeight: CGFloat
    ) -> Bool {
        let currentSize = workspaceSizes[workspaceId] ?? .zero
        guard abs(totalWidth - currentSize.width) > 1 || abs(totalHeight - currentSize.height) > 1 else {
            return false
        }
        workspaceSizes[workspaceId] = CGSize(width: totalWidth, height: totalHeight)
        guard activeWorkspaceId == workspaceId else {
            return false
        }
        let panelDims = bridge.resizeLayoutPx(widthPx: Int(totalWidth), heightPx: Int(totalHeight))
        return applyPanelDimensions(panelDims, in: workspaceId)
    }

    @discardableResult
    func applyPanelDimensions(
        _ panelDims: [MoonBitBridge.PanelDimensions],
        in workspaceId: Int32
    ) -> Bool {
        guard let tab = selectedTab(in: workspaceId), !panelDims.isEmpty else { return false }

        for dim in panelDims {
            if let panel = tab.panel(forPanelId: dim.panelId) {
                panel.state.gridCache.updateDimensions(rows: dim.rows, cols: dim.cols)
                if panel.state.pty.isConnected {
                    bridge.ptyResize(
                        masterFd: panel.state.pty.masterFd,
                        rows: dim.rows,
                        cols: dim.cols
                    )
                }
                panel.state.refresh()
            }
        }
        return true
    }

    @discardableResult
    func notifyDividerMoved(
        in workspaceId: Int32,
        panelId: Int32,
        firstSizePx: Int,
        totalSizePx: Int
    ) -> Bool {
        activateWorkspaceIfNeeded(workspaceId)
        let panelDims = bridge.notifyPanelResize(
            panelId: panelId,
            firstSizePx: firstSizePx,
            totalSizePx: totalSizePx
        )
        return applyPanelDimensions(panelDims, in: workspaceId)
    }

    @discardableResult
    func syncWorkspacesFromBridge() -> Bool {
        let snapshots = bridge.getWorkspaceSnapshot()

        if snapshots.isEmpty {
            for tab in tabsById.values {
                for panel in tab.panels {
                    panel.state.stopPtyLoop()
                }
            }
            tabsById.removeAll()
            workspaces.removeAll()
            activeWorkspaceId = nil
            primaryWindowContext.workspaceId = nil
            return true
        }

        let oldWorkspaces = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceId, $0) })
        let visibleTabIds = Set(snapshots.flatMap { $0.tabs.map(\.tabId) })
        let removedTabIds = Set(tabsById.keys).subtracting(visibleTabIds)
        for tabId in removedTabIds {
            if let tab = tabsById.removeValue(forKey: tabId) {
                for panel in tab.panels {
                    panel.state.stopPtyLoop()
                }
            }
        }

        var orderedWorkspaces: [TerminalWorkspace] = []
        for snapshot in snapshots {
            let workspace = oldWorkspaces[snapshot.workspaceId] ?? TerminalWorkspace(workspaceId: snapshot.workspaceId)
            workspace.isActive = snapshot.isActive
            workspace.selectedTabId = snapshot.activeTabId >= 0 ? snapshot.activeTabId : snapshot.tabs.first?.tabId
            workspace.orderedTabIds = snapshot.tabs.map(\.tabId)

            for tabInfo in snapshot.tabs {
                let tab = tabsById[tabInfo.tabId] ?? TerminalTab(tabId: tabInfo.tabId)
                tab.isActive = tabInfo.isActive
                if !tabInfo.title.isEmpty {
                    tab.title = tabInfo.title
                }
                tabsById[tabInfo.tabId] = tab
            }

            orderedWorkspaces.append(workspace)
        }

        workspaces = orderedWorkspaces
        activeWorkspaceId = snapshots.first(where: { $0.isActive })?.workspaceId ?? snapshots.first?.workspaceId
        let workspaceIds = Set(orderedWorkspaces.map(\.workspaceId))
        if let currentPrimary = primaryWindowContext.workspaceId,
           !workspaceIds.contains(currentPrimary) {
            primaryWindowContext.workspaceId = orderedWorkspaces.first?.workspaceId
        } else if primaryWindowContext.workspaceId == nil {
            primaryWindowContext.workspaceId = activeWorkspaceId
        }
        return true
    }

    func makeFocusedPanelFirstResponder(in workspaceId: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let focused = self.focusedPanel(in: workspaceId),
                  let view = focused.state.terminalView,
                  let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    func closeAll() {
        for tab in tabsById.values {
            for panel in tab.panels {
                panel.state.stopPtyLoop()
            }
        }
        bridge.shutdown()
        tabsById.removeAll()
        workspaces.removeAll()
        activeWorkspaceId = nil
        primaryWindowContext.workspaceId = nil
    }

    private func activateWorkspaceIfNeeded(_ workspaceId: Int32?) {
        guard let workspaceId else { return }
        if activeWorkspaceId != workspaceId {
            _ = bridge.activateWorkspace(workspaceId: workspaceId)
            _ = syncWorkspacesFromBridge()
        }
    }

    private func forceLayoutResize(for workspaceId: Int32) {
        guard let size = workspaceSizes[workspaceId], size.width > 0, size.height > 0 else { return }
        activateWorkspaceIfNeeded(workspaceId)
        let panelDims = bridge.resizeLayoutPx(
            widthPx: Int(size.width),
            heightPx: Int(size.height)
        )
        _ = applyPanelDimensions(panelDims, in: workspaceId)
    }

    private func hoveredTarget(at screenPoint: CGPoint) -> TabDragHoverTarget? {
        // Tab bar takes priority over all other targets — check it first.
        // This avoids the need to tune frame sizes relative to content/panel zones.
        for (workspaceId, barFrame) in tabBarFrames {
            if barFrame.contains(screenPoint) {
                return .tabBar(workspaceId: workspaceId)
            }
        }

        // Fall through to registered drop targets (panel, workspaceContent, etc.).
        let candidates = dropTargets.values.filter { $0.frame.contains(screenPoint) }
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }
        return sorted.first?.target
    }

    private func shouldDetachDraggedTabOutsideWindows(_ dragState: TabDragState) -> Bool {
        guard canDetachTabToNewWindow(tabId: dragState.tabId) else { return false }
        return !NSApp.windows.contains(where: { window in
            window.isVisible && window.frame.contains(dragState.screenPoint)
        })
    }
}
