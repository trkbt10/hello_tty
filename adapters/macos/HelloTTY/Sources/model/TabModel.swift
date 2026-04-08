import Foundation
import SwiftUI
import Combine

/// Represents a single terminal panel within a tab.
///
/// Each panel maps 1:1 to a MoonBit Session (independent PTY, grid, parser).
/// The panel owns a TerminalState which drives the PTY I/O loop.
class TerminalPanel: Identifiable, ObservableObject {
    let id = UUID()
    /// MoonBit panel ID (from LayoutManager).
    let panelId: Int32
    /// MoonBit session ID (from SessionManager, via LayoutManager).
    let sessionId: Int32
    @Published var isFocused: Bool = false
    let state: TerminalState

    init(panelId: Int32, sessionId: Int32, state: TerminalState) {
        self.panelId = panelId
        self.sessionId = sessionId
        self.state = state
    }
}

/// Represents a single terminal tab containing one or more panels.
///
/// The layout tree (split structure) is managed by MoonBit LayoutManager.
/// This is a thin Swift wrapper providing Combine/SwiftUI observability.
class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    /// MoonBit tab ID (from LayoutManager).
    let tabId: Int32
    @Published var title: String = "Terminal"
    @Published var isActive: Bool = true

    /// All panels in this tab. The layout tree structure is queried
    /// from MoonBit via ffi_get_layout() — this flat list is for
    /// PTY I/O loop management and state lookup.
    @Published var panels: [TerminalPanel] = []

    private var titleSink: AnyCancellable?

    init(tabId: Int32) {
        self.tabId = tabId
    }

    /// Add a panel and observe its state's title changes.
    func addPanel(_ panel: TerminalPanel) {
        panels.append(panel)
        // Observe focused panel's title
        if panel.isFocused {
            observeTitle(of: panel)
        }
    }

    /// Remove a panel by panelId.
    func removePanel(panelId: Int32) {
        panels.removeAll(where: { $0.panelId == panelId })
    }

    /// Find a panel by panelId.
    func panel(forPanelId pid: Int32) -> TerminalPanel? {
        panels.first(where: { $0.panelId == pid })
    }

    /// Find a panel by sessionId.
    func panel(forSessionId sid: Int32) -> TerminalPanel? {
        panels.first(where: { $0.sessionId == sid })
    }

    /// Update which panel is focused and observe its title.
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
                guard let self = self else { return }
                if !newTitle.isEmpty {
                    self.title = newTitle
                }
            }
    }

    var label: String {
        title.isEmpty ? "Terminal" : title
    }

    /// Convenience: the focused panel's state (backward compatibility for code
    /// that used the old single-state-per-tab model).
    var state: TerminalState? {
        panels.first(where: { $0.isFocused })?.state ?? panels.first?.state
    }
}

