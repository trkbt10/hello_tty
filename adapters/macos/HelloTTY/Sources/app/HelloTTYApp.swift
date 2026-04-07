import SwiftUI

@main
struct HelloTTYApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appDelegate.tabManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 720, height: 480)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    let tab = appDelegate.tabManager.newTab()
                    tab.state.initialize()
                    tab.state.startShell()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        ZStack {
            // Behind-window blur layer.
            //
            // This NSVisualEffectView with .behindWindow blending is the ONLY
            // way to get the macOS window-compositor Gaussian blur.
            // `.ignoresSafeArea()` makes it extend under the titlebar, so
            // both the toolbar chrome and the content area share the same
            // continuous blur — matching Terminal.app / Ghostty behavior.
            //
            // Material choices:
            //   .hudWindow        — dark, high saturation (good for dark terminals)
            //   .underWindowBackground — neutral, adapts to light/dark appearance
            //   .sidebar           — Finder sidebar style
            //   .fullScreenUI      — very dark
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .behindWindow,
                state: .active
            )
            .ignoresSafeArea()

            // Terminal content (drawn on top of the blur)
            if let tab = tabManager.selectedTab {
                TerminalContainerView(state: tab.state)
                    .id(tab.id)
            } else {
                PlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Toolbar area: tab capsules + new-tab button
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlassTabBarView(tabManager: tabManager)
            }
        }
        .onAppear {
            if tabManager.tabs.isEmpty {
                let tab = tabManager.newTab()
                tab.state.initialize()
                tab.state.startShell()
            }
        }
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

/// Tab bar rendered as glass capsules inside the unified toolbar.
///
/// Each tab is a translucent capsule; the selected tab has a brighter,
/// more opaque glass fill — mimicking the Liquid Glass tab style from
/// Finder in macOS 26.
struct GlassTabBarView: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabManager.tabs) { tab in
                GlassTabCapsule(
                    tab: tab,
                    isSelected: tabManager.selectedTabId == tab.id,
                    onSelect: { tabManager.selectTab(tab) },
                    onClose: { tabManager.closeTab(tab) }
                )
            }

            // "+" button — plain icon, matching Finder style
            Button(action: {
                let newTab = tabManager.newTab()
                newTab.state.initialize()
                newTab.state.startShell()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Glass Tab Capsule

struct GlassTabCapsule: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(tab.label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Close button: visible on hover or when selected
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
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 80, maxWidth: 180)
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
        .overlay(
            Capsule()
                .strokeBorder(
                    isSelected
                        ? Color.white.opacity(0.25)
                        : Color.white.opacity(0.08),
                    lineWidth: 0.5
                )
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Terminal Container

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
