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
        // Theme background — shown while panel view is not yet available
        // during tab switch, avoiding a visible flash.
        let themeBg = Color(nsColor: tabManager.theme.background)
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
                    themeBg
                }
            } else {
                themeBg
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

    /// Drop overlay showing which half of the panel the tab will merge into.
    /// No border is shown when the panel is simply focused (no drag active).
    private func panelDropOverlay(panelId: Int32, isFocused: Bool) -> some View {
        PanelDropDirectionOverlay(
            tabManager: tabManager,
            workspaceId: workspaceId,
            panelId: panelId
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
                Color(nsColor: tabManager.theme.background)
            }

        case .split(let direction, let ratio, let first, let second):
            let firstLeafId = LayoutTree.firstLeafId(first)
            let dividerSize: CGFloat = tabManager.uiConfig.panelDividerHitArea
            GeometryReader { geometry in
                switch direction {
                case .vertical:
                    let available = geometry.size.width - dividerSize
                    // During drag, use the exact pixel size from the gesture
                    // instead of re-computing from ratio (avoids feedback jitter).
                    let firstW = tabManager.dividerDragFirstSize[firstLeafId] ?? (available * ratio)
                    let secondW = available - firstW
                    HStack(spacing: 0) {
                        LayoutNodeView(
                            node: first,
                            tab: tab,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        .frame(width: firstW)
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
                        .frame(width: secondW)
                    }

                case .horizontal:
                    let available = geometry.size.height - dividerSize
                    let firstH = tabManager.dividerDragFirstSize[firstLeafId] ?? (available * ratio)
                    let secondH = available - firstH
                    VStack(spacing: 0) {
                        LayoutNodeView(
                            node: first,
                            tab: tab,
                            tabManager: tabManager,
                            workspaceId: workspaceId
                        )
                        .frame(height: firstH)
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
                        .frame(height: secondH)
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

    private var dividerThickness: CGFloat { tabManager.uiConfig.panelDividerThickness }
    private var dividerHitArea: CGFloat { tabManager.uiConfig.panelDividerHitArea }
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor)
                    .opacity(isDragging ? 0.5 : (isHovering ? 0.3 : 0.1)))
                .frame(
                    width: direction == .vertical ? dividerThickness : nil,
                    height: direction == .horizontal ? dividerThickness : nil
                )
        }
        .frame(
            width: direction == .vertical ? dividerHitArea : nil,
            height: direction == .horizontal ? dividerHitArea : nil
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
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
                    let dividerPx = dividerHitArea
                    let available = totalSize - dividerPx
                    let firstSize = min(max(startOffset + translation, 20), available - 20)
                    let firstSizeInt = Int(firstSize)

                    // Publish the drag's computed size so LayoutNodeView can
                    // use it directly instead of re-computing from MoonBit's ratio.
                    // This breaks the feedback loop that causes jitter.
                    tabManager.dividerDragFirstSize[panelId] = firstSize

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
                    tabManager.dividerDragFirstSize.removeValue(forKey: panelId)
                    tabManager.objectWillChange.send()
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
        PanelDropDirectionOverlay(
            tabManager: tabManager,
            workspaceId: workspaceId,
            panelId: panelId
        )
        .onDisappear {
            tabManager.unregisterDropTarget(id: "workspace-\(workspaceId)-panel-\(panelId)")
        }
    }
}

/// Shows a directional split preview when dragging a tab over a panel.
/// Highlights the half of the panel where the dropped tab will appear.
/// No overlay when the panel is merely focused (no drag in progress).
private struct PanelDropDirectionOverlay: View {
    @ObservedObject var tabManager: TabManager
    let workspaceId: Int32
    let panelId: Int32

    private var isHovering: Bool {
        tabManager.isHoveringPanel(workspaceId: workspaceId, panelId: panelId)
    }

    private var dropEdge: (direction: Int32, secondHalf: Bool)? {
        tabManager.panelDropEdge(workspaceId: workspaceId, panelId: panelId)
    }

    var body: some View {
        GeometryReader { geometry in
            if isHovering, let edge = dropEdge {
                let isVertical = edge.direction == 0
                let halfRect: CGRect = {
                    let w = geometry.size.width
                    let h = geometry.size.height
                    if isVertical {
                        // Left or right half
                        let halfW = w / 2
                        return edge.secondHalf
                            ? CGRect(x: halfW, y: 0, width: halfW, height: h)
                            : CGRect(x: 0, y: 0, width: halfW, height: h)
                    } else {
                        // Top or bottom half
                        let halfH = h / 2
                        return edge.secondHalf
                            ? CGRect(x: 0, y: halfH, width: w, height: halfH)
                            : CGRect(x: 0, y: 0, width: w, height: halfH)
                    }
                }()

                ZStack {
                    // Tinted half to show where the new panel will appear
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: halfRect.width, height: halfRect.height)
                        .position(x: halfRect.midX, y: halfRect.midY)

                    // Border around the highlighted half
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                        .frame(width: halfRect.width, height: halfRect.height)
                        .position(x: halfRect.midX, y: halfRect.midY)
                }
                .animation(.easeInOut(duration: 0.12), value: edge.direction)
                .animation(.easeInOut(duration: 0.12), value: edge.secondHalf)
            }
        }
        .allowsHitTesting(false)
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
