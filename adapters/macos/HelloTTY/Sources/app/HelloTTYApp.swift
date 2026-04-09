import SwiftUI

@main
struct HelloTTYApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindowView(windowContext: appDelegate.tabManager.primaryWindowContext)
                .environmentObject(appDelegate.tabManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 480)
        .commands {
            // Replace default Cmd+N (new window) — we don't support multi-window yet
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    appDelegate.tabManager.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Panel") {
                    appDelegate.tabManager.closeFocusedPanel()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject var windowContext: WorkspaceWindowContext

    var body: some View {
        ZStack {
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .behindWindow,
                state: .active
            )
            .ignoresSafeArea()

            if let workspaceId = windowContext.workspaceId,
               tabManager.selectedTab(in: workspaceId) != nil {
                PanelSplitView(tabManager: tabManager, workspaceId: workspaceId)
            } else {
                PlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let workspaceId = windowContext.workspaceId {
                if tabManager.tabs(in: workspaceId).isEmpty {
                    tabManager.newTab(in: workspaceId)
                }
            } else if tabManager.workspaces.isEmpty {
                _ = tabManager.newTab()
            }
        }
    }
}

struct TitlebarTabStripView: View {
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject var windowContext: WorkspaceWindowContext

    var body: some View {
        ZStack(alignment: .bottom) {
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .withinWindow,
                state: .active
            )
            GlassTabBarView(tabManager: tabManager, windowContext: windowContext)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 7)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .frame(height: 42)
    }
}

// MARK: - Placeholder

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("hello_tty")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            Text("Press \u{2318}T to open a new tab")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Glass Tab Bar (toolbar-inline)

struct GlassTabBarView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var windowContext: WorkspaceWindowContext

    var body: some View {
        HStack(spacing: 4) {
            let tabs = tabManager.tabs(in: windowContext.workspaceId)
            ForEach(tabs, id: \.id) { tab in
                GlassTabCapsule(
                    tab: tab,
                    isSelected: tabManager.selectedTab(in: windowContext.workspaceId)?.tabId == tab.id,
                    isBeingDragged: tabManager.isTabBeingDragged(tab.tabId),
                    onSelect: { tabManager.selectTab(tab, in: windowContext.workspaceId) },
                    onClose: { tabManager.closeTab(tab, in: windowContext.workspaceId) },
                    onDetach: {
                        if let newWorkspaceId = tabManager.detachTabToNewWindow(tabId: tab.tabId) {
                            AppDelegate.shared?.showDetachedWindow(for: newWorkspaceId)
                        }
                    },
                    onFrameChange: { frame in
                        if let frame {
                            tabManager.registerTabFrame(tabId: tab.tabId, frame: frame)
                        } else {
                            tabManager.unregisterTabFrame(tabId: tab.tabId)
                        }
                    }
                )
            }

            Button(action: {
                _ = tabManager.newTab(in: windowContext.workspaceId)
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        // Register the entire tab bar strip as a single drop target region.
        // TabManager resolves the insertion index dynamically from x position.
        .background(
            ScreenFrameReporter { frame in
                guard let workspaceId = windowContext.workspaceId else { return }
                if let frame {
                    tabManager.registerTabBarFrame(workspaceId: workspaceId, frame: frame)
                } else {
                    tabManager.unregisterTabBarFrame(workspaceId: workspaceId)
                }
            }
            .allowsHitTesting(false)
        )
        .onDisappear {
            if let workspaceId = windowContext.workspaceId {
                tabManager.unregisterTabBarFrame(workspaceId: workspaceId)
            }
        }
    }

}

// MARK: - Glass Tab Capsule

struct GlassTabCapsule: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let isBeingDragged: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDetach: () -> Void
    let onFrameChange: (CGRect?) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(tab.label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .padding(.trailing, (isSelected || isHovering) ? 18 : 0)
        .frame(minWidth: 80, maxWidth: 180)
        .opacity(isBeingDragged ? 0.55 : 1.0)
        .background(
            Capsule()
                .fill(isSelected
                    ? .ultraThickMaterial
                    : (isHovering ? .regularMaterial : .ultraThinMaterial))
                .shadow(
                    color: isSelected ? Color.black.opacity(0.08) : .clear,
                    radius: 2, y: 1
                )
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    isSelected
                        ? Color.white.opacity(0.25)
                        : Color.white.opacity(0.08),
                    lineWidth: 0.5
                )
        }
        .overlay {
            TabMouseInteractionLayer(
                tabId: tab.tabId,
                onClick: onSelect,
                onFrameChange: onFrameChange
            )
        }
        .overlay(alignment: .trailing) {
            if isSelected || isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(.quaternary.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .contentShape(Capsule())
        .contextMenu {
            Button("Move Tab to New Window", action: onDetach)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onDisappear {
            onFrameChange(nil)
        }
    }
}

// MARK: - Terminal Container (legacy, kept for single-panel fallback)

struct TerminalContainerView: View {
    @ObservedObject var state: TerminalState

    var body: some View {
        TerminalView(state: state)
            .onChange(of: state.title) { newTitle in
                if let window = NSApp.mainWindow {
                    window.title = newTitle.isEmpty ? "hello_tty" : newTitle
                }
            }
    }
}

// MARK: - Window Title Sync (for panel-based layout)

struct WindowTitleModifier: ViewModifier {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var windowContext: WorkspaceWindowContext

    func body(content: Content) -> some View {
        content
            .onChange(of: tabManager.selectedTab(in: windowContext.workspaceId)?.title) { newTitle in
                if let window = NSApp.mainWindow {
                    window.title = (newTitle ?? "").isEmpty ? "hello_tty" : (newTitle ?? "hello_tty")
                }
            }
    }
}
