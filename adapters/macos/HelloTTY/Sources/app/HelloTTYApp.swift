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
                state: .active,
                appearance: tabManager.theme.appearance
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
        .environment(\.colorScheme, tabManager.theme.isDark ? .dark : .light)
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

    private var ui: MoonBitBridge.UIConfigInfo { tabManager.uiConfig }

    var body: some View {
        VStack(spacing: 0) {
            GlassTabBarView(tabManager: tabManager, windowContext: windowContext)
                .padding(.leading, ui.titlebarLeadingInset)
                .padding(.trailing, ui.titlebarTrailingInset)
                // Center tabs vertically: (bar_height - tab_height - separator) / 2
                .padding(.vertical, (ui.tabBarHeight - ui.tabHeight - ui.separatorThickness) / 2)
            Color(nsColor: .separatorColor)
                .frame(height: ui.separatorThickness)
        }
        .frame(height: ui.tabBarHeight)
        // Use the theme-aware appearance for all SwiftUI materials in this subtree.
        .environment(\.colorScheme, tabManager.theme.isDark ? .dark : .light)
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
        HStack(spacing: tabManager.uiConfig.tabSpacing) {
            let tabs = tabManager.tabs(in: windowContext.workspaceId)
            ForEach(tabs, id: \.id) { tab in
                GlassTabCapsule(
                    tab: tab,
                    uiConfig: tabManager.uiConfig,
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

            Spacer(minLength: 0)
        }
        // Insertion indicator as overlay — does not affect tab layout.
        .overlay {
            TabInsertionOverlay(
                tabManager: tabManager,
                workspaceId: windowContext.workspaceId
            )
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
    let uiConfig: MoonBitBridge.UIConfigInfo
    let isSelected: Bool
    let isBeingDragged: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDetach: () -> Void
    let onFrameChange: (CGRect?) -> Void

    @State private var isHovering = false

    // Corner radius, padding, and close button inset are all derived from
    // UIConfig (MoonBit SoT). The ratio-based model ensures:
    //   outer_r = tab_height * corner_ratio
    //   inner_r = max(outer_r - padding, 0)
    //   close_inset >= outer_r
    private var tabShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: uiConfig.outerCornerRadius, style: .continuous)
    }

    private var tabFill: some View {
        Group {
            if isSelected {
                tabShape.fill(.ultraThickMaterial)
            } else if isHovering {
                tabShape.fill(.regularMaterial)
            } else {
                tabShape.fill(.ultraThinMaterial)
            }
        }
    }

    private var tabBorderColor: Color {
        isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.08)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(tab.label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, uiConfig.tabPaddingH)
        .padding(.vertical, uiConfig.tabPaddingV)
        .padding(.trailing, (isSelected || isHovering) ? uiConfig.closeButtonExtraTrailing : 0)
        .frame(minWidth: uiConfig.tabMinWidth, maxWidth: uiConfig.tabMaxWidth)
        .opacity(isBeingDragged ? 0.55 : 1.0)
        .background(tabFill)
        .overlay {
            tabShape
                .strokeBorder(tabBorderColor, lineWidth: 0.5)
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
                        .frame(
                            width: uiConfig.closeButtonSize,
                            height: uiConfig.closeButtonSize
                        )
                        .background(
                            Circle()
                                .fill(.quaternary.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, uiConfig.closeButtonInset)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .contentShape(tabShape)
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

// MARK: - Tab Insertion Overlay

/// Draws a thin vertical insertion indicator at the computed drop position.
/// Rendered as an overlay on the tab bar so it never shifts tab layout.
/// Uses the registered tab frames (screen coordinates) to position itself.
struct TabInsertionOverlay: View {
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32?

    var body: some View {
        GeometryReader { geometry in
            if let workspaceId,
               let dragState = tabManager.tabDragState,
               case .tabBar(let wid) = tabManager.dragHoverTarget,
               wid == workspaceId,
               let barFrame = tabManager.frameForDropTarget(.tabBar(workspaceId: workspaceId)) {
                let index = tabManager.tabInsertionIndex(
                    workspaceId: workspaceId,
                    screenX: dragState.screenPoint.x
                )
                let tabs = tabManager.tabs(in: workspaceId)
                let orderedIds = tabs.map(\.tabId)
                let screenX = insertionScreenX(
                    index: index,
                    orderedIds: orderedIds,
                    tabManager: tabManager
                )
                if let screenX {
                    // Convert screen x to local: both tabFrames and barFrame
                    // are in screen coordinates, so subtract barFrame origin.
                    let localX = screenX - barFrame.minX
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 20)
                        .position(x: localX, y: geometry.size.height / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Compute the screen x coordinate for the insertion indicator.
    /// index=0 → left edge of first tab, index=N → right edge of last tab.
    private func insertionScreenX(
        index: Int,
        orderedIds: [Int32],
        tabManager: TabManager
    ) -> CGFloat? {
        if orderedIds.isEmpty { return nil }
        if index <= 0 {
            // Before first tab: left edge of first tab
            guard let frame = tabManager.frameForTab(tabId: orderedIds[0]) else { return nil }
            return frame.minX
        }
        if index >= orderedIds.count {
            // After last tab: right edge of last tab
            guard let frame = tabManager.frameForTab(tabId: orderedIds[orderedIds.count - 1]) else { return nil }
            return frame.maxX
        }
        // Between tabs: midpoint between right edge of prev and left edge of next
        guard let prevFrame = tabManager.frameForTab(tabId: orderedIds[index - 1]),
              let nextFrame = tabManager.frameForTab(tabId: orderedIds[index])
        else { return nil }
        return (prevFrame.maxX + nextFrame.minX) / 2
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