/// Manages the collection of terminal tabs and their panels.
///
/// Session and layout lifecycle is FULLY delegated to MoonBit:
///   - LayoutManager owns the tab/panel layout tree
///   - SessionManager owns the session (PTY, grid, parser)
///
/// This class handles:
///   - SwiftUI observability (@Published)
///   - PTY I/O loop per panel (platform threading concern)
///   - Mapping MoonBit tab/panel IDs to Swift UI objects
class TabManager: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabId: UUID?

    let bridge = MoonBitBridge.shared
    let theme: TerminalTheme

    init() {
        self.theme = TerminalTheme.fromBridge(MoonBitBridge.shared)
    }

    var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return tabs.first }
        return tabs.first(where: { $0.id == id })
    }

    /// The currently focused panel across all tabs.
    var focusedPanel: TerminalPanel? {
        selectedTab?.panels.first(where: { $0.isFocused })
    }

    // MARK: - Tab Operations

    /// Create a new tab with a single panel.
    /// MoonBit LayoutManager handles: session creation, PTY spawn, layout tree.
    @discardableResult
    func newTab(rows: Int = 24, cols: Int = 80) -> TerminalTab {
        guard let result = bridge.createTab(rows: rows, cols: cols) else {
            NSLog("hello_tty: failed to create tab")
            let tab = TerminalTab(tabId: -1)
            tabs.append(tab)
            selectedTabId = tab.id
            return tab
        }

        let tab = TerminalTab(tabId: result.tabId)
        let state = TerminalState(theme: theme, sessionId: result.sessionId)
        let panel = TerminalPanel(panelId: result.panelId,
                                  sessionId: result.sessionId,
                                  state: state)
        panel.isFocused = true
        tab.addPanel(panel)

        tabs.append(tab)
        selectedTabId = tab.id

        // Start PTY I/O loop
        if result.masterFd >= 0 {
            state.startPtyLoop(masterFd: result.masterFd)
        }

        // Resize the new tab's layout to match the current window size
        forceLayoutResize()

        return tab
    }

    func closeTab(_ tab: TerminalTab) {
        // Stop all PTY loops in this tab
        for panel in tab.panels {
            panel.state.stopPtyLoop()
        }
        bridge.closeTab(id: tab.tabId)

        tabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = tabs.last?.id
            if let newTab = tabs.last {
                _ = bridge.switchTab(id: newTab.tabId)
            }
        }
    }

    func selectTab(_ tab: TerminalTab) {
        selectedTabId = tab.id
        _ = bridge.switchTab(id: tab.tabId)
        forceLayoutResize()
    }

    func nextTab() {
        _ = bridge.nextTab()
        syncSelectedTab()
        forceLayoutResize()
    }

    func prevTab() {
        _ = bridge.prevTab()
        syncSelectedTab()
        forceLayoutResize()
    }

    /// Force a layout resize using the last known total dimensions.
    /// Called after tab switch to ensure the new tab's layout tree gets
    /// proper dimensions and all PTYs are resized.
    private func forceLayoutResize() {
        guard lastTotalWidth > 0 && lastTotalHeight > 0 else { return }
        let panelDims = bridge.resizeLayoutPx(
            widthPx: Int(lastTotalWidth), heightPx: Int(lastTotalHeight))
        _ = applyPanelDimensions(panelDims)
    }

    // MARK: - Panel Operations

    /// Split the focused panel. direction: 0=vertical (left/right), 1=horizontal (top/bottom).
    func splitFocusedPanel(direction: Int32) {
        guard let tab = selectedTab,
              let focused = focusedPanel else { return }

        guard let result = bridge.splitPanel(panelId: focused.panelId, direction: direction) else {
            NSLog("hello_tty: panel too small to split")
            return
        }

        // Create state for the new panel
        let newState = TerminalState(theme: theme, sessionId: result.sessionId)
        let newPanel = TerminalPanel(panelId: result.panelId,
                                     sessionId: result.sessionId,
                                     state: newState)
        tab.addPanel(newPanel)

        // Start PTY I/O loop for the new panel
        if result.masterFd >= 0 {
            newState.startPtyLoop(masterFd: result.masterFd)
        }

        // Update focus (MoonBit already moved focus to new panel)
        tab.setFocusedPanel(result.panelId)

        // Resize all panels via MoonBit SoT. This propagates the split's
        // effect on dimensions to all sessions and sends ptyResize (SIGWINCH).
        forceLayoutResize()

        objectWillChange.send()

        // Move keyboard focus to the new panel's view.
        // Delayed because SwiftUI needs time to create the new TerminalView.
        makeFocusedPanelFirstResponder()
    }

    /// Close the focused panel. If last panel in tab, closes the tab.
    func closeFocusedPanel() {
        guard let tab = selectedTab,
              let focused = focusedPanel else { return }

        // If this is the last panel, close the tab
        if tab.panels.count <= 1 {
            closeTab(tab)
            return
        }

        focused.state.stopPtyLoop()
        let newFocusedSessionId = bridge.closePanel(panelId: focused.panelId)
        tab.removePanel(panelId: focused.panelId)

        // Update focus
        if newFocusedSessionId >= 0 {
            if let newFocused = tab.panel(forSessionId: newFocusedSessionId) {
                tab.setFocusedPanel(newFocused.panelId)
            }
        }

        // Resize remaining panels to fill the freed space
        forceLayoutResize()
        objectWillChange.send()
        makeFocusedPanelFirstResponder()
    }

    /// Focus a panel by MoonBit panel ID.
    func focusPanel(panelId: Int32) {
        guard let tab = selectedTab else { return }
        if bridge.focusPanel(panelId: panelId) {
            tab.setFocusedPanel(panelId)
            objectWillChange.send()
        }
    }

    /// Focus panel by DFS index (Cmd+1/2/3).
    func focusPanelByIndex(_ index: Int) {
        guard let tab = selectedTab else { return }
        if bridge.focusPanelByIndex(Int32(index)) {
            let newFocusedId = bridge.getFocusedPanelId()
            if newFocusedId >= 0 {
                tab.setFocusedPanel(newFocusedId)
                objectWillChange.send()
            }
        }
    }

    /// Focus neighboring panel (Cmd+Alt+Arrow).
    func focusDirection(_ direction: Int32) {
        guard let tab = selectedTab else { return }
        if bridge.focusDirection(direction) {
            let newFocusedId = bridge.getFocusedPanelId()
            if newFocusedId >= 0 {
                tab.setFocusedPanel(newFocusedId)
                makeFocusedPanelFirstResponder()
                objectWillChange.send()
            }
        }
    }

    /// Focus next split pane by creation order (Cmd+]).
    func focusNextSplit() {
        guard let tab = selectedTab else { return }
        let panels = tab.panels
        guard panels.count > 1,
              let currentIdx = panels.firstIndex(where: { $0.isFocused })
        else { return }
        let nextIdx = (currentIdx + 1) % panels.count
        let nextPanel = panels[nextIdx]
        if bridge.focusPanel(panelId: nextPanel.panelId) {
            tab.setFocusedPanel(nextPanel.panelId)
            makeFocusedPanelFirstResponder()
            objectWillChange.send()
        }
    }

    /// Focus previous split pane by creation order (Cmd+[).
    func focusPrevSplit() {
        guard let tab = selectedTab else { return }
        let panels = tab.panels
        guard panels.count > 1,
              let currentIdx = panels.firstIndex(where: { $0.isFocused })
        else { return }
        let prevIdx = (currentIdx - 1 + panels.count) % panels.count
        let prevPanel = panels[prevIdx]
        if bridge.focusPanel(panelId: prevPanel.panelId) {
            tab.setFocusedPanel(prevPanel.panelId)
            makeFocusedPanelFirstResponder()
            objectWillChange.send()
        }
    }

    /// Go to tab by index (Cmd+1-8), or last tab (index = -1, Cmd+9).
    func gotoTab(_ index: Int) {
        let targetTab: TerminalTab?
        if index == -1 {
            targetTab = tabs.last
        } else if index >= 0 && index < tabs.count {
            targetTab = tabs[index]
        } else {
            return
        }
        guard let tab = targetTab else { return }
        selectTab(tab)
    }

    // MARK: - Layout Resize (Container-driven, SoT = MoonBit)

    /// Last known total container dimensions (in pixels).
    /// Stored so forceLayoutResize can replay without needing GeometryReader.
    private(set) var lastTotalWidth: CGFloat = 0
    private(set) var lastTotalHeight: CGFloat = 0

    /// Called by PanelSplitView's GeometryReader when the container size changes.
    /// Passes pixel dimensions directly to MoonBit, which converts to grid cells
    /// using its own cell metrics (SoT) and distributes space via the layout tree.
    @discardableResult
    func applyLayoutResize(totalWidth: CGFloat, totalHeight: CGFloat) -> Bool {
        // Avoid redundant resizes for the same dimensions
        guard abs(totalWidth - lastTotalWidth) > 1 || abs(totalHeight - lastTotalHeight) > 1 else {
            return false
        }
        lastTotalWidth = totalWidth
        lastTotalHeight = totalHeight

        let panelDims = bridge.resizeLayoutPx(
            widthPx: Int(totalWidth), heightPx: Int(totalHeight))
        return applyPanelDimensions(panelDims)
    }

    /// Apply panel dimensions to all panels — shared by layout resize and divider drag.
    @discardableResult
    func applyPanelDimensions(_ panelDims: [MoonBitBridge.PanelDimensions]) -> Bool {
        guard let tab = selectedTab, !panelDims.isEmpty else { return false }

        for dim in panelDims {
            if let panel = tab.panel(forPanelId: dim.panelId) {
                panel.state.gridCache.updateDimensions(rows: dim.rows, cols: dim.cols)
                if panel.state.pty.isConnected {
                    bridge.ptyResize(masterFd: panel.state.pty.masterFd,
                                     rows: dim.rows, cols: dim.cols)
                }
                panel.state.refresh()
            }
        }
        return true
    }

    /// Notify MoonBit that a divider moved.
    /// panelId: first leaf's panel ID (identifies the split).
    /// firstSizePx: first child's pixel size along the split axis.
    /// totalSizePx: total available pixel size along the split axis.
    @discardableResult
    func notifyDividerMoved(panelId: Int32, firstSizePx: Int, totalSizePx: Int) -> Bool {
        let panelDims = bridge.notifyPanelResize(
            panelId: panelId,
            firstSizePx: firstSizePx,
            totalSizePx: totalSizePx
        )
        return applyPanelDimensions(panelDims)
    }

    // MARK: - Sync

    /// Sync the Swift-side selected tab with MoonBit's active tab.
    private func syncSelectedTab() {
        let tabInfos = bridge.listTabs()
        if let active = tabInfos.first(where: { $0.isActive }) {
            if let swiftTab = tabs.first(where: { $0.tabId == Int32(active.id) }) {
                selectedTabId = swiftTab.id
            }
        }
    }

    // MARK: - First Responder Management

    /// Make the focused panel's TerminalBaseView the first responder.
    /// Called after split, close, focus change, etc. to ensure keyboard
    /// input goes to the correct panel.
    ///
    /// Uses a short async delay because SwiftUI may not have created the
    /// new view yet when this is called from splitFocusedPanel.
    func makeFocusedPanelFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let focused = self.focusedPanel,
                  let view = focused.state.terminalView,
                  let window = view.window
            else { return }
            window.makeFirstResponder(view)
        }
    }

    // MARK: - Cleanup

    func closeAll() {
        for tab in tabs {
            for panel in tab.panels {
                panel.state.stopPtyLoop()
            }
        }
        bridge.shutdown()
        tabs.removeAll()
        selectedTabId = nil
    }
}
