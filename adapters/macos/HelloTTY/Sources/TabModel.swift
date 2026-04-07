import Foundation
import SwiftUI
import Combine

/// Represents a single terminal tab with its own PTY session and state.
class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String = "zsh"
    @Published var isActive: Bool = true
    let state: TerminalState

    private var titleSink: AnyCancellable?

    init(state: TerminalState) {
        self.state = state
        // Sync tab title from terminal title
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
/// NOTE: The current MoonBit bridge uses a global singleton terminal state.
/// True multi-tab (each with independent terminal buffers) requires either:
///   - Multiple MoonBit instances (one dylib per tab), or
///   - MoonBit core supporting multiple terminal IDs
/// For now, tabs share the same underlying state and switching tabs
/// re-initializes the MoonBit state. This is a known limitation.
class TabManager: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabId: UUID?

    let theme: TerminalTheme

    init(theme: TerminalTheme = .midnight) {
        self.theme = theme
    }

    var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return tabs.first }
        return tabs.first(where: { $0.id == id })
    }

    @discardableResult
    func newTab(shell: String = "/bin/zsh", rows: Int = 24, cols: Int = 80) -> TerminalTab {
        let state = TerminalState(theme: theme)
        let tab = TerminalTab(state: state)
        tabs.append(tab)
        selectedTabId = tab.id
        return tab
    }

    func closeTab(_ tab: TerminalTab) {
        tab.state.shutdown()
        tabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = tabs.last?.id
        }
    }

    func closeAll() {
        for tab in tabs {
            tab.state.shutdown()
        }
        tabs.removeAll()
        selectedTabId = nil
    }
}
