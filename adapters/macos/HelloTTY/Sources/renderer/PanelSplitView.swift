import SwiftUI

/// Recursive SwiftUI view that renders the layout tree from MoonBit.
///
/// The layout tree is a binary tree: each internal node is a Split
/// (horizontal or vertical), each leaf is a panel containing a TerminalView.
///
/// This view queries the layout from MoonBit via ffi_get_layout() and
/// renders it as nested HStack/VStack with dividers.
struct PanelSplitView: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        GeometryReader { geometry in
            content(for: geometry.size)
        }
    }

    private func content(for size: CGSize) -> some View {
        // Trigger layout resize from the container level.
        // This is the ONLY place that calls resizeLayout — individual panel
        // views must NOT call it (they only know their own partial bounds).
        let _ = tabManager.applyLayoutResize(
            totalWidth: size.width,
            totalHeight: size.height
        )
        return Group {
            if let tab = tabManager.selectedTab {
                if let layoutJson = tabManager.bridge.getLayout(),
                   let node = LayoutTree.parse(json: layoutJson) {
                    LayoutNodeView(node: node, tab: tab, tabManager: tabManager)
                } else {
                    // Fallback: render the first panel full-size
                    if let panel = tab.panels.first {
                        panelView(for: panel)
                    } else {
                        Color.black
                    }
                }
            } else {
                Color.black
            }
        }
    }

    private func panelView(for panel: TerminalPanel) -> some View {
        TerminalView(state: panel.state, tabManager: tabManager)
            .border(panel.isFocused ? Color.accentColor.opacity(0.6) : Color.clear, width: 1)
            .onTapGesture {
                tabManager.focusPanel(panelId: panel.panelId)
            }
    }
}

// MARK: - Layout Tree Model (parsed from MoonBit JSON)

/// Swift representation of MoonBit's LayoutNode, parsed from ffi_get_layout() JSON.
indirect enum LayoutTree {
    case leaf(panelId: Int32, sessionId: Int32)
    case split(direction: SplitDir, ratio: CGFloat, first: LayoutTree, second: LayoutTree)

    enum SplitDir {
        case vertical   // left/right
        case horizontal // top/bottom
    }

    /// Parse the layout JSON from MoonBit into a LayoutTree.
    static func parse(json: String) -> LayoutTree? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseNode(obj)
    }

    /// Get the panel ID of the first leaf in the tree (for divider association).
    static func firstLeafId(_ tree: LayoutTree) -> Int32 {
        switch tree {
        case .leaf(let pid, _): return pid
        case .split(_, _, let first, _): return firstLeafId(first)
        }
    }

    private static func parseNode(_ obj: [String: Any]) -> LayoutTree? {
        guard let type = obj["type"] as? String else { return nil }
        switch type {
        case "leaf":
            guard let pid = obj["panel_id"] as? Int,
                  let sid = obj["session_id"] as? Int
            else { return nil }
            return .leaf(panelId: Int32(pid), sessionId: Int32(sid))

        case "split":
            guard let dirStr = obj["direction"] as? String,
                  let ratio = obj["ratio"] as? Double,
                  let firstObj = obj["first"] as? [String: Any],
                  let secondObj = obj["second"] as? [String: Any],
                  let first = parseNode(firstObj),
                  let second = parseNode(secondObj)
            else { return nil }
            let dir: SplitDir = (dirStr == "horizontal") ? .horizontal : .vertical
            return .split(direction: dir, ratio: CGFloat(ratio), first: first, second: second)

        default:
            return nil
        }
    }
}

// MARK: - Recursive Layout Node View

struct LayoutNodeView: View {
    let node: LayoutTree
    let tab: TerminalTab
    @ObservedObject var tabManager: TabManager

