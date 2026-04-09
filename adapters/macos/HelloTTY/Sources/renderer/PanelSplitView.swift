import SwiftUI

/// Recursive SwiftUI view that renders the layout tree from MoonBit.
struct PanelSplitView: View {
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32

    var body: some View {
        GeometryReader { geometry in
            content(for: geometry.size)
        }
        .background(
            ScreenFrameReporter { frame in
                let id = "workspace-\(workspaceId)-content"
                if let frame {
                    tabManager.registerDropTarget(
                        id: id,
                        target: .workspaceContent(workspaceId: workspaceId),
                        frame: frame
                    )
                } else {
                    tabManager.unregisterDropTarget(id: id)
                }
            }
            .allowsHitTesting(false)
        )
        .onDisappear {
            tabManager.unregisterDropTarget(id: "workspace-\(workspaceId)-content")
        }
    }

    private func content(for size: CGSize) -> some View {
        let _ = tabManager.applyLayoutResize(
            in: workspaceId,
            totalWidth: size.width,
            totalHeight: size.height
        )
        return Group {
            if let tab = tabManager.selectedTab(in: workspaceId) {
                if let layoutJson = tabManager.bridge.getLayout(),
                   let node = LayoutTree.parse(json: layoutJson) {
                    LayoutNodeView(
                        node: node,
                        tab: tab,
                        tabManager: tabManager,
                        workspaceId: workspaceId
                    )
                } else if let panel = tab.panels.first {
                    panelView(for: panel)
                } else {
                    Color.black
                }
            } else {
                Color.black
            }
        }
    }

    private func panelView(for panel: TerminalPanel) -> some View {
        TerminalView(state: panel.state, tabManager: tabManager, workspaceId: workspaceId)
            .background(
                PanelDropFrameRegistration(
                    tabManager: tabManager,
                    workspaceId: workspaceId,
                    panelId: panel.panelId
                )
            )
            .overlay(panelDropOverlay(panelId: panel.panelId, isFocused: panel.isFocused))
            .onTapGesture {
                tabManager.focusPanel(in: workspaceId, panelId: panel.panelId)
            }
    }

    private func panelDropOverlay(panelId: Int32, isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .stroke(
                tabManager.isHoveringPanel(workspaceId: workspaceId, panelId: panelId)
                    ? Color.accentColor.opacity(0.9)
                    : (isFocused ? Color.accentColor.opacity(0.6) : Color.clear),
                lineWidth: tabManager.isHoveringPanel(workspaceId: workspaceId, panelId: panelId) ? 3 : 1
            )
            .onDisappear {
                tabManager.unregisterDropTarget(id: "workspace-\(workspaceId)-panel-\(panelId)")
            }
    }
}

indirect enum LayoutTree {
    case leaf(panelId: Int32, sessionId: Int32)
    case split(direction: SplitDir, ratio: CGFloat, first: LayoutTree, second: LayoutTree)

    enum SplitDir {
        case vertical
        case horizontal
    }

    static func parse(json: String) -> LayoutTree? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseNode(obj)
    }

    static func firstLeafId(_ tree: LayoutTree) -> Int32 {
        switch tree {
        case .leaf(let panelId, _):
            return panelId
        case .split(_, _, let first, _):
            return firstLeafId(first)
        }
    }

    private static func parseNode(_ obj: [String: Any]) -> LayoutTree? {
        guard let type = obj["type"] as? String else { return nil }
        switch type {
        case "leaf":
            guard let panelId = obj["panel_id"] as? Int,
                  let sessionId = obj["session_id"] as? Int
            else { return nil }
            return .leaf(panelId: Int32(panelId), sessionId: Int32(sessionId))

        case "split":
            guard let direction = obj["direction"] as? String,
                  let ratio = obj["ratio"] as? Double,
                  let firstObj = obj["first"] as? [String: Any],
                  let secondObj = obj["second"] as? [String: Any],
                  let first = parseNode(firstObj),
                  let second = parseNode(secondObj)
            else { return nil }
            return .split(
                direction: direction == "horizontal" ? .horizontal : .vertical,
                ratio: CGFloat(ratio),
                first: first,
                second: second
            )
        default:
            return nil
        }
    }
}

struct LayoutNodeView: View {
    let node: LayoutTree
    let tab: TerminalTab
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32

