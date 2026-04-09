import AppKit
import CoreGraphics

/// Debug scenario runner for Chrome/VSCode-like tab drag/drop behaviors.
///
/// Launch with:
///   swift run HelloTTY --debug-scenario tab-dnd
final class TabDragDropScenarioRunner {
    enum Mode {
        case full
        case tabDragStartOnly
    }

    private let appDelegate: AppDelegate
    private let tabManager: TabManager
    private let mode: Mode
    private var failures: [String] = []
    private var checks = 0

    init(appDelegate: AppDelegate, tabManager: TabManager, mode: Mode = .full) {
        self.appDelegate = appDelegate
        self.tabManager = tabManager
        self.mode = mode
    }

    func run() {
        NSLog("scenario(tab-dnd): starting mode=%@", String(describing: mode))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.bootstrap()
        }
    }

    private func bootstrap() {
        if tabManager.workspaces.isEmpty {
            _ = tabManager.newTab()
        }
        guard let primaryWorkspaceId = tabManager.primaryWindowContext.workspaceId ?? tabManager.workspaces.first?.workspaceId else {
            fail("bootstrap: no workspace available")
            reportAndExit()
            return
        }
        if mode == .tabDragStartOnly {
            scenario8_systemMouseDragStartsFromTabButton(primaryWorkspaceId: primaryWorkspaceId)
            return
        }
        scenario1_refuseDetachLastTab(primaryWorkspaceId: primaryWorkspaceId)
    }

    private func scenario1_refuseDetachLastTab(primaryWorkspaceId: Int32) {
        guard let onlyTab = tabManager.selectedTab(in: primaryWorkspaceId) else {
            fail("scenario1: no selected tab in primary workspace")
            reportAndExit()
            return
        }
        let outcome = dragTabOutsideApplication(tabId: onlyTab.tabId)
        if outcome != .none || tabManager.workspaces.count != 1 {
            fail("scenario1: detached the last tab in a workspace")
        } else {
            pass("scenario1: last tab cannot be detached into a new window")
        }
        advance(after: 0.4) {
            self.scenario2_reorderWithinWindow(primaryWorkspaceId: primaryWorkspaceId)
        }
    }

    private func scenario2_reorderWithinWindow(primaryWorkspaceId: Int32) {
        _ = tabManager.newTab(in: primaryWorkspaceId)
        advance(after: 0.4) {
            let tabsBefore = self.tabManager.tabs(in: primaryWorkspaceId)
            guard tabsBefore.count >= 2,
                  let draggedTab = tabsBefore.last
            else {
                self.fail("scenario2: failed to create a second tab for reorder")
                self.reportAndExit()
                return
            }
            guard let startFrame = self.tabManager.frameForTab(tabId: draggedTab.tabId) else {
                self.fail("scenario2: missing source tab frame for reorder")
                self.reportAndExit()
                return
            }
            let target = TabDragHoverTarget.tabInsertion(workspaceId: primaryWorkspaceId, index: 0)
            self.waitForDropTargetFrame(target, retries: 20) { targetFrame in
                let resolvedFrame = targetFrame ?? self.tabStripTargetFrame(for: primaryWorkspaceId, index: 0)
                // Drop near the LEFT edge of the tab bar so tabInsertionIndex resolves to 0.
                // midX of the whole bar could land past the first tab's midX → index 1 (no-op for tab 2).
                let dropX = resolvedFrame.minX + 10
                self.simulateObservedTabDrag(
                    from: CGPoint(x: startFrame.midX, y: startFrame.midY),
                    to: CGPoint(x: dropX, y: resolvedFrame.midY)
                ) {
                    self.advance(after: 0.6) {
                        let tabsAfter = self.tabManager.tabs(in: primaryWorkspaceId)
                        if tabsAfter.first?.tabId == draggedTab.tabId {
                            self.pass("scenario2: dragging inside one window reorders tabs in the existing strip")
                        } else {
                            self.fail("scenario2: expected reordered tabs, got tabs=\(tabsAfter.map(\.tabId))")
                        }
                        self.scenario3_detachWhenWorkspaceHasTwoTabs(primaryWorkspaceId: primaryWorkspaceId)
                    }
                }
            }
        }
    }

    private func scenario3_detachWhenWorkspaceHasTwoTabs(primaryWorkspaceId: Int32) {
        guard tabManager.tabs(in: primaryWorkspaceId).count >= 2,
              let draggedTab = tabManager.tabs(in: primaryWorkspaceId).last
        else {
            fail("scenario3: failed to create and detach a second tab")
            reportAndExit()
            return
        }
        let outcome = dragTabOutsideApplication(tabId: draggedTab.tabId)
        guard case .detached(let detachedWorkspaceId) = outcome else {
            fail("scenario3: expected detached outcome, got \(outcome)")
            reportAndExit()
            return
        }
        appDelegate.showDetachedWindow(
            for: detachedWorkspaceId,
            near: detachedWindowPoint(relativeTo: primaryWorkspaceId)
        )
        advance(after: 0.6) {
            let detachedTabs = self.tabManager.tabs(in: detachedWorkspaceId)
            let primaryTabs = self.tabManager.tabs(in: primaryWorkspaceId)
            let visibleWindows = self.visibleWorkspaceWindows()
            let detachedWindowVisible = self.workspaceWindow(for: detachedWorkspaceId)?.isVisible == true
                && self.workspaceWindow(for: detachedWorkspaceId)?.contentViewController != nil
            if detachedTabs.count == 1 && primaryTabs.count == 1 && visibleWindows.count >= 2 && detachedWindowVisible {
                self.pass("scenario3: drag-out policy creates a second window only after the workspace has 2+ tabs")
            } else {
                self.fail("scenario3: expected 2 visible single-tab workspaces/windows, got primary=\(primaryTabs.count) detached=\(detachedTabs.count) visibleWindows=\(visibleWindows.count) detachedVisible=\(detachedWindowVisible)")
            }
            self.scenario4_attachSingleTabWindowAsTab(primaryWorkspaceId: primaryWorkspaceId, detachedWorkspaceId: detachedWorkspaceId)
        }
    }

    private func scenario4_attachSingleTabWindowAsTab(primaryWorkspaceId: Int32, detachedWorkspaceId: Int32) {
        guard let detachedTab = tabManager.tabs(in: detachedWorkspaceId).first else {
            fail("scenario4: detached workspace has no tab to attach")
            reportAndExit()
            return
        }
        advance(after: 0.6) {
            guard self.tabManager.frameForTab(tabId: detachedTab.tabId) != nil else {
                self.fail("scenario4: missing detached tab frame")
                self.reportAndExit()
                return
            }
            let target = TabDragHoverTarget.tabInsertion(workspaceId: primaryWorkspaceId, index: 1)
            guard let targetFrame = self.dropTargetFrame(
                for: target,
                fallback: self.tabStripTargetFrame(for: primaryWorkspaceId, index: 1)
            ) else {
                self.fail("scenario4: missing tab strip target frame")
                self.reportAndExit()
                return
            }
            let outcome = self.dragTab(
                tabId: detachedTab.tabId,
                to: target,
                frame: targetFrame,
                id: "scenario4-tab-strip-target"
            )
            self.appDelegate.syncWorkspaceWindows()
            self.advance(after: 0.8) {
                let workspaces = self.tabManager.workspaces
                let primaryTabs = self.tabManager.tabs(in: primaryWorkspaceId)
                if outcome == .attached(workspaceId: primaryWorkspaceId)
                    && workspaces.count == 1
                    && primaryTabs.count == 2 {
                    self.pass("scenario4: dragging a single-tab window onto another window's tab strip merges as tabs")
                } else {
                    self.fail("scenario4: expected one workspace with two tabs, got outcome=\(outcome) workspaces=\(workspaces.count) tabs=\(primaryTabs.count)")
                }
                self.scenario5_mergeSingleTabWindowIntoPanel(primaryWorkspaceId: primaryWorkspaceId)
            }
        }
    }

    private func scenario5_mergeSingleTabWindowIntoPanel(primaryWorkspaceId: Int32) {
        guard let detachedCandidate = tabManager.tabs(in: primaryWorkspaceId).last,
              case .detached(let detachedWorkspaceId) = dragTabOutsideApplication(tabId: detachedCandidate.tabId)
        else {
            fail("scenario5: failed to recreate a second single-tab window")
            reportAndExit()
            return
        }
        appDelegate.showDetachedWindow(
            for: detachedWorkspaceId,
            near: detachedWindowPoint(relativeTo: primaryWorkspaceId)
        )
        advance(after: 0.6) {
            guard let targetTab = self.tabManager.tabs(in: primaryWorkspaceId).first,
                  targetTab.panels.first != nil,
                  let detachedTab = self.tabManager.tabs(in: detachedWorkspaceId).first
            else {
                self.fail("scenario5: missing target panel or detached tab")
                self.reportAndExit()
                return
            }
            self.tabManager.selectTab(targetTab, in: primaryWorkspaceId)
            self.advance(after: 0.4) {
                guard self.tabManager.frameForTab(tabId: detachedTab.tabId) != nil else {
                    self.fail("scenario5: missing detached tab frame")
                    self.reportAndExit()
                    return
                }
                let target = TabDragHoverTarget.workspaceContent(workspaceId: primaryWorkspaceId)
                self.waitForDropTargetFrame(target, retries: 20) { targetFrame in
                    guard let targetFrame else {
                        self.fail("scenario5: missing workspace content target frame")
                        self.reportAndExit()
                        return
                    }
                    let outcome = self.dragTab(
                        tabId: detachedTab.tabId,
                        to: target,
                        frame: targetFrame,
                        id: "scenario5-panel-target"
                    )
                    self.appDelegate.syncWorkspaceWindows()
                    self.advance(after: 0.8) {
                        let tabs = self.tabManager.tabs(in: primaryWorkspaceId)
                        let panelCount = self.tabManager.selectedTab(in: primaryWorkspaceId)?.panels.count ?? 0
                        if outcome == .merged(workspaceId: primaryWorkspaceId, panelId: self.tabManager.selectedTab(in: primaryWorkspaceId)?.panels.first?.panelId ?? -1)
                            || (self.tabManager.workspaces.count == 1 && tabs.count == 1 && panelCount >= 2) {
                            self.pass("scenario5: dragging a single-tab window onto a panel merges as a panel split")
                        } else {
                            self.fail("scenario5: expected one tab with split panels, got outcome=\(outcome) workspaces=\(self.tabManager.workspaces.count) tabs=\(tabs.count) panels=\(panelCount)")
                        }
                        self.scenario6_mergeOneOfManyTabsIntoPanel(primaryWorkspaceId: primaryWorkspaceId)
                    }
                }
            }
        }
    }

    private func scenario6_mergeOneOfManyTabsIntoPanel(primaryWorkspaceId: Int32) {
        guard let baseTab = tabManager.selectedTab(in: primaryWorkspaceId) else {
            fail("scenario6: no base tab to receive panel drop")
            reportAndExit()
            return
        }
        let baseTabId = baseTab.tabId
        let basePanelCount = baseTab.panels.count
        _ = tabManager.newTab(in: primaryWorkspaceId)
        let droppedTab = tabManager.newTab(in: primaryWorkspaceId)
        tabManager.selectTab(baseTab, in: primaryWorkspaceId)
        guard let targetPanelId = tabManager.selectedTab(in: primaryWorkspaceId)?.panels.first?.panelId else {
            fail("scenario6: missing target panel")
            reportAndExit()
            return
        }
        advance(after: 0.6) {
            guard let startFrame = self.tabManager.frameForTab(tabId: droppedTab.tabId) else {
                self.fail("scenario6: missing source tab frame")
                self.reportAndExit()
                return
            }
            let target = TabDragHoverTarget.panel(workspaceId: primaryWorkspaceId, panelId: targetPanelId)
            self.waitForDropTargetFrame(target, retries: 20) { targetFrame in
                guard let targetFrame else {
                    self.fail("scenario6: missing panel target frame")
                    self.reportAndExit()
                    return
                }
                self.simulateObservedTabDrag(
                    from: CGPoint(x: startFrame.midX, y: startFrame.midY),
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                ) {
                    self.advance(after: 0.8) {
                    let tabs = self.tabManager.tabs(in: primaryWorkspaceId)
                    let mergedTab = self.tabManager.tab(for: baseTabId)
                    let mergedPanelCount = mergedTab?.panels.count ?? 0
                    if tabs.count == 2 && mergedPanelCount == basePanelCount + 1 {
                        self.pass("scenario6: dragging one of multiple tabs onto a panel keeps the workspace and expands the target tab as a split")
                    } else {
                        self.fail("scenario6: expected two tabs and one extra panel on the target tab, got outcome=\(self.appDelegate.lastTabDragOutcome) tabs=\(tabs.count) panels=\(mergedPanelCount)")
                    }
                    self.scenario7_realUIDragOutCreatesDetachedWindow(primaryWorkspaceId: primaryWorkspaceId)
                }
            }
        }
        }
    }

    private func scenario7_realUIDragOutCreatesDetachedWindow(primaryWorkspaceId: Int32) {
        let tabsBefore = tabManager.tabs(in: primaryWorkspaceId)
        if tabsBefore.count < 2 {
            _ = tabManager.newTab(in: primaryWorkspaceId)
        }
        advance(after: 0.6) {
            let tabs = self.tabManager.tabs(in: primaryWorkspaceId)
            guard tabs.count >= 2, let draggedTab = tabs.last else {
                self.fail("scenario7: failed to prepare a second tab for real UI drag-out")
                self.reportAndExit()
                return
            }
            guard let startFrame = self.tabManager.frameForTab(tabId: draggedTab.tabId) else {
                self.fail("scenario7: missing on-screen frame for dragged tab")
                self.reportAndExit()
                return
            }
            self.simulateObservedTabDrag(
                from: CGPoint(x: startFrame.midX, y: startFrame.midY),
                to: self.outsideApplicationPoint()
            ) {
                self.advance(after: 1.0) {
                    let visibleWindows = self.visibleWorkspaceWindows()
                    let workspaceCount = self.tabManager.workspaces.count
                    let newestWindowVisible = self.visibleWorkspaceWindows().count >= 2
                    if newestWindowVisible && workspaceCount >= 2 {
                        self.pass("scenario7: real UI drag-out creates a detached window")
                    } else {
                        self.fail("scenario7: expected a visible detached window after real UI drag-out, got workspaces=\(workspaceCount) visibleWindows=\(visibleWindows.count)")
                    }
                    self.scenario8_systemMouseDragStartsFromTabButton(primaryWorkspaceId: primaryWorkspaceId)
                }
            }
        }
    }

    private func scenario8_systemMouseDragStartsFromTabButton(primaryWorkspaceId: Int32) {
        resetToSingleWindow(primaryWorkspaceId: primaryWorkspaceId)
        if tabManager.tabs(in: primaryWorkspaceId).count < 2 {
            _ = tabManager.newTab(in: primaryWorkspaceId)
        }
        advance(after: 0.8) {
            self.appDelegate.resetDebugTabDragSignals()
            self.flushWorkspaceWindowLayouts()
            let tabs = self.tabManager.tabs(in: primaryWorkspaceId)
            guard tabs.count >= 2, let draggedTab = tabs.last else {
                self.fail("scenario8: failed to prepare tabs for system drag-start")
                self.reportAndExit()
                return
            }
            // Wait for the TabMouseInteractionView to register itself in AppDelegate's registry.
            // This is the reliable path: direct dispatch to the view bypasses CGEvent routing issues.
            self.waitForTabInteractionView(tabId: draggedTab.tabId, retries: 30) { hasView in
                guard hasView else {
                    self.fail("scenario8: TabMouseInteractionView for tabId=\(draggedTab.tabId) not registered after waiting")
                    self.reportAndExit()
                    return
                }
                // Resolve screen-space coordinates for the drag.
                // tabManager.frameForTab returns a screen-space rect (set by reportFrame via convertToScreen).
                // directDispatchTabDrag converts screen → window → view internally.
                let frame = self.tabManager.frameForTab(tabId: draggedTab.tabId)
                guard let frame, frame.width > 4, frame.height > 4 else {
                    self.fail("scenario8: tab frame not available for tabId=\(draggedTab.tabId)")
                    self.reportAndExit()
                    return
                }
                let start = CGPoint(x: frame.midX, y: frame.midY)
                let end = CGPoint(x: start.x + 48, y: start.y)
                self.appDelegate.directDispatchTabDrag(
                    tabId: draggedTab.tabId,
                    from: start,
                    to: end,
                    steps: 12
                ) { success in
                    guard success else {
                        self.fail("scenario8: directDispatchTabDrag failed — view may have been deallocated")
                        self.reportAndExit()
                        return
                    }
                    self.advance(after: 0.4) {
                        if self.appDelegate.debugLastBeginObservedTabDragTabId == draggedTab.tabId,
                           self.appDelegate.debugObservedTabDragStartCount > 0 {
                            self.pass("scenario8: direct-dispatch drag starts from the tab button itself")
                            self.scenario9_systemMouseDragOutCreatesDetachedWindow(primaryWorkspaceId: primaryWorkspaceId)
                        } else {
                            self.fail("scenario8: drag did not start from the tab button, got startedTab=\(String(describing: self.appDelegate.debugLastBeginObservedTabDragTabId)) startCount=\(self.appDelegate.debugObservedTabDragStartCount) mouseDown=\(self.appDelegate.debugTabMouseDownCount) mouseDragged=\(self.appDelegate.debugTabMouseDraggedCount) mouseUp=\(self.appDelegate.debugTabMouseUpCount) panBegan=\(self.appDelegate.debugTabPanBeganCount) panChanged=\(self.appDelegate.debugTabPanChangedCount) panEnded=\(self.appDelegate.debugTabPanEndedCount)")
                            self.reportAndExit()
                        }
                    }
                }
            }
        }
    }

    private func waitForTabInteractionView(
        tabId: Int32,
        retries: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if appDelegate.tabInteractionView(for: tabId) != nil {
            completion(true)
            return
        }
        guard retries > 0 else {
            NSLog("scenario8: waitForTabInteractionView giving up tabId=%d registeredTabIds=%@", tabId, appDelegate.debugRegisteredTabInteractionViewIds() as CVarArg)
            completion(false)
            return
        }
        advance(after: 0.05) {
            self.waitForTabInteractionView(tabId: tabId, retries: retries - 1, completion: completion)
        }
    }

    private func scenario9_systemMouseDragOutCreatesDetachedWindow(primaryWorkspaceId: Int32) {
        resetToSingleWindow(primaryWorkspaceId: primaryWorkspaceId)
        if tabManager.tabs(in: primaryWorkspaceId).count < 2 {
            _ = tabManager.newTab(in: primaryWorkspaceId)
        }
        advance(after: 0.8) {
            self.appDelegate.resetDebugTabDragSignals()
            self.flushWorkspaceWindowLayouts()
            let tabs = self.tabManager.tabs(in: primaryWorkspaceId)
            guard tabs.count >= 2, let draggedTab = tabs.last else {
                self.fail("scenario9: failed to prepare tabs for direct drag-out")
                self.reportAndExit()
                return
            }
            self.waitForTabInteractionView(tabId: draggedTab.tabId, retries: 30) { hasView in
                guard hasView else {
                    self.fail("scenario9: TabMouseInteractionView for tabId=\(draggedTab.tabId) not registered")
                    self.reportAndExit()
                    return
                }
                guard let frame = self.tabManager.frameForTab(tabId: draggedTab.tabId),
                      frame.width > 4, frame.height > 4 else {
                    self.fail("scenario9: tab frame not available for tabId=\(draggedTab.tabId)")
                    self.reportAndExit()
                    return
                }
                let start = CGPoint(x: frame.midX, y: frame.midY)
                let end = self.outsideVisibleWindowPoint(relativeTo: primaryWorkspaceId)
                self.appDelegate.directDispatchTabDrag(
                    tabId: draggedTab.tabId,
                    from: start,
                    to: end,
                    steps: 16
                ) { success in
                    guard success else {
                        self.fail("scenario9: directDispatchTabDrag failed")
                        self.reportAndExit()
                        return
                    }
                    self.advance(after: 1.0) {
                        let visibleWindows = self.visibleWorkspaceWindows()
                        let workspaceCount = self.tabManager.workspaces.count
                        if visibleWindows.count >= 2 && workspaceCount >= 2 {
                            self.pass("scenario9: direct-dispatch drag-out creates a visible detached window")
                        } else {
                            self.fail("scenario9: expected drag-out to create a visible detached window, got startedTab=\(String(describing: self.appDelegate.debugLastBeginObservedTabDragTabId)) startCount=\(self.appDelegate.debugObservedTabDragStartCount) outcome=\(self.appDelegate.lastTabDragOutcome) dragState=\(String(describing: self.tabManager.tabDragState)) workspaces=\(workspaceCount) visibleWindows=\(visibleWindows.count)")
                        }
                        self.reportAndExit()
                    }
                }
            }
        }
    }

    private func workspaceWindowCount() -> Int {
        workspaceWindows().count
    }

    private func workspaceWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "workspace-primary" || raw.hasPrefix("workspace-")
        }
    }

    private func visibleWorkspaceWindows() -> [NSWindow] {
        workspaceWindows().filter { window in
            window.isVisible && !window.isMiniaturized && window.contentViewController != nil
        }
    }

    private func advance(after delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    private func dragTabOutsideApplication(tabId: Int32) -> TabDragDropOutcome {
        tabManager.beginTabDrag(tabId: tabId)
        return tabManager.finishTabDrag(screenPoint: outsideApplicationPoint())
    }

    private func dragTab(
        tabId: Int32,
        to target: TabDragHoverTarget,
        frame: CGRect,
        id: String
    ) -> TabDragDropOutcome {
        tabManager.registerDropTarget(id: id, target: target, frame: frame)
        tabManager.beginTabDrag(tabId: tabId)
        let outcome = tabManager.finishTabDrag(screenPoint: CGPoint(x: frame.midX, y: frame.midY))
        tabManager.unregisterDropTarget(id: id)
        return outcome
    }

    private func outsideApplicationPoint() -> CGPoint {
        CGPoint(x: -4096, y: -4096)
    }

    private func simulateObservedTabDrag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int = 12,
        completion: @escaping () -> Void
    ) {
        appDelegate.debugTabPointerDown(at: start)
        guard steps >= 2 else {
            appDelegate.debugTabPointerUp(at: end)
            completion()
            return
        }

        var points: [CGPoint] = []
        for step in 1..<(steps - 1) {
            let t = CGFloat(step) / CGFloat(steps - 1)
            points.append(CGPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            ))
        }
        runObservedDragPoints(points, end: end, completion: completion)
    }

    private func runObservedDragPoints(
        _ points: [CGPoint],
        end: CGPoint,
        index: Int = 0,
        completion: @escaping () -> Void
    ) {
        guard index < points.count else {
            appDelegate.debugTabPointerUp(at: end)
            completion()
            return
        }
        appDelegate.debugTabPointerDragged(to: points[index])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.runObservedDragPoints(points, end: end, index: index + 1, completion: completion)
        }
    }

    private func simulateSystemMouseDrag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int = 16,
        completion: @escaping (Bool) -> Void
    ) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            completion(false)
            return
        }

        func post(_ type: CGEventType, point: CGPoint) -> Bool {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return false
            }
            event.post(tap: .cgSessionEventTap)
            return true
        }

        guard post(.mouseMoved, point: start),
              post(.leftMouseDown, point: start)
        else {
            completion(false)
            return
        }

        let interpolated = (1...steps).map { step -> CGPoint in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            )
        }

        runSystemDragPoints(interpolated, finalPoint: end, post: post, completion: completion)
    }

    private func runSystemDragPoints(
        _ points: [CGPoint],
        finalPoint: CGPoint,
        index: Int = 0,
        post: @escaping (CGEventType, CGPoint) -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < points.count else {
            completion(post(.leftMouseUp, finalPoint))
            return
        }
        let ok = post(.leftMouseDragged, points[index])
        guard ok else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.runSystemDragPoints(points, finalPoint: finalPoint, index: index + 1, post: post, completion: completion)
        }
    }

    private func resetToSingleWindow(primaryWorkspaceId: Int32) {
        let extraWorkspaceIds = tabManager.workspaces.map(\.workspaceId).filter { $0 != primaryWorkspaceId }
        for workspaceId in extraWorkspaceIds {
            let tabs = tabManager.tabs(in: workspaceId)
            for tab in tabs.reversed() {
                tabManager.attachTab(tabId: tab.tabId, to: primaryWorkspaceId, targetIndex: tabManager.tabs(in: primaryWorkspaceId).count)
            }
        }
        appDelegate.syncWorkspaceWindows()
    }

    private func dropTargetFrame(for target: TabDragHoverTarget, fallback: CGRect) -> CGRect? {
        tabManager.frameForDropTarget(target) ?? fallback
    }

    private func waitForDropTargetFrame(
        _ target: TabDragHoverTarget,
        retries: Int = 10,
        completion: @escaping (CGRect?) -> Void
    ) {
        if let frame = tabManager.frameForDropTarget(target),
           frame.width > 10,
           frame.height > 10 {
            completion(frame)
            return
        }
        guard retries > 0 else {
            completion(nil)
            return
        }
        advance(after: 0.1) {
            self.waitForDropTargetFrame(target, retries: retries - 1, completion: completion)
        }
    }

    private func tabStripTargetFrame(for workspaceId: Int32, index: Int) -> CGRect {
        guard let window = workspaceWindow(for: workspaceId) else {
            return CGRect(x: 120 + (index * 40), y: 700, width: 32, height: 28)
        }
        return CGRect(
            x: window.frame.minX + 100 + CGFloat(index * 40),
            y: window.frame.maxY - 42,
            width: 28,
            height: 28
        )
    }

    private func panelTargetFrame(for workspaceId: Int32) -> CGRect {
        guard let window = workspaceWindow(for: workspaceId) else {
            return CGRect(x: 240, y: 240, width: 300, height: 220)
        }
        return CGRect(
            x: window.frame.minX + 80,
            y: window.frame.minY + 80,
            width: max(window.frame.width - 160, 160),
            height: max(window.frame.height - 160, 160)
        )
    }

    private func detachedWindowPoint(relativeTo workspaceId: Int32) -> CGPoint {
        guard let window = workspaceWindow(for: workspaceId) else {
            return CGPoint(x: 1400, y: 800)
        }
        return CGPoint(
            x: window.frame.maxX + 420,
            y: window.frame.midY
        )
    }

    private func outsideVisibleWindowPoint(relativeTo workspaceId: Int32) -> CGPoint {
        guard let window = workspaceWindow(for: workspaceId) else {
            return CGPoint(x: 40, y: 40)
        }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let rightPoint = CGPoint(x: min(window.frame.maxX + 80, visible.maxX - 40), y: window.frame.midY)
        if !window.frame.contains(rightPoint) {
            return rightPoint
        }

        let leftPoint = CGPoint(x: max(window.frame.minX - 80, visible.minX + 40), y: window.frame.midY)
        if !window.frame.contains(leftPoint) {
            return leftPoint
        }

        let belowPoint = CGPoint(x: window.frame.midX, y: max(window.frame.minY - 80, visible.minY + 40))
        if !window.frame.contains(belowPoint) {
            return belowPoint
        }

        return CGPoint(x: visible.minX + 40, y: visible.minY + 40)
    }

    private func workspaceWindow(for workspaceId: Int32) -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == "workspace-\(workspaceId)"
                || (workspaceId == tabManager.primaryWindowContext.workspaceId
                    && window.identifier?.rawValue == "workspace-primary")
        }
    }

    private func flushWorkspaceWindowLayouts() {
        for window in visibleWorkspaceWindows() {
            window.contentView?.layoutSubtreeIfNeeded()
            for accessory in window.titlebarAccessoryViewControllers {
                accessory.view.layoutSubtreeIfNeeded()
            }
            window.displayIfNeeded()
        }
    }

    private func pass(_ message: String) {
        checks += 1
        NSLog("scenario(tab-dnd): PASS — %@", message)
        print("SCENARIO PASS: \(message)")
    }

    private func fail(_ message: String) {
        checks += 1
        failures.append(message)
        NSLog("scenario(tab-dnd): FAIL — %@", message)
        print("SCENARIO FAIL: \(message)")
    }

    private func reportAndExit() {
        if failures.isEmpty {
            NSLog("scenario(tab-dnd): ALL PASSED (%d checks)", checks)
            print("SCENARIO(tab-dnd): ALL PASSED")
            exit(0)
        } else {
            NSLog("scenario(tab-dnd): %d FAILURES", failures.count)
            print("SCENARIO(tab-dnd): \(failures.count) FAILURES")
            exit(1)
        }
    }

    private func waitForTabFrame(
        tabId: Int32,
        retries: Int = 10,
        completion: @escaping (CGRect?) -> Void
    ) {
        if let frame = tabManager.frameForTab(tabId: tabId) {
            completion(frame)
            return
        }
        guard retries > 0 else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.waitForTabFrame(tabId: tabId, retries: retries - 1, completion: completion)
        }
    }
}