    var body: some View {
        switch node {
        case .leaf(let panelId, _):
            if let panel = tab.panel(forPanelId: panelId) {
                TerminalView(state: panel.state, tabManager: tabManager)
                    .overlay(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(panel.isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tabManager.focusPanel(panelId: panelId)
                    }
            } else {
                Color.black
            }

        case .split(let direction, let ratio, let first, let second):
            let firstLeafId = LayoutTree.firstLeafId(first)
            let dividerSize: CGFloat = 4 // Must match DraggableDivider frame size
            GeometryReader { geometry in
                switch direction {
                case .vertical:
                    let available = geometry.size.width - dividerSize
                    HStack(spacing: 0) {
                        LayoutNodeView(node: first, tab: tab, tabManager: tabManager)
                            .frame(width: available * ratio)
                        DraggableDivider(
                            direction: .vertical,
                            panelId: firstLeafId,
                            totalSize: geometry.size.width,
                            tabManager: tabManager
                        )
                        LayoutNodeView(node: second, tab: tab, tabManager: tabManager)
                            .frame(width: available * (1 - ratio))
                    }
                case .horizontal:
                    let available = geometry.size.height - dividerSize
                    VStack(spacing: 0) {
                        LayoutNodeView(node: first, tab: tab, tabManager: tabManager)
                            .frame(height: available * ratio)
                        DraggableDivider(
                            direction: .horizontal,
                            panelId: firstLeafId,
                            totalSize: geometry.size.height,
                            tabManager: tabManager
                        )
                        LayoutNodeView(node: second, tab: tab, tabManager: tabManager)
                            .frame(height: available * (1 - ratio))
                    }
                }
            }
        }
    }
}

// MARK: - Draggable Divider

struct DraggableDivider: View {
    let direction: LayoutTree.SplitDir
    let panelId: Int32
    let totalSize: CGFloat
    @ObservedObject var tabManager: TabManager

    @State private var isDragging = false
    /// The pixel offset of the divider at the start of this drag gesture.
    @State private var startOffset: CGFloat = 0
    /// Last notified first-child pixel size (to avoid redundant notifications).
    @State private var lastNotifiedSize: Int = 0

    var body: some View {
        // Subtle divider that blends with the terminal background.
        // 1px visible line + wider hit target for dragging.
        ZStack {
            // Visible line: nearly invisible unless hovered/dragged
            Rectangle()
                .fill(isDragging
                    ? Color.white.opacity(0.15)
                    : Color.white.opacity(0.06))
                .frame(
                    width: direction == .vertical ? 1 : nil,
                    height: direction == .horizontal ? 1 : nil
                )
        }
        .frame(
            width: direction == .vertical ? 4 : nil,
            height: direction == .horizontal ? 4 : nil
        )
        .contentShape(Rectangle()) // Hit target is the full 4px
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
                        // Capture the current first-child size from the ratio.
                        let currentRatio = readCurrentRatio()
                        startOffset = totalSize * currentRatio
                        lastNotifiedSize = Int(startOffset)
                    }
                    // Compute the first child's new pixel size from the drag.
                    let translation: CGFloat
                    if direction == .vertical {
                        translation = value.translation.width
                    } else {
                        translation = value.translation.height
                    }
                    let dividerPx: CGFloat = 4
                    let available = totalSize - dividerPx
                    // Loose UI clamp to prevent dragging off-screen.
                    // MoonBit applies the authoritative min/max ratio constraint.
                    let firstSize = min(max(startOffset + translation, 20), available - 20)
                    let firstSizeInt = Int(firstSize)

                    // Only notify if meaningfully different
                    if abs(firstSizeInt - lastNotifiedSize) >= 1 {
                        lastNotifiedSize = firstSizeInt
                        tabManager.notifyDividerMoved(
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

    /// Read the current ratio from MoonBit's layout tree.
    private func readCurrentRatio() -> CGFloat {
        guard let layoutJson = tabManager.bridge.getLayout(),
              let node = LayoutTree.parse(json: layoutJson)
        else { return 0.5 }
        return findRatio(in: node, panelId: panelId) ?? 0.5
    }

    /// Find the split ratio whose first child contains the given panelId.
    private func findRatio(in node: LayoutTree, panelId: Int32) -> CGFloat? {
        switch node {
        case .leaf: return nil
        case .split(_, let ratio, let first, let second):
            if LayoutTree.firstLeafId(first) == panelId {
                return ratio
            }
            return findRatio(in: first, panelId: panelId)
                ?? findRatio(in: second, panelId: panelId)
        }
    }
}