    var body: some View {
        switch node {
        case .leaf(let panelId, _):
            if let panel = tab.panel(forPanelId: panelId) {
                TerminalView(state: panel.state, tabManager: tabManager, workspaceId: workspaceId)
                    .background(
                        PanelDropFrameRegistration(
                            tabManager: tabManager,
                            workspaceId: workspaceId,
                            panelId: panelId
                        )
                    )
                    .overlay(
                        PanelDropTargetOverlay(
                            tabManager: tabManager,
                            workspaceId: workspaceId,
                            panelId: panelId,
                            isFocused: panel.isFocused
                        )
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tabManager.focusPanel(in: workspaceId, panelId: panelId)
                    }
            } else {
                Color.black
            }

        case .split(let direction, let ratio, let first, let second):
            let firstLeafId = LayoutTree.firstLeafId(first)
            let dividerSize: CGFloat = 4
            GeometryReader { geometry in
                switch direction {
                case .vertical:
                    let available = geometry.size.width - dividerSize
                    HStack(spacing: 0) {
                        LayoutNodeView(
                            node: first,
                            tab: tab,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        .frame(width: available * ratio)
                        DraggableDivider(
                            direction: .vertical,
                            panelId: firstLeafId,
                            totalSize: geometry.size.width,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        LayoutNodeView(
                            node: second,
                            tab: tab,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        .frame(width: available * (1 - ratio))
                    }

                case .horizontal:
                    let available = geometry.size.height - dividerSize
                    VStack(spacing: 0) {
                        LayoutNodeView(
                            node: first,
                            tab: tab,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        .frame(height: available * ratio)
                        DraggableDivider(
                            direction: .horizontal,
                            panelId: firstLeafId,
                            totalSize: geometry.size.height,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        LayoutNodeView(
                            node: second,
                            tab: tab,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        .frame(height: available * (1 - ratio))
                    }
                }
            }
        }
    }
}

struct DraggableDivider: View {
    let direction: LayoutTree.SplitDir
    let panelId: Int32
    let totalSize: CGFloat
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32

    @State private var isDragging = false
    @State private var startOffset: CGFloat = 0
    @State private var lastNotifiedSize: Int = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isDragging ? Color.white.opacity(0.15) : Color.white.opacity(0.06))
                .frame(
                    width: direction == .vertical ? 1 : nil,
                    height: direction == .horizontal ? 1 : nil
                )
        }
        .frame(
            width: direction == .vertical ? 4 : nil,
            height: direction == .horizontal ? 4 : nil
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                if direction == .vertical {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.resizeUpDown.set()
                }
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard totalSize > 0 else { return }
                    if !isDragging {
                        isDragging = true
                        let currentRatio = readCurrentRatio()
                        startOffset = totalSize * currentRatio
                        lastNotifiedSize = Int(startOffset)
                    }

                    let translation = direction == .vertical
                        ? value.translation.width
                        : value.translation.height
                    let dividerPx: CGFloat = 4
                    let available = totalSize - dividerPx
                    let firstSize = min(max(startOffset + translation, 20), available - 20)
                    let firstSizeInt = Int(firstSize)

                    if abs(firstSizeInt - lastNotifiedSize) >= 1 {
                        lastNotifiedSize = firstSizeInt
                        _ = tabManager.notifyDividerMoved(
                            in: workspaceId,
                            panelId: panelId,
                            firstSizePx: firstSizeInt,
                            totalSizePx: Int(available)
                        )
                        tabManager.objectWillChange.send()
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }

    private func readCurrentRatio() -> CGFloat {
        guard let layoutJson = tabManager.bridge.getLayout(),
              let node = LayoutTree.parse(json: layoutJson)
        else { return 0.5 }
        return findRatio(in: node, panelId: panelId) ?? 0.5
    }

    private func findRatio(in node: LayoutTree, panelId: Int32) -> CGFloat? {
        switch node {
        case .leaf:
            return nil
        case .split(_, let ratio, let first, let second):
            if LayoutTree.firstLeafId(first) == panelId {
                return ratio
            }
            return findRatio(in: first, panelId: panelId)
                ?? findRatio(in: second, panelId: panelId)
        }
    }
}

private struct PanelDropTargetOverlay: View {
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32
    let panelId: Int32
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 0)
            .stroke(
                tabManager.isHoveringPanel(workspaceId: workspaceId, panelId: panelId)
                    ? Color.accentColor.opacity(0.9)
                    : (isFocused ? Color.accentColor.opacity(0.5) : Color.clear),
                lineWidth: tabManager.isHoveringPanel(workspaceId: workspaceId, panelId: panelId) ? 3 : 2
            )
            .onDisappear {
                tabManager.unregisterDropTarget(id: "workspace-\(workspaceId)-panel-\(panelId)")
            }
    }
}

private struct PanelDropFrameRegistration: View {
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32
    let panelId: Int32

    var body: some View {
        ScreenFrameReporter { frame in
            let id = "workspace-\(workspaceId)-panel-\(panelId)"
            if let frame {
                tabManager.registerDropTarget(
                    id: id,
                    target: .panel(workspaceId: workspaceId, panelId: panelId),
                    frame: frame
                )
            } else {
                tabManager.unregisterDropTarget(id: id)
            }
        }
        .allowsHitTesting(false)
    }
}
