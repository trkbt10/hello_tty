import Foundation
import SwiftUI
import Combine

/// Represents a single terminal tab.
///
/// The session lifecycle (terminal init, PTY spawn, shell path resolution)
/// is managed entirely by MoonBit (src/session/).
/// This is a thin Swift wrapper providing Combine/SwiftUI observability.
class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    /// MoonBit session ID (from SessionManager).
    let sessionId: Int32
    @Published var title: String = "Terminal"
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
/// Session lifecycle is FULLY delegated to MoonBit SessionManager (SoT):
///   - Shell path resolution ($SHELL) → MoonBit
///   - Terminal init (grid, parser) → MoonBit
///   - PTY spawn (posix_spawn) → MoonBit
///
/// This class only handles:
///   - SwiftUI observability (@Published)
///   - PTY I/O loop (platform threading concern — MoonBit GC not thread-safe)
///   - Mapping MoonBit session IDs to Swift UI objects
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

    /// Create a new tab. MoonBit handles everything:
    ///   1. Resolve shell from $SHELL
    ///   2. Create terminal (grid + parser)
    ///   3. Spawn PTY (posix_spawn)
    /// Swift only starts the I/O read loop with the returned master_fd.
    @discardableResult
    func newTab(rows: Int = 24, cols: Int = 80) -> TerminalTab {
        // Single call to MoonBit — creates session + spawns PTY
        guard let result = bridge.createSession(rows: rows, cols: cols) else {
            NSLog("hello_tty: failed to create session")
            // Fallback: create a tab with no PTY
            let state = TerminalState(theme: theme)
            let tab = TerminalTab(sessionId: -1, state: state)
            tabs.append(tab)
            selectedTabId = tab.id
            return tab
        }

        let state = TerminalState(theme: theme)
        let tab = TerminalTab(sessionId: result.sessionId, state: state)
        tabs.append(tab)
        selectedTabId = tab.id

        // Switch MoonBit active session
        _ = bridge.switchSession(id: result.sessionId)

        // Start PTY I/O loop (platform responsibility — threading)
        if result.masterFd >= 0 {
            state.startPtyLoop(masterFd: result.masterFd)
        }

        return tab
    }

    func closeTab(_ tab: TerminalTab) {
        tab.state.stopPtyLoop()
        bridge.destroySession(id: tab.sessionId)

        tabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = tabs.last?.id
            if let newTab = tabs.last {
                _ = bridge.switchSession(id: newTab.sessionId)
            }
        }
    }

    func selectTab(_ tab: TerminalTab) {
        selectedTabId = tab.id
        _ = bridge.switchSession(id: tab.sessionId)
    }

    func closeAll() {
        for tab in tabs {
            tab.state.stopPtyLoop()
            bridge.destroySession(id: tab.sessionId)
        }
        tabs.removeAll()
        selectedTabId = nil
    }
}
