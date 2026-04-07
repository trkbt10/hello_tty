import AppKit

/// Automated UI test suite for hello_tty.
///
/// Launched via `--self-test` argument. Exercises the terminal state,
/// rendering pipeline, resize behavior, and tab management, then exits
/// with 0 (pass) or 1 (fail).
///
/// Screenshots are saved to /tmp/hello_tty_selftest_*.png for inspection.
/// No Screen Recording or Accessibility permissions are needed — the app
/// captures its own views via NSView.cacheDisplay.
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
                    self.reportAndExit()
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
        guard let grid = tab.state.grid else {
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
        preResizeRows = tab.state.currentRows
        preResizeCols = tab.state.currentCols

        guard let window = NSApp.windows.first else {
            fail("test4_resize: No window")
            return
        }

        // Resize to a larger size
        let newFrame = NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                              width: 1024, height: 768)
        window.setFrame(newFrame, display: true, animate: false)
        pass("test4_resize: Resized to 1024x768 (was \(preResizeRows)x\(preResizeCols))")
    }

    // MARK: - Test 5: Resize result

    private func test5_resizeResult() {
        guard let tab = tabManager.selectedTab else {
            fail("test5_resizeResult: No selected tab")
            return
        }
        let newRows = tab.state.currentRows
        let newCols = tab.state.currentCols

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
        cellCountBefore = tab.state.grid?.cells.count ?? 0

        // Send "echo test123" + Return
        tab.state.sendText("echo test123\r")
        pass("test6_keyboardInput: Sent 'echo test123\\r'")
    }

    // MARK: - Test 7: Keyboard input result

    private func test7_keyboardInputResult() {
        guard let tab = tabManager.selectedTab else {
            fail("test7_keyboardInputResult: No selected tab")
            return
        }
        let cellCountAfter = tab.state.grid?.cells.count ?? 0

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

        // Create a new tab
        let newTab = tabManager.newTab()
        newTab.state.initialize()
        newTab.state.startShell()

        if tabManager.tabs.count != tabCountBefore + 1 {
            fail("test8_tabManagement: Tab count did not increase")
            return
        }

        // Switch back to first tab
        if let firstTab = tabManager.tabs.first {
            tabManager.selectedTabId = firstTab.id
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
        if let grid = tab.state.grid {
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
              let grid = tab.state.grid
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

    private func captureView(_ view: NSView) -> NSBitmapImageRep {
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

    private func gridContainsText(_ text: String) -> Bool {
        guard let tab = tabManager.selectedTab,
              let grid = tab.state.grid
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
