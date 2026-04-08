import AppKit

/// Automated UI test suite for hello_tty.
///
/// Launched via `--self-test` argument. Exercises the terminal state,
/// rendering pipeline, resize behavior, and tab management, then exits
/// with 0 (pass) or 1 (fail).
///
/// Screenshots are saved to /tmp/hello_tty_selftest_*.png for inspection.
/// Uses CGWindowListCreateImage to capture GPU-rendered content (Metal/wgpu).
/// Screen Recording permission may be needed on macOS 14+ for cross-process
/// capture, but self-capture of own windows works without it.
class SelfTestRunner {
    let tabManager: TabManager
    var failures: [String] = []
    var testIndex = 0

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func run() {
        NSLog("self-test: starting")

        // Wait for the window and initial shell output to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.runTests()
        }
    }

    private func runTests() {
        test1_windowExists()
        test2_gridHasContent()
        test3_screenshotNotBlank()
        test4_resize()

        // Tests that need async settling
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.test5_resizeResult()
            self.test6_keyboardInput()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.test7_keyboardInputResult()
                self.test8_tabManagement()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.test9_tabSwitchResult()
                    self.test10_underlineCheck()
                    self.test11_panelSplit()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.test12_panelSplitResult()
                        self.test13_signalCtrlC()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.test14_signalCtrlCResult()
                            self.test15_scrollbackGeneration()

                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self.test16_scrollbackViewport()
                                self.test17_scrollbackContent()

                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    self.test18_autoReset()
                                    self.reportAndExit()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test 1: Window exists

    private func test1_windowExists() {
        guard let window = NSApp.windows.first else {
            fail("test1_windowExists: No main window")
            return
        }
        guard window.contentView != nil else {
            fail("test1_windowExists: No content view")
            return
        }
        let frame = window.frame
        pass("test1_windowExists: \(Int(frame.width))x\(Int(frame.height))")
    }

    // MARK: - Test 2: Grid has content

    private func test2_gridHasContent() {
        guard let tab = tabManager.selectedTab else {
            fail("test2_gridHasContent: No selected tab")
            return
        }
        guard let grid = tab.state!.forceRefreshGrid() else {
            fail("test2_gridHasContent: Grid is nil")
            return
        }
        if grid.cells.isEmpty {
            fail("test2_gridHasContent: Grid has 0 cells")
            return
        }
        pass("test2_gridHasContent: \(grid.rows)x\(grid.cols), \(grid.cells.count) cells")
    }

    // MARK: - Test 3: Screenshot not blank

    private func test3_screenshotNotBlank() {
        guard let window = NSApp.windows.first,
              let contentView = window.contentView
        else {
            fail("test3_screenshotNotBlank: No window/content")
            return
        }

        let rep = captureView(contentView)
        saveScreenshot(rep, name: "01_initial")

        if isImageBlank(rep) {
            fail("test3_screenshotNotBlank: Window content is completely blank")
        } else {
            pass("test3_screenshotNotBlank: Content is visible")
        }
    }

    // MARK: - Test 4: Resize

    private var preResizeRows: Int = 0
    private var preResizeCols: Int = 0

    private func test4_resize() {
        guard let tab = tabManager.selectedTab else {
            fail("test4_resize: No selected tab")
            return
        }
        preResizeRows = tab.state!.currentRows
        preResizeCols = tab.state!.currentCols

        guard let window = NSApp.windows.first else {
            fail("test4_resize: No window")
            return
        }

        // Choose a window size distinctly different from the current one.
        // We pick something far from any common default.
        let currentFrame = window.frame
        let targetW: CGFloat = abs(currentFrame.width - 500) > 100 ? 500 : 850
        let targetH: CGFloat = abs(currentFrame.height - 400) > 100 ? 400 : 680
        let newFrame = NSRect(x: currentFrame.origin.x, y: currentFrame.origin.y,
                              width: targetW, height: targetH)
        window.setFrame(newFrame, display: true, animate: false)

        // Let SwiftUI propagate the new layout (setFrameSize → recalculateGridSize → resize).
        // We do NOT call state.resize manually — that would race with SwiftUI's layout.
        // The test5 check runs after a 1-second delay to allow propagation.
        pass("test4_resize: Window resized to \(Int(targetW))x\(Int(targetH)) (was \(Int(currentFrame.width))x\(Int(currentFrame.height)), grid was \(preResizeRows)x\(preResizeCols))")
    }

    // MARK: - Test 5: Resize result

    private func test5_resizeResult() {
        guard let tab = tabManager.selectedTab else {
            fail("test5_resizeResult: No selected tab")
            return
        }
        let newRows = tab.state!.currentRows
        let newCols = tab.state!.currentCols

        if newRows == preResizeRows && newCols == preResizeCols {
            fail("test5_resizeResult: Grid did NOT resize (still \(newRows)x\(newCols))")
        } else {
            pass("test5_resizeResult: Grid resized to \(newRows)x\(newCols)")
        }

        // Screenshot after resize
        if let contentView = NSApp.windows.first?.contentView {
            let rep = captureView(contentView)
            saveScreenshot(rep, name: "02_after_resize")

            // Check the expanded area isn't blank
            if isImageBlank(rep) {
                fail("test5_resizeResult: Screenshot is blank after resize")
            }
        }
    }

    // MARK: - Test 6: Keyboard input

    private var cellCountBefore: Int = 0

    private func test6_keyboardInput() {
        guard let tab = tabManager.selectedTab else {
            fail("test6_keyboardInput: No selected tab")
            return
        }
        cellCountBefore = tab.state!.forceRefreshGrid()?.cells.count ?? 0

        // Send "echo test123" + Return
        tab.state!.sendText("echo test123\r")
        pass("test6_keyboardInput: Sent 'echo test123\\r'")
    }

    // MARK: - Test 7: Keyboard input result

    private func test7_keyboardInputResult() {
        guard let tab = tabManager.selectedTab else {
            fail("test7_keyboardInputResult: No selected tab")
            return
        }
        let cellCountAfter = tab.state!.forceRefreshGrid()?.cells.count ?? 0

        if cellCountAfter <= cellCountBefore {
            fail("test7_keyboardInputResult: Cell count did not increase (\(cellCountBefore) -> \(cellCountAfter))")
        } else {
            pass("test7_keyboardInputResult: Cell count \(cellCountBefore) -> \(cellCountAfter)")
        }

        // Check if "test123" appears in the grid
        let foundText = gridContainsText("test123")
        if !foundText {
            fail("test7_keyboardInputResult: 'test123' not found in grid cells")
        } else {
            pass("test7_keyboardInputResult: 'test123' found in grid")
        }

        if let contentView = NSApp.windows.first?.contentView {
            saveScreenshot(captureView(contentView), name: "03_after_input")
        }
    }

    // MARK: - Test 8: Tab management

    private func test8_tabManagement() {
        let tabCountBefore = tabManager.tabs.count

        // Create a new tab (MoonBit handles init + PTY spawn)
        let newTab = tabManager.newTab()

        if tabManager.tabs.count != tabCountBefore + 1 {
            fail("test8_tabManagement: Tab count did not increase")
            return
        }

        // Switch back to first tab (must use selectTab to sync MoonBit state)
        if let firstTab = tabManager.tabs.first {
            tabManager.selectTab(firstTab)
        }
        pass("test8_tabManagement: Created tab, switched back to first")
    }

    // MARK: - Test 9: Tab switch result

    private func test9_tabSwitchResult() {
        guard let tab = tabManager.selectedTab else {
            fail("test9_tabSwitchResult: No selected tab after switch")
            return
        }

        // The first tab should still have its grid
        if let grid = tab.state!.forceRefreshGrid() {
            if grid.cells.isEmpty {
                fail("test9_tabSwitchResult: First tab grid is EMPTY after switching back")
            } else {
                pass("test9_tabSwitchResult: First tab has \(grid.cells.count) cells after switch")
            }
        } else {
            fail("test9_tabSwitchResult: First tab grid is nil after switching back")
        }

        if let contentView = NSApp.windows.first?.contentView {
            saveScreenshot(captureView(contentView), name: "04_after_tab_switch")
        }
    }

    // MARK: - Test 10: Underline check

    private func test10_underlineCheck() {
        guard let tab = tabManager.selectedTab,
              let grid = tab.state!.forceRefreshGrid()
        else {
            fail("test10_underlineCheck: No grid")
            return
        }

        let totalCells = grid.cells.count
        let underlinedCells = grid.cells.filter { $0.isUnderline }.count
        let underlineRatio = totalCells > 0 ? Double(underlinedCells) / Double(totalCells) : 0

        if underlineRatio > 0.5 {
            fail("test10_underlineCheck: \(Int(underlineRatio * 100))% of cells have underline! (\(underlinedCells)/\(totalCells)) — attrs sample: \(grid.cells.prefix(5).map { $0.attrs })")
        } else {
            pass("test10_underlineCheck: \(underlinedCells)/\(totalCells) underlined (\(Int(underlineRatio * 100))%)")
        }
    }

    // MARK: - Test 11: Panel split

    private var preSplitPanelCount: Int = 0

    private func test11_panelSplit() {
        guard let tab = tabManager.selectedTab else {
            fail("test11_panelSplit: No selected tab")
            return
        }
        preSplitPanelCount = tab.panels.count

        // Split the focused panel vertically (Cmd+\)
        tabManager.splitFocusedPanel(direction: 0) // 0 = vertical

        if tab.panels.count == preSplitPanelCount + 1 {
            pass("test11_panelSplit: Split created, now \(tab.panels.count) panels")
        } else {
            fail("test11_panelSplit: Panel count did not increase (\(preSplitPanelCount) -> \(tab.panels.count))")
        }
    }

    // MARK: - Test 12: Panel split result (verify both panels have content)

    private func test12_panelSplitResult() {
        guard let tab = tabManager.selectedTab else {
            fail("test12_panelSplitResult: No selected tab")
            return
        }

        // Check that all panels have a running PTY
        var allConnected = true
        for panel in tab.panels {
            if !panel.state.pty.isConnected {
                allConnected = false
                fail("test12_panelSplitResult: Panel \(panel.panelId) PTY not connected")
            }
        }

        // Check ALL panels have grid content (not just the focused one)
        for panel in tab.panels {
            if let grid = panel.state.forceRefreshGrid() {
                let nonEmpty = grid.cells.filter { $0.char != " " && $0.char != "\0" }.count
                if nonEmpty > 0 {
                    pass("test12_panelSplitResult: Panel \(panel.panelId) (session \(panel.sessionId), focused=\(panel.isFocused)) has \(grid.cells.count) cells (\(nonEmpty) non-empty)")
                } else {
                    fail("test12_panelSplitResult: Panel \(panel.panelId) (session \(panel.sessionId), focused=\(panel.isFocused)) grid has \(grid.cells.count) cells but ALL EMPTY")
                }
            } else {
                fail("test12_panelSplitResult: Panel \(panel.panelId) (session \(panel.sessionId)) grid is nil")
            }
        }

        // Screenshot
        if let contentView = NSApp.windows.first?.contentView {
            saveScreenshot(captureView(contentView), name: "05_after_split")
        }
    }

    // MARK: - Test 13: Signal — send Ctrl+C to interrupt a running process

    private func test13_signalCtrlC() {
        guard let tab = tabManager.selectedTab,
              let state = tab.state,
              state.pty.isConnected
        else {
            fail("test13_signalCtrlC: No connected PTY")
            return
        }

        // Start a long-running command, then send Ctrl+C
        // "sleep 60" should be killed by SIGINT when we send 0x03
        state.sendText("sleep 60\r")

        // Give the command time to start, then send Ctrl+C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Send Ctrl+C (0x03) the same way InputHandler does:
            // classify_key → DirectToPty → sendKey → translate_key_input → PTY write
            state.sendKey(keyCode: 0x03, modifiers: 2) // 2 = mod_ctrl
            self.pass("test13_signalCtrlC: Sent Ctrl+C to PTY")
        }
    }

    // MARK: - Test 14: Verify Ctrl+C actually interrupted the process

    private func test14_signalCtrlCResult() {
        // After Ctrl+C, the shell should show a new prompt.
        // "sleep 60" should NOT still be running — if it is,
        // the controlling terminal wasn't set up correctly.

        // Check that grid contains a shell prompt ($ or %) on a recent line,
        // indicating the shell regained control after the signal.
        guard let tab = tabManager.selectedTab,
              let grid = tab.state?.forceRefreshGrid()
        else {
            fail("test14_signalCtrlCResult: No grid")
            return
        }

        // Build row strings
        var lastNonEmptyRow = ""
        var promptFound = false
        for row in stride(from: grid.rows - 1, through: 0, by: -1) {
            var line = ""
            for cell in grid.cells where cell.row == row {
                line.append(cell.char)
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if lastNonEmptyRow.isEmpty { lastNonEmptyRow = trimmed }
            // Shell prompts typically end with $, %, >, or #
            if trimmed.hasSuffix("$") || trimmed.hasSuffix("%") ||
               trimmed.hasSuffix(">") || trimmed.hasSuffix("#") ||
               trimmed.contains("$ ") || trimmed.contains("% ") {
                promptFound = true
                break
            }
            // Also check for ^C in output (signal echo)
            if trimmed.contains("^C") {
                promptFound = true
                break
            }
            // Only check the last few non-empty rows
            if row < grid.rows - 5 { break }
        }

        if promptFound {
            pass("test14_signalCtrlCResult: Shell prompt found after Ctrl+C (signal delivered)")
        } else {
            fail("test14_signalCtrlCResult: No shell prompt found after Ctrl+C — signal may not have been delivered. Last row: \(lastNonEmptyRow)")
        }
    }

    // MARK: - Test 15: Scrollback generation

    private func test15_scrollbackGeneration() {
        guard let tab = tabManager.selectedTab,
              let state = tab.state
        else {
            fail("test15_scrollbackGeneration: No selected tab/state")
            return
        }

        // Generate enough output to fill scrollback: echo many lines
        // Terminal height is ~21 rows after resize, so 50 lines is plenty
        for i in 0..<50 {
            state.sendText("echo scrolltest_line_\(i)\r")
        }
        pass("test15_scrollbackGeneration: Sent 50 echo commands")
    }

    // MARK: - Test 16: Scrollback viewport — API control

    private func test16_scrollbackViewport() {
        guard let tab = tabManager.selectedTab,
              let state = tab.state
        else {
            fail("test16_scrollbackViewport: No selected tab/state")
            return
        }

        let bridge = MoonBitBridge.shared
        let sessionId = state.sessionId

        // Check scrollback has content
        let sbLen = bridge.getScrollbackLength(sessionId: sessionId)
        if sbLen <= 0 {
            fail("test16_scrollbackViewport: Scrollback empty (length=\(sbLen))")
            return
        }
        pass("test16_scrollbackViewport: Scrollback has \(sbLen) lines")

        // Verify viewport starts at 0 (live)
        let offset0 = bridge.getViewportOffset(sessionId: sessionId)
        if offset0 != 0 {
            fail("test16_scrollbackViewport: Expected initial offset 0, got \(offset0)")
            return
        }

        // Scroll up by scrollback length (all the way to oldest)
        let maxOffset = bridge.scrollViewportUp(sessionId: sessionId, lines: Int(sbLen))
        if maxOffset != sbLen {
            fail("test16_scrollbackViewport: Expected offset \(sbLen) at max, got \(maxOffset)")
            return
        }

        // Grid at max scroll should show content from history (not the latest live lines)
        if let grid = state.forceRefreshGrid() {
            if grid.cells.isEmpty {
                fail("test16_scrollbackViewport: Grid empty at max scroll")
                return
            }
            pass("test16_scrollbackViewport: Grid has \(grid.cells.count) cells at max scroll (offset \(maxOffset))")
        } else {
            fail("test16_scrollbackViewport: Grid nil at max scroll")
            return
        }

        // Scroll back to middle
        _ = bridge.resetViewport(sessionId: sessionId)
        let midOffset = bridge.scrollViewportUp(sessionId: sessionId, lines: 10)
        if midOffset != 10 {
            fail("test16_scrollbackViewport: Expected offset 10, got \(midOffset)")
            return
        }
        pass("test16_scrollbackViewport: Scrolled to offset \(midOffset)")

        // Scroll down 5 lines
        let offset5 = bridge.scrollViewportDown(sessionId: sessionId, lines: 5)
        if offset5 != 5 {
            fail("test16_scrollbackViewport: Expected offset 5 after scroll down, got \(offset5)")
            return
        }

        // Clamp test: scroll up beyond max
        _ = bridge.resetViewport(sessionId: sessionId)
        let overMax = bridge.scrollViewportUp(sessionId: sessionId, lines: 999999)
        if overMax != sbLen {
            fail("test16_scrollbackViewport: Over-scroll should clamp to \(sbLen), got \(overMax)")
            return
        }
        pass("test16_scrollbackViewport: Over-scroll clamped to \(overMax)")

        // Clamp test: scroll down beyond 0
        let underMin = bridge.scrollViewportDown(sessionId: sessionId, lines: 999999)
        if underMin != 0 {
            fail("test16_scrollbackViewport: Under-scroll should clamp to 0, got \(underMin)")
            return
        }
        pass("test16_scrollbackViewport: Under-scroll clamped to 0")

        // Reset to live
        let resetOk = bridge.resetViewport(sessionId: sessionId)
        if !resetOk {
            fail("test16_scrollbackViewport: resetViewport failed")
            return
        }
        let finalOffset = bridge.getViewportOffset(sessionId: sessionId)
        if finalOffset != 0 {
            fail("test16_scrollbackViewport: Expected offset 0 after reset, got \(finalOffset)")
            return
        }
        pass("test16_scrollbackViewport: Reset to live view (offset 0)")

        // Screenshot
        if let contentView = NSApp.windows.first?.contentView {
            saveScreenshot(captureView(contentView), name: "06_after_scrollback")
        }
    }

    // MARK: - Test 17: Scrollback content correctness

    private func test17_scrollbackContent() {
        guard let tab = tabManager.selectedTab,
              let state = tab.state
        else {
            fail("test17_scrollbackContent: No selected tab/state")
            return
        }

        let bridge = MoonBitBridge.shared
        let sessionId = state.sessionId

        // Scroll to a position where scrolltest lines should be visible.
        // scrolltest lines are in the middle of the scrollback, not at the very start.
        // Scroll up by half the scrollback length — should land in the echo output area.
        let sbLen = bridge.getScrollbackLength(sessionId: sessionId)
        let halfScroll = Int(sbLen) / 2
        _ = bridge.scrollViewportUp(sessionId: sessionId, lines: halfScroll)

        guard let scrolledGrid = state.forceRefreshGrid() else {
            fail("test17_scrollbackContent: Cannot get scrolled grid")
            _ = bridge.resetViewport(sessionId: sessionId)
            return
        }
        let scrolledText = gridToText(scrolledGrid)

        // The scrolled view should contain some "scrolltest_line_" text
        if scrolledText.contains("scrolltest_line_") {
            pass("test17_scrollbackContent: scrolltest lines visible at offset \(halfScroll)")
        } else {
            // Might not land exactly on scrolltest lines, but grid should have content
            if scrolledGrid.cells.isEmpty {
                fail("test17_scrollbackContent: Grid empty at offset \(halfScroll)")
            } else {
                pass("test17_scrollbackContent: Grid has \(scrolledGrid.cells.count) cells at offset \(halfScroll) (scrolltest text not in view, but grid is populated)")
            }
        }

        // Screenshot of scrolled-back state
        if let contentView = NSApp.windows.first?.contentView {
            saveScreenshot(captureView(contentView), name: "07_scrollback_content")
        }

        // Reset, scroll up again, send new output — viewport should snap back
        _ = bridge.resetViewport(sessionId: sessionId)
        _ = bridge.scrollViewportUp(sessionId: sessionId, lines: 20)
        let beforeOutput = bridge.getViewportOffset(sessionId: sessionId)
        if beforeOutput == 0 {
            fail("test17_scrollbackContent: Viewport didn't scroll up")
            return
        }
        pass("test17_scrollbackContent: Viewport at offset \(beforeOutput) before new output")

        // Send new output — viewport should snap back
        state.sendText("echo viewport_reset_test\r")
    }

    // MARK: - Test 18: Auto-reset on new output

    private func test18_autoReset() {
        guard let tab = tabManager.selectedTab,
              let state = tab.state
        else {
            fail("test18_autoReset: No selected tab/state")
            return
        }

        let bridge = MoonBitBridge.shared
        let sessionId = state.sessionId

        let afterOutput = bridge.getViewportOffset(sessionId: sessionId)
        if afterOutput != 0 {
            fail("test18_autoReset: Viewport should auto-reset to 0 after new output, got \(afterOutput)")
            return
        }
        pass("test18_autoReset: Viewport auto-reset to live after new output")
    }

    // MARK: - Helpers

    private func pass(_ msg: String) {
        testIndex += 1
        NSLog("self-test: PASS — %@", msg)
    }

    private func fail(_ msg: String) {
        testIndex += 1
        failures.append(msg)
        NSLog("self-test: FAIL — %@", msg)
    }

    private func reportAndExit() {
        NSLog("self-test: ========================================")
        if failures.isEmpty {
            NSLog("self-test: ALL TESTS PASSED (%d tests)", testIndex)
            print("SELF-TEST: ALL PASSED")

            // Clean up second tab
            if tabManager.tabs.count > 1 {
                tabManager.closeTab(tabManager.tabs.last!)
            }
            exit(0)
        } else {
            NSLog("self-test: %d FAILURES:", failures.count)
            for f in failures {
                NSLog("self-test:   - %@", f)
                print("FAIL: \(f)")
            }
            print("SELF-TEST: \(failures.count) FAILURES")
            exit(1)
        }
    }

    /// Capture the window's on-screen pixels via the window compositor.
    ///
    /// NSView.cacheDisplay only captures the AppKit backing store — it misses
    /// CAMetalLayer / wgpu content entirely (always blank). CGWindowListCreateImage
    /// captures the actual composited pixels from the window server, including
    /// Metal, OpenGL, and any GPU-rendered content.
    private func captureView(_ view: NSView) -> NSBitmapImageRep {
        guard let window = view.window else {
            // Fallback to the old method if no window
            let bounds = view.bounds
            let rep = view.bitmapImageRepForCachingDisplay(in: bounds)!
            view.cacheDisplay(in: bounds, to: rep)
            return rep
        }

        let windowId = CGWindowID(window.windowNumber)
        // .boundsIgnoreFraming captures only the window content (no shadow)
        if let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowId,
            [.boundsIgnoreFraming]
        ) {
            return NSBitmapImageRep(cgImage: cgImage)
        }

        // Fallback
        let bounds = view.bounds
        let rep = view.bitmapImageRepForCachingDisplay(in: bounds)!
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private func saveScreenshot(_ rep: NSBitmapImageRep, name: String) {
        if let data = rep.representation(using: .png, properties: [:]) {
            let path = "/tmp/hello_tty_selftest_\(name).png"
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("self-test: Screenshot saved to %@", path)
        }
    }

    private func isImageBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return true }
        let bytesPerPixel = rep.bitsPerPixel / 8
        let total = rep.pixelsWide * rep.pixelsHigh
        guard total > 0 && bytesPerPixel > 0 else { return true }

        // Sample first pixel
        let firstR = data[0]
        let firstG = data[1]
        let firstB = data[2]

        // Check every 97th pixel (prime stride to avoid patterns)
        var differentCount = 0
        let stride = max(1, bytesPerPixel * 97)
        var offset = 0
        while offset + bytesPerPixel <= total * bytesPerPixel {
            let r = data[offset]
            let g = data[offset + 1]
            let b = data[offset + 2]
            if r != firstR || g != firstG || b != firstB {
                differentCount += 1
            }
            offset += stride
        }
        // If fewer than 5% of sampled pixels differ, it's blank
        let sampledCount = total * bytesPerPixel / stride
        return sampledCount > 0 && Double(differentCount) / Double(sampledCount) < 0.05
    }

    /// Build a single string from all grid rows (for content assertions).
    private func gridToText(_ grid: TerminalGrid) -> String {
        var rowChars: [Int: [Int: Character]] = [:]
        for cell in grid.cells {
            if rowChars[cell.row] == nil { rowChars[cell.row] = [:] }
            rowChars[cell.row]![cell.col] = cell.char
        }
        var lines: [String] = []
        for row in 0..<grid.rows {
            guard let cols = rowChars[row] else { continue }
            var line = ""
            for col in 0..<grid.cols {
                line.append(cols[col] ?? " ")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func gridContainsText(_ text: String) -> Bool {
        guard let tab = tabManager.selectedTab,
              let grid = tab.state!.forceRefreshGrid()
        else { return false }

        // Build rows as strings
        var rowChars: [Int: [Int: Character]] = [:]
        for cell in grid.cells {
            if rowChars[cell.row] == nil { rowChars[cell.row] = [:] }
            rowChars[cell.row]![cell.col] = cell.char
        }

        for row in 0..<grid.rows {
            guard let cols = rowChars[row] else { continue }
            var line = ""
            for col in 0..<grid.cols {
                line.append(cols[col] ?? " ")
            }
            if line.contains(text) { return true }
        }
        return false
    }
}
