import Foundation
import SwiftUI
import Combine

/// Represents a single terminal tab.
///
/// The session lifecycle is managed by MoonBit (src/session/).
/// This is a thin Swift wrapper providing Combine/SwiftUI observability.
class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    /// MoonBit session ID (from SessionManager).
    let sessionId: Int32
    @Published var title: String = "zsh"
    @Published var isActive: Bool = true
    let state: TerminalState

    private var titleSink: AnyCancellable?

    init(sessionId: Int32, state: TerminalState) {
        self.sessionId = sessionId
        self.state = state
        titleSink = state.$title
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
}

/// Manages the collection of terminal tabs.
///
/// Session lifecycle is delegated to MoonBit SessionManager (SoT).
/// This class handles:
///   - Swift/SwiftUI observability (@Published)
///   - PTY orchestration (platform-specific)
///   - Mapping MoonBit session IDs to Swift TerminalTab objects
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

    @discardableResult
    func newTab(shell: String = "/bin/zsh", rows: Int = 24, cols: Int = 80) -> TerminalTab {
        // Create session in MoonBit (SoT)
        let sessionId = bridge.createSession(rows: rows, cols: cols)

        let state = TerminalState(theme: theme)
        let tab = TerminalTab(sessionId: sessionId, state: state)
        tabs.append(tab)
        selectedTabId = tab.id

        // Switch MoonBit active session
        _ = bridge.switchSession(id: sessionId)

        return tab
    }

    func closeTab(_ tab: TerminalTab) {
        tab.state.shutdown()
        // Destroy session in MoonBit (SoT)
        bridge.destroySession(id: tab.sessionId)

        tabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = tabs.last?.id
            // Switch MoonBit to new active session
            if let newTab = tabs.last {
                _ = bridge.switchSession(id: newTab.sessionId)
            }
        }
    }

    func selectTab(_ tab: TerminalTab) {
        selectedTabId = tab.id
        // Switch MoonBit active session
        _ = bridge.switchSession(id: tab.sessionId)
    }

    func closeAll() {
        for tab in tabs {
            tab.state.shutdown()
            bridge.destroySession(id: tab.sessionId)
        }
        tabs.removeAll()
        selectedTabId = nil
    }
}
