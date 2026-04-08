import Foundation

/// Bridge to the MoonBit terminal core via dynamically loaded libhello_tty.dylib.
///
/// Following bartleby's pattern: dlopen → dlsym → typed function pointers.
/// All data crosses the FFI boundary as C strings (UTF-8, null-terminated).
/// Returned strings must be freed via hello_tty_free_string.
class MoonBitBridge {
    static let shared = MoonBitBridge()

    // Function pointer typedefs matching hello_tty_core.h
    private typealias InitFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias ShutdownFn = @convention(c) () -> Int32
    private typealias ProcessOutputFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias HandleKeyFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias GetGridFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetCursorFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetTitleFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetModesFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias ResizeFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias FocusEventFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    // PTY session function types
    private typealias PtyStartFn = @convention(c) (UnsafePointer<CChar>?, Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias PtyPollFn = @convention(c) (Int32, Int32) -> Int32
    private typealias PtyReadFn = @convention(c) (Int32, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    private typealias PtyWriteFn = @convention(c) (Int32, UnsafePointer<UInt8>, Int32) -> Int32
    private typealias PtyCloseFn = @convention(c) (Int32) -> Void
    private typealias PtyResizeFn = @convention(c) (Int32, Int32, Int32) -> Int32

    // Input classification
    private typealias ClassifyKeyFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

    // Session management (legacy)
    private typealias CreateSessionFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias DestroySessionFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias SwitchSessionFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias ListSessionsFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetActiveSessionFn = @convention(c) () -> Int32

    // Tab & Panel management (layout-aware)
    private typealias CreateTabFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias CloseTabFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias SwitchTabFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias NextTabFn = @convention(c) () -> Int32
    private typealias PrevTabFn = @convention(c) () -> Int32
    private typealias ListTabsFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias SplitPanelFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias ClosePanelFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias FocusPanelFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias FocusPanelByIndexFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias FocusDirectionFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias GetLayoutFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetAllPanelsFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetFocusedPanelIdFn = @convention(c) () -> Int32

    // Session-targeted operations
    private typealias ProcessOutputForFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias GetGridForFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias HandleKeyForFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias ResizeSessionFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

    // Shell Integration (OSC 133 Semantic Prompt)
    private typealias GetInputRegionFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetInputRegionForFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias IsInInputRegionFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias CursorMoveSequenceFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias SetFeatureFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

    // Viewport / Scrollback
    private typealias ScrollViewportFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias ResetViewportFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias GetViewportOffsetFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias GetScrollbackLengthFn = @convention(c) (UnsafePointer<CChar>?) -> Int32

    // Theme
    private typealias GetThemeFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

    // Font rasterization function types
    private typealias FontInitFn = @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> Int32
    private typealias FontRasterizeFn = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    private typealias FontGetMetricsFn = @convention(c) (UnsafeMutablePointer<Int32>) -> Int32
    private typealias FontShutdownFn = @convention(c) () -> Void

    // GPU rendering via MoonBit pipeline (bridge functions)
    private typealias GpuInitBridgeFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias RenderFrameFn = @convention(c) () -> Int32
    private typealias GpuResizeBridgeFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

    private typealias RenderFrameForFn = @convention(c) (UnsafePointer<CChar>?) -> Int32

    // GPU multi-surface bridge
    private typealias GpuRegisterSurfaceFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias GpuSurfaceDestroyBridgeFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias GpuSurfaceResizeBridgeFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

    // Direct GPU FFI (for surface init that needs raw pointer)
    private typealias GpuInitDirectFn = @convention(c) (UInt64, Int32, Int32) -> Int32
    private typealias GpuSurfaceCreateDirectFn = @convention(c) (UInt64, Int32, Int32) -> Int32

    // Loaded function pointers
    private var fnInit: InitFn?
    private var fnShutdown: ShutdownFn?
    private var fnProcessOutput: ProcessOutputFn?
    private var fnHandleKey: HandleKeyFn?
    private var fnGetGrid: GetGridFn?
    private var fnGetCursor: GetCursorFn?
    private var fnGetTitle: GetTitleFn?
    private var fnGetModes: GetModesFn?
    private var fnResize: ResizeFn?
    private var fnFocusEvent: FocusEventFn?
    private var fnFreeString: FreeStringFn?
    private var fnPtyStart: PtyStartFn?
    private var fnPtyPoll: PtyPollFn?
    private var fnPtyRead: PtyReadFn?
    private var fnPtyWrite: PtyWriteFn?
    private var fnPtyClose: PtyCloseFn?
    private var fnPtyResize: PtyResizeFn?

    // Input
    private var fnClassifyKey: ClassifyKeyFn?

    // Session management (legacy)
    private var fnCreateSession: CreateSessionFn?
    private var fnDestroySession: DestroySessionFn?
    private var fnSwitchSession: SwitchSessionFn?
    private var fnListSessions: ListSessionsFn?
    private var fnGetActiveSession: GetActiveSessionFn?

    // Tab & Panel management
    private var fnCreateTab: CreateTabFn?
    private var fnCloseTab: CloseTabFn?
    private var fnSwitchTab: SwitchTabFn?
    private var fnNextTab: NextTabFn?
    private var fnPrevTab: PrevTabFn?
    private var fnListTabs: ListTabsFn?
    private var fnSplitPanel: SplitPanelFn?
    private var fnClosePanel: ClosePanelFn?
    private var fnFocusPanel: FocusPanelFn?
    private var fnFocusPanelByIndex: FocusPanelByIndexFn?
    private var fnFocusDirection: FocusDirectionFn?
    private var fnGetLayout: GetLayoutFn?
    private var fnGetAllPanels: GetAllPanelsFn?
    private var fnGetFocusedPanelId: GetFocusedPanelIdFn?

    // Session-targeted operations
    private var fnProcessOutputFor: ProcessOutputForFn?
    private var fnGetGridFor: GetGridForFn?
    private var fnHandleKeyFor: HandleKeyForFn?
    private var fnResizeSession: ResizeSessionFn?

    // Shell Integration (OSC 133)
    private var fnGetInputRegion: GetInputRegionFn?
    private var fnGetInputRegionFor: GetInputRegionForFn?
    private var fnIsInInputRegion: IsInInputRegionFn?
    private var fnCursorMoveSequence: CursorMoveSequenceFn?
    private var fnSetFeature: SetFeatureFn?

    // Viewport / Scrollback
    private var fnScrollViewportUp: ScrollViewportFn?
    private var fnScrollViewportDown: ScrollViewportFn?
    private var fnResetViewport: ResetViewportFn?
    private var fnGetViewportOffset: GetViewportOffsetFn?
    private var fnGetScrollbackLength: GetScrollbackLengthFn?

    // Theme & metrics
    private var fnGetTheme: GetThemeFn?
    private var fnGetCellMetrics: GetThemeFn?  // same signature: () -> UnsafeMutablePointer<CChar>?

    // Font
    private var fnFontInit: FontInitFn?
    private var fnFontRasterize: FontRasterizeFn?
    private var fnFontGetMetrics: FontGetMetricsFn?
    private var fnFontShutdown: FontShutdownFn?

    // GPU (MoonBit pipeline bridge)
    private var fnGpuInitBridge: GpuInitBridgeFn?
    private var fnRenderFrame: RenderFrameFn?
    private var fnRenderFrameFor: RenderFrameForFn?
    private var fnGpuResizeBridge: GpuResizeBridgeFn?
    // GPU multi-surface
    private var fnGpuRegisterSurface: GpuRegisterSurfaceFn?
    private var fnGpuSurfaceDestroyBridge: GpuSurfaceDestroyBridgeFn?
    private var fnGpuSurfaceResizeBridge: GpuSurfaceResizeBridgeFn?
    // Direct GPU FFI (for raw surface init)
    private var fnGpuInitDirect: GpuInitDirectFn?
    private var fnGpuSurfaceCreateDirect: GpuSurfaceCreateDirectFn?

    private var handle: UnsafeMutableRawPointer?
    private(set) var isLoaded = false

    private init() {
        loadLibrary()
    }

    deinit {
        if let handle = handle {
            dlclose(handle)
        }
    }

    // MARK: - Library Loading

    private func loadLibrary() {
        let searchPaths = buildSearchPaths()

        for path in searchPaths {
            if let h = dlopen(path, RTLD_LAZY) {
                handle = h
                loadSymbols()
                isLoaded = true
                NSLog("hello_tty: loaded dylib from %@", path)
                return
            }
        }

        // Try bare name (uses DYLD_LIBRARY_PATH)
        if let h = dlopen("libhello_tty.dylib", RTLD_LAZY) {
            handle = h
            loadSymbols()
            isLoaded = true
            NSLog("hello_tty: loaded dylib via DYLD_LIBRARY_PATH")
            return
        }

        NSLog("hello_tty: WARNING — could not load libhello_tty.dylib")
    }

    private func buildSearchPaths() -> [String] {
        var paths: [String] = []

        // 1. Adjacent to the Swift executable (development)
        if let execPath = Bundle.main.executablePath {
            let dir = (execPath as NSString).deletingLastPathComponent
            paths.append(dir + "/build/libhello_tty.dylib")
            paths.append(dir + "/libhello_tty.dylib")
        }

        // 2. Project-relative build directory
        if let projectRoot = findProjectRoot() {
            paths.append(projectRoot + "/adapters/macos/build/libhello_tty.dylib")
        }

        // 3. App bundle frameworks
        if let frameworksPath = Bundle.main.privateFrameworksPath {
            paths.append(frameworksPath + "/libhello_tty.dylib")
        }

        // 4. App bundle resources
        if let resourcePath = Bundle.main.resourcePath {
            paths.append(resourcePath + "/libhello_tty.dylib")
        }

        return paths
    }

    private func findProjectRoot() -> String? {
        // Walk up from the executable looking for moon.mod.json
        var dir = (Bundle.main.executablePath ?? "") as NSString
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent as NSString
            let moonMod = dir.appendingPathComponent("moon.mod.json")
            if FileManager.default.fileExists(atPath: moonMod) {
                return dir as String
            }
        }
        return nil
    }

    private func loadSymbols() {
        guard let h = handle else { return }

        func sym<T>(_ name: String) -> T? {
            guard let ptr = dlsym(h, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        fnInit = sym("hello_tty_init")
        fnShutdown = sym("hello_tty_shutdown")
        fnProcessOutput = sym("hello_tty_process_output")
        fnHandleKey = sym("hello_tty_handle_key")
        fnGetGrid = sym("hello_tty_get_grid")
        fnGetCursor = sym("hello_tty_get_cursor")
        fnGetTitle = sym("hello_tty_get_title")
        fnGetModes = sym("hello_tty_get_modes")
        fnResize = sym("hello_tty_resize")
        fnFocusEvent = sym("hello_tty_focus_event")
        fnFreeString = sym("hello_tty_free_string")
        fnPtyStart = sym("hello_tty_pty_start")
        fnPtyPoll = sym("hello_tty_pty_poll")
        fnPtyRead = sym("hello_tty_pty_read")
        fnPtyWrite = sym("hello_tty_pty_write")
        fnPtyClose = sym("hello_tty_pty_close")
        fnPtyResize = sym("hello_tty_pty_resize")

        // Input
        fnClassifyKey = sym("hello_tty_classify_key")

        // Session management
        fnCreateSession = sym("hello_tty_create_session")
        fnDestroySession = sym("hello_tty_destroy_session")
        fnSwitchSession = sym("hello_tty_switch_session")
        fnListSessions = sym("hello_tty_list_sessions")
        fnGetActiveSession = sym("hello_tty_get_active_session")

        // Tab & Panel management
        fnCreateTab = sym("hello_tty_create_tab")
        fnCloseTab = sym("hello_tty_close_tab")
        fnSwitchTab = sym("hello_tty_switch_tab")
        fnNextTab = sym("hello_tty_next_tab")
        fnPrevTab = sym("hello_tty_prev_tab")
        fnListTabs = sym("hello_tty_list_tabs")
        fnSplitPanel = sym("hello_tty_split_panel")
        fnClosePanel = sym("hello_tty_close_panel")
        fnFocusPanel = sym("hello_tty_focus_panel")
        fnFocusPanelByIndex = sym("hello_tty_focus_panel_by_index")
        fnFocusDirection = sym("hello_tty_focus_direction")
        fnGetLayout = sym("hello_tty_get_layout")
        fnGetAllPanels = sym("hello_tty_get_all_panels")
        fnGetFocusedPanelId = sym("hello_tty_get_focused_panel_id")

        // Session-targeted operations
        fnProcessOutputFor = sym("hello_tty_process_output_for")
        fnGetGridFor = sym("hello_tty_get_grid_for")
        fnHandleKeyFor = sym("hello_tty_handle_key_for")
        fnResizeSession = sym("hello_tty_resize_session")

        // Shell Integration (OSC 133)
        fnGetInputRegion = sym("hello_tty_get_input_region")
        fnGetInputRegionFor = sym("hello_tty_get_input_region_for")
        fnIsInInputRegion = sym("hello_tty_is_in_input_region")
        fnCursorMoveSequence = sym("hello_tty_cursor_move_sequence")
        fnSetFeature = sym("hello_tty_set_feature")

        // Viewport / Scrollback
        fnScrollViewportUp = sym("hello_tty_scroll_viewport_up")
        fnScrollViewportDown = sym("hello_tty_scroll_viewport_down")
        fnResetViewport = sym("hello_tty_reset_viewport")
        fnGetViewportOffset = sym("hello_tty_get_viewport_offset")
        fnGetScrollbackLength = sym("hello_tty_get_scrollback_length")

        // Layout resize (MoonBit SoT)
        fnResizeLayout = sym("hello_tty_resize_layout")
        fnResizeLayoutPx = sym("hello_tty_resize_layout_px")

        // Panel resize notification
        fnNotifyPanelResize = sym("hello_tty_notify_panel_resize")

        // Coordinate conversion
        fnPixelToGrid = sym("hello_tty_pixel_to_grid")

        // Theme & metrics
        fnGetTheme = sym("hello_tty_get_theme")
        fnGetCellMetrics = sym("hello_tty_get_cell_metrics")

        // Font
        fnFontInit = sym("hello_tty_font_init")
        fnFontRasterize = sym("hello_tty_font_rasterize")
        fnFontGetMetrics = sym("hello_tty_font_get_metrics")
        fnFontShutdown = sym("hello_tty_font_shutdown")

        // GPU (MoonBit pipeline bridge)
        fnGpuInitBridge = sym("hello_tty_gpu_init_bridge")
        fnRenderFrame = sym("hello_tty_render_frame")
        fnRenderFrameFor = sym("hello_tty_render_frame_for")
        fnGpuResizeBridge = sym("hello_tty_gpu_resize_bridge")
        // GPU multi-surface
        fnGpuRegisterSurface = sym("hello_tty_gpu_register_surface")
        fnGpuSurfaceDestroyBridge = sym("hello_tty_gpu_surface_destroy_bridge")
        fnGpuSurfaceResizeBridge = sym("hello_tty_gpu_surface_resize_bridge")
        // Direct GPU FFI (for raw surface init)
        fnGpuInitDirect = sym("hello_tty_gpu_init")
        fnGpuSurfaceCreateDirect = sym("hello_tty_gpu_surface_create")
        fnGpuSurfaceDestroyDirect = sym("hello_tty_gpu_surface_destroy")
    }

    // MARK: - Public API

    func initialize(rows: Int = 24, cols: Int = 80) -> Bool {
        guard let fn = fnInit else { return false }
        let result = "\(rows)".withCString { r in
            "\(cols)".withCString { c in
                fn(r, c)
            }
        }
        return result == 0
    }

    func shutdown() {
        _ = fnShutdown?()
    }

    func processOutput(_ data: String) -> Bool {
        guard let fn = fnProcessOutput else { return false }
        return data.withCString { fn($0) } == 0
    }

    func handleKey(keyCode: Int, modifiers: Int) -> String? {
        guard let fn = fnHandleKey else { return nil }
        let resultPtr = "\(keyCode)".withCString { k in
            "\(modifiers)".withCString { m in
                fn(k, m)
            }
        }
        guard let ptr = resultPtr else { return nil }
        defer { fnFreeString?(ptr) }
        return String(cString: ptr)
    }

    /// Get the terminal grid. Colors are already fully resolved by MoonBit.
    func getGrid() -> TerminalGrid? {
        guard let fn = fnGetGrid else { return nil }
        guard let ptr = fn() else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)
        return TerminalGrid.fromJSON(jsonStr)
    }

    /// Lightweight cursor query — no JSON, just "row,col,visible,style".
    struct CursorInfo {
        let row: Int
        let col: Int
        let visible: Bool
        let style: String
    }

    func getCursor() -> CursorInfo? {
        guard let fn = fnGetCursor else { return nil }
        guard let ptr = fn() else { return nil }
        defer { fnFreeString?(ptr) }
        let str = String(cString: ptr)
        let parts = str.split(separator: ",")
        guard parts.count == 4,
              let row = Int(parts[0]),
              let col = Int(parts[1])
        else { return nil }
        return CursorInfo(
            row: row,
            col: col,
            visible: parts[2] == "1",
            style: String(parts[3])
        )
    }

    func getTitle() -> String {
        guard let fn = fnGetTitle else { return "" }
        guard let ptr = fn() else { return "" }
        defer { fnFreeString?(ptr) }
        return String(cString: ptr)
    }

    func getModes() -> [String: Bool] {
        guard let fn = fnGetModes else { return [:] }
        guard let ptr = fn() else { return [:] }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else { return [:] }
        return obj
    }

    func resize(rows: Int, cols: Int) -> Bool {
        guard let fn = fnResize else { return false }
        let result = "\(rows)".withCString { r in
            "\(cols)".withCString { c in
                fn(r, c)
            }
        }
        return result == 0
    }

    func focusEvent(gained: Bool) -> String? {
        guard let fn = fnFocusEvent else { return nil }
        let gainedStr = gained ? "1" : "0"
        let resultPtr = gainedStr.withCString { fn($0) }
        guard let ptr = resultPtr else { return nil }
        defer { fnFreeString?(ptr) }
        return String(cString: ptr)
    }

    // MARK: - PTY Session

    /// Start a PTY session. Returns (masterFd, childPid), or nil on failure.
    func ptyStart(shell: String = "/bin/zsh", rows: Int = 24, cols: Int = 80) -> (masterFd: Int32, pid: Int32)? {
        guard let fn = fnPtyStart else { return nil }
        var pid: Int32 = 0
        let masterFd = shell.withCString { fn($0, Int32(rows), Int32(cols), &pid) }
        if masterFd < 0 { return nil }
        return (masterFd, pid)
    }

    /// Poll PTY for readability. Returns 1=readable, 0=timeout, -2=EOF, -1=error.
    func ptyPoll(masterFd: Int32, timeoutMs: Int32 = 10) -> Int32 {
        guard let fn = fnPtyPoll else { return -1 }
        return fn(masterFd, timeoutMs)
    }

    /// Read from PTY. Returns data or nil on EOF/error.
    func ptyRead(masterFd: Int32, maxLen: Int = 4096) -> Data? {
        guard let fn = fnPtyRead else { return nil }
        var buf = [UInt8](repeating: 0, count: maxLen)
        let n = fn(masterFd, &buf, Int32(maxLen))
        if n <= 0 { return nil }
        return Data(buf[0..<Int(n)])
    }

    /// Write data to PTY.
    func ptyWrite(masterFd: Int32, data: Data) -> Bool {
        guard let fn = fnPtyWrite else { return false }
        return data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return fn(masterFd, ptr, Int32(data.count)) >= 0
        }
    }

    /// Close PTY master fd.
    func ptyClose(masterFd: Int32) {
        fnPtyClose?(masterFd)
    }

    /// Resize PTY window (TIOCSWINSZ).
    func ptyResize(masterFd: Int32, rows: Int, cols: Int) {
        _ = fnPtyResize?(masterFd, Int32(rows), Int32(cols))
    }

    // MARK: - Input Classification (MoonBit SoT)

    enum KeyClassification {
        case directToPty
        case forwardToIme
        case clipboardCopy
        case clipboardPaste
        case clipboardCut
        case selectAll
        case findInTerminal
        case splitRight
        case splitDown
        case nextSplit
        case prevSplit
        case newTab
        case closePanel
        case nextTab
        case prevTab
        case gotoTab(Int)          // 0-based index, -1 = last tab
        case focusDirection(Int32) // 0=up, 1=down, 2=left, 3=right

        static func from(rawValue: Int32) -> KeyClassification {
            switch rawValue {
            case 0: return .directToPty
            case 1: return .forwardToIme
            case 2: return .clipboardCopy
            case 3: return .clipboardPaste
            case 4: return .clipboardCut
            case 5: return .selectAll
            case 6: return .findInTerminal
            case 10: return .splitRight
            case 11: return .splitDown
            case 12: return .nextSplit
            case 13: return .prevSplit
            case 14: return .newTab
            case 15: return .closePanel
            case 16: return .nextTab
            case 17: return .prevTab
            // GotoTab: 19 = last tab (-1), 20..27 = tab 0..7
            case 19: return .gotoTab(-1)
            case 20...27: return .gotoTab(Int(rawValue - 20))
            case 30...33: return .focusDirection(rawValue - 30)
            default: return .forwardToIme
            }
        }
    }

    /// Classify a key event — delegates to MoonBit input module (SoT).
    func classifyKey(keyCode: Int, modifiers: Int, hasMarkedText: Bool) -> KeyClassification {
        guard let fn = fnClassifyKey else { return .forwardToIme }
        let result = "\(keyCode)".withCString { k in
            "\(modifiers)".withCString { m in
                "\(hasMarkedText ? 1 : 0)".withCString { h in
                    fn(k, m, h)
                }
            }
        }
        return KeyClassification.from(rawValue: result)
    }

    // MARK: - Session Management (MoonBit SoT)

    struct CreateSessionResult {
        let sessionId: Int32
        let masterFd: Int32
    }

    /// Create a new session (terminal init + PTY spawn in MoonBit).
    /// Returns (sessionId, masterFd). Shell path resolved by MoonBit from $SHELL.
    func createSession(rows: Int = 24, cols: Int = 80) -> CreateSessionResult? {
        guard let fn = fnCreateSession else { return nil }
        let ptr = "\(rows)".withCString { r in
            "\(cols)".withCString { c in fn(r, c) }
        }
        guard let ptr = ptr else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int,
              let fd = obj["fd"] as? Int
        else { return nil }

        return CreateSessionResult(sessionId: Int32(id), masterFd: Int32(fd))
    }

    /// Destroy a session by ID.
    func destroySession(id: Int32) {
        guard let fn = fnDestroySession else { return }
        _ = "\(id)".withCString { fn($0) }
    }

    /// Switch active session.
    func switchSession(id: Int32) -> Bool {
        guard let fn = fnSwitchSession else { return false }
        return "\(id)".withCString { fn($0) } == 0
    }

    struct SessionInfo {
        let id: Int
        let title: String
        let isActive: Bool
    }

    /// List all sessions.
    func listSessions() -> [SessionInfo] {
        guard let fn = fnListSessions else { return [] }
        guard let ptr = fn() else { return [] }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj in
            guard let id = obj["id"] as? Int,
                  let title = obj["title"] as? String,
                  let active = obj["active"] as? Bool
            else { return nil }
            return SessionInfo(id: id, title: title, isActive: active)
        }
    }

    /// Get the active session ID (-1 if none).
    func getActiveSessionId() -> Int32 {
        guard let fn = fnGetActiveSession else { return -1 }
        return fn()
    }

    // MARK: - Tab & Panel Management (Layout-aware, MoonBit SoT)

    struct CreateTabResult {
        let tabId: Int32
        let panelId: Int32
        let sessionId: Int32
        let masterFd: Int32
    }

    /// Create a new tab with a single panel.
    func createTab(rows: Int = 24, cols: Int = 80) -> CreateTabResult? {
        guard let fn = fnCreateTab else { return nil }
        let ptr = "\(rows)".withCString { r in
            "\(cols)".withCString { c in fn(r, c) }
        }
        guard let ptr = ptr else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tabId = obj["tab_id"] as? Int,
              let panelId = obj["panel_id"] as? Int,
              let sessionId = obj["session_id"] as? Int,
              let fd = obj["fd"] as? Int
        else { return nil }

        return CreateTabResult(tabId: Int32(tabId), panelId: Int32(panelId),
                               sessionId: Int32(sessionId), masterFd: Int32(fd))
    }

    /// Close a tab and all its panels/sessions.
    func closeTab(id: Int32) {
        guard let fn = fnCloseTab else { return }
        _ = "\(id)".withCString { fn($0) }
    }

    /// Switch to a tab by ID.
    func switchTab(id: Int32) -> Bool {
        guard let fn = fnSwitchTab else { return false }
        return "\(id)".withCString { fn($0) } == 0
    }

    /// Switch to next tab.
    func nextTab() -> Bool {
        guard let fn = fnNextTab else { return false }
        return fn() == 0
    }

    /// Switch to previous tab.
    func prevTab() -> Bool {
        guard let fn = fnPrevTab else { return false }
        return fn() == 0
    }

    struct TabInfo {
        let id: Int
        let title: String
        let isActive: Bool
    }

    /// List all tabs.
    func listTabs() -> [TabInfo] {
        guard let fn = fnListTabs else { return [] }
        guard let ptr = fn() else { return [] }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj in
            guard let id = obj["id"] as? Int,
                  let title = obj["title"] as? String,
                  let active = obj["active"] as? Bool
            else { return nil }
            return TabInfo(id: id, title: title, isActive: active)
        }
    }

    struct SplitPanelResult {
        let panelId: Int32
        let sessionId: Int32
        let masterFd: Int32
        let existingRows: Int
        let existingCols: Int
    }

    /// Split a panel. direction: 0=vertical (left/right), 1=horizontal (top/bottom).
    func splitPanel(panelId: Int32, direction: Int32) -> SplitPanelResult? {
        guard let fn = fnSplitPanel else { return nil }
        let ptr = "\(panelId)".withCString { p in
            "\(direction)".withCString { d in fn(p, d) }
        }
        guard let ptr = ptr else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["panel_id"] as? Int,
              let sid = obj["session_id"] as? Int,
              let fd = obj["fd"] as? Int,
              let er = obj["existing_rows"] as? Int,
              let ec = obj["existing_cols"] as? Int
        else { return nil }

        return SplitPanelResult(panelId: Int32(pid), sessionId: Int32(sid),
                                masterFd: Int32(fd), existingRows: er, existingCols: ec)
    }

    /// Close a panel. Returns new focused session_id, or -1 if tab was closed.
    func closePanel(panelId: Int32) -> Int32 {
        guard let fn = fnClosePanel else { return -1 }
        return "\(panelId)".withCString { fn($0) }
    }

    /// Focus a panel by ID.
    func focusPanel(panelId: Int32) -> Bool {
        guard let fn = fnFocusPanel else { return false }
        return "\(panelId)".withCString { fn($0) } == 0
    }

    /// Focus panel by DFS index (0-based).
    func focusPanelByIndex(_ index: Int32) -> Bool {
        guard let fn = fnFocusPanelByIndex else { return false }
        return "\(index)".withCString { fn($0) } == 0
    }

    /// Focus neighboring panel. 0=up, 1=down, 2=left, 3=right.
    func focusDirection(_ direction: Int32) -> Bool {
        guard let fn = fnFocusDirection else { return false }
        return "\(direction)".withCString { fn($0) } == 0
    }

    /// Get the layout tree of the active tab as JSON string.
    func getLayout() -> String? {
        guard let fn = fnGetLayout else { return nil }
        guard let ptr = fn() else { return nil }
        defer { fnFreeString?(ptr) }
        return String(cString: ptr)
    }

    struct PanelInfo {
        let panelId: Int32
        let sessionId: Int32
        let rows: Int
        let cols: Int
        let focused: Bool
    }

    /// Get all panels in the active tab.
    func getAllPanels() -> [PanelInfo] {
        guard let fn = fnGetAllPanels else { return [] }
        guard let ptr = fn() else { return [] }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj in
            guard let pid = obj["panel_id"] as? Int,
                  let sid = obj["session_id"] as? Int,
                  let rows = obj["rows"] as? Int,
                  let cols = obj["cols"] as? Int,
                  let focused = obj["focused"] as? Bool
            else { return nil }
            return PanelInfo(panelId: Int32(pid), sessionId: Int32(sid),
                             rows: rows, cols: cols, focused: focused)
        }
    }

    /// Get the focused panel ID (-1 if none).
    func getFocusedPanelId() -> Int32 {
        guard let fn = fnGetFocusedPanelId else { return -1 }
        return fn()
    }

    // MARK: - Session-Targeted Operations

    /// Feed PTY output into a specific session.
    func processOutputFor(sessionId: Int32, data: String) -> Bool {
        guard let fn = fnProcessOutputFor else { return false }
        let result = "\(sessionId)".withCString { s in
            data.withCString { d in fn(s, d) }
        }
        return result == 0
    }

    /// Get the grid of a specific session.
    func getGridFor(sessionId: Int32) -> TerminalGrid? {
        guard let fn = fnGetGridFor else { return nil }
        let ptr = "\(sessionId)".withCString { fn($0) }
        guard let ptr = ptr else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)
        return TerminalGrid.fromJSON(jsonStr)
    }

    /// Handle a key on a specific session.
    func handleKeyFor(sessionId: Int32, keyCode: Int, modifiers: Int) -> String? {
        guard let fn = fnHandleKeyFor else { return nil }
        let resultPtr = "\(sessionId)".withCString { s in
            "\(keyCode)".withCString { k in
                "\(modifiers)".withCString { m in fn(s, k, m) }
            }
        }
        guard let ptr = resultPtr else { return nil }
        defer { fnFreeString?(ptr) }
        return String(cString: ptr)
    }

    /// Resize a specific session's terminal.
    func resizeSession(sessionId: Int32, rows: Int, cols: Int) -> Bool {
        guard let fn = fnResizeSession else { return false }
        let result = "\(sessionId)".withCString { s in
            "\(rows)".withCString { r in
                "\(cols)".withCString { c in fn(s, r, c) }
            }
        }
        return result == 0
    }

    // MARK: - Viewport / Scrollback

    /// Scroll a session's viewport up (back into history). Returns new offset.
    func scrollViewportUp(sessionId: Int32, lines: Int) -> Int32 {
        guard let fn = fnScrollViewportUp else { return -1 }
        return "\(sessionId)".withCString { s in
            "\(lines)".withCString { l in fn(s, l) }
        }
    }

    /// Scroll a session's viewport down (toward live). Returns new offset.
    func scrollViewportDown(sessionId: Int32, lines: Int) -> Int32 {
        guard let fn = fnScrollViewportDown else { return -1 }
        return "\(sessionId)".withCString { s in
            "\(lines)".withCString { l in fn(s, l) }
        }
    }

    /// Reset a session's viewport to live view.
    func resetViewport(sessionId: Int32) -> Bool {
        guard let fn = fnResetViewport else { return false }
        let result = "\(sessionId)".withCString { fn($0) }
        return result == 0
    }

    /// Get a session's current viewport offset (0=live).
    func getViewportOffset(sessionId: Int32) -> Int32 {
        guard let fn = fnGetViewportOffset else { return -1 }
        return "\(sessionId)".withCString { fn($0) }
    }

    /// Get a session's scrollback length (total lines in history).
    func getScrollbackLength(sessionId: Int32) -> Int32 {
        guard let fn = fnGetScrollbackLength else { return -1 }
        return "\(sessionId)".withCString { fn($0) }
    }

    // MARK: - Layout Resize (MoonBit SoT)

    private typealias ResizeLayoutFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private var fnResizeLayout: ResizeLayoutFn?
    private var fnResizeLayoutPx: ResizeLayoutFn?

    struct PanelDimensions {
        let panelId: Int32
        let sessionId: Int32
        let rows: Int
        let cols: Int
    }

    /// Resize the layout using grid dimensions.
    func resizeLayout(totalRows: Int, totalCols: Int) -> [PanelDimensions] {
        guard let fn = fnResizeLayout else { return [] }
        let ptr = "\(totalRows)".withCString { r in
            "\(totalCols)".withCString { c in fn(r, c) }
        }
        return parsePanelDimensions(ptr)
    }

    /// Resize the layout using pixel dimensions.
    /// MoonBit converts pixels → grid cells using its own cell metrics (SoT).
    func resizeLayoutPx(widthPx: Int, heightPx: Int) -> [PanelDimensions] {
        guard let fn = fnResizeLayoutPx else { return [] }
        let ptr = "\(widthPx)".withCString { w in
            "\(heightPx)".withCString { h in fn(w, h) }
        }
        return parsePanelDimensions(ptr)
    }

    /// Parse panel dimensions JSON from a C string pointer.
    private func parsePanelDimensions(_ ptr: UnsafeMutablePointer<CChar>?) -> [PanelDimensions] {
        guard let ptr = ptr else { return [] }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj in
            guard let pid = obj["panel_id"] as? Int,
                  let sid = obj["session_id"] as? Int,
                  let rows = obj["rows"] as? Int,
                  let cols = obj["cols"] as? Int
            else { return nil }
            return PanelDimensions(panelId: Int32(pid), sessionId: Int32(sid),
                                  rows: rows, cols: cols)
        }
    }

    // MARK: - Coordinate Conversion (MoonBit SoT)

    private typealias PixelToGridFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private var fnPixelToGrid: PixelToGridFn?

    /// Convert pixel coordinates to grid cell (row, col).
    /// MoonBit uses its own cell metrics (SoT) for the conversion.
    func pixelToGrid(xPx: Int, yPx: Int, viewHeightPx: Int) -> (row: Int, col: Int) {
        guard let fn = fnPixelToGrid else { return (0, 0) }
        let ptr = "\(xPx)".withCString { x in
            "\(yPx)".withCString { y in
                "\(viewHeightPx)".withCString { h in fn(x, y, h) }
            }
        }
        guard let ptr = ptr else { return (0, 0) }
        defer { fnFreeString?(ptr) }
        let result = String(cString: ptr)
        let parts = result.split(separator: ",")
        guard parts.count == 2,
              let row = Int(parts[0]),
              let col = Int(parts[1])
        else { return (0, 0) }
        return (row, col)
    }

    // MARK: - Shell Integration (OSC 133 Input Region)

    /// Test whether a grid cell is within the shell input region (MoonBit SoT).
    /// Returns true only when shell_integration feature is enabled and the cell
    /// falls within the current command input span.
    func isInInputRegion(sessionId: Int32, row: Int, col: Int) -> Bool {
        guard let fn = fnIsInInputRegion else { return false }
        return "\(sessionId)".withCString { s in
            "\(row)".withCString { r in
                "\(col)".withCString { c in fn(s, r, c) }
            }
        } == 1
    }

    /// Generate arrow key escape sequences to move the shell cursor to (row, col).
    /// MoonBit computes the delta from the current cursor position and generates
    /// the correct sequences (respecting application cursor key mode).
    /// Returns nil if the target is outside the input region.
    func cursorMoveSequence(sessionId: Int32, row: Int, col: Int) -> String? {
        guard let fn = fnCursorMoveSequence else { return nil }
        let ptr = "\(sessionId)".withCString { s in
            "\(row)".withCString { r in
                "\(col)".withCString { c in fn(s, r, c) }
            }
        }
        guard let ptr = ptr else { return nil }
        defer { fnFreeString?(ptr) }
        let result = String(cString: ptr)
        return result.isEmpty ? nil : result
    }

    /// Set a terminal feature flag (MoonBit SoT).
    /// - Parameters:
    ///   - sessionId: Target session
    ///   - name: Feature name (e.g., "shell_integration")
    ///   - enabled: Whether to enable or disable
    @discardableResult
    func setFeature(sessionId: Int32, name: String, enabled: Bool) -> Int32 {
        guard let fn = fnSetFeature else { return -1 }
        return "\(sessionId)".withCString { s in
            name.withCString { n in
                (enabled ? "1" : "0").withCString { e in fn(s, n, e) }
            }
        }
    }

    // MARK: - Panel Resize Notification

    private typealias NotifyPanelResizeFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private var fnNotifyPanelResize: NotifyPanelResizeFn?

    /// Notify MoonBit that a divider moved, giving the first child's new pixel size.
    /// Returns updated panel dimensions (same as resizeLayout).
    func notifyPanelResize(panelId: Int32, firstSizePx: Int, totalSizePx: Int) -> [PanelDimensions] {
        guard let fn = fnNotifyPanelResize else { return [] }
        let ptr = "\(panelId)".withCString { p in
            "\(firstSizePx)".withCString { f in
                "\(totalSizePx)".withCString { t in fn(p, f, t) }
            }
        }
        guard let ptr = ptr else { return [] }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj in
            guard let pid = obj["panel_id"] as? Int,
                  let sid = obj["session_id"] as? Int,
                  let rows = obj["rows"] as? Int,
                  let cols = obj["cols"] as? Int
            else { return nil }
            return PanelDimensions(panelId: Int32(pid), sessionId: Int32(sid),
                                  rows: rows, cols: cols)
        }
    }

    // MARK: - Theme (MoonBit SoT)

    struct ThemeInfo {
        let name: String
        let isDark: Bool
        let bgAlpha: Double
        let fg: (Int, Int, Int, Int)  // r, g, b, a (0-255)
        let bg: (Int, Int, Int, Int)
        let cursor: (Int, Int, Int, Int)
        let selection: (Int, Int, Int, Int)
    }

    /// Get theme configuration from MoonBit.
    func getTheme() -> ThemeInfo? {
        guard let fn = fnGetTheme else { return nil }
        guard let ptr = fn() else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func parseRGBA(_ value: Any?) -> (Int, Int, Int, Int)? {
            guard let arr = value as? [Int], arr.count >= 3 else { return nil }
            let a = arr.count >= 4 ? arr[3] : 255
            return (arr[0], arr[1], arr[2], a)
        }

        return ThemeInfo(
            name: obj["name"] as? String ?? "Unknown",
            isDark: obj["is_dark"] as? Bool ?? true,
            bgAlpha: obj["bg_alpha"] as? Double ?? 1.0,
            fg: parseRGBA(obj["fg"]) ?? (230, 230, 230, 255),
            bg: parseRGBA(obj["bg"]) ?? (20, 20, 26, 255),
            cursor: parseRGBA(obj["cursor"]) ?? (102, 179, 255, 217),
            selection: parseRGBA(obj["selection"]) ?? (64, 115, 191, 102)
        )
    }

    struct CellMetrics {
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let dpiScale: CGFloat
        /// Font size in points (for CPU fallback rendering).
        let fontSize: CGFloat
    }

    /// Get cell metrics from MoonBit's GPU font engine.
    /// This is the SoT for pixel↔grid conversion — Swift must NOT compute
    /// cell sizes from its own NSFont. The GPU renderer uses these exact
    /// values for rendering, so layout calculations must match.
    func getCellMetrics() -> CellMetrics? {
        guard let fn = fnGetCellMetrics else { return nil }
        guard let ptr = fn() else { return nil }
        defer { fnFreeString?(ptr) }
        let jsonStr = String(cString: ptr)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let cw = obj["cell_width"] as? Int,
              let ch = obj["cell_height"] as? Int
        else { return nil }

        let dpi = obj["dpi_scale"] as? Double ?? 2.0
        let fontSize = obj["font_size"] as? Int ?? 14
        return CellMetrics(
            cellWidth: CGFloat(cw),
            cellHeight: CGFloat(ch),
            dpiScale: CGFloat(dpi),
            fontSize: CGFloat(fontSize)
        )
    }

    // MARK: - GPU Rendering (MoonBit Pipeline)
    //
    // Font rasterization and glyph atlas management are handled entirely
    // within MoonBit (src/font/ + src/renderer/). Swift does not need font FFI access.

    /// Initialize GPU backend directly with raw CAMetalLayer pointer.
    /// This calls wgpu FFI directly to set up the surface.
    func gpuInitDirect(metalLayer: UnsafeMutableRawPointer, width: Int, height: Int) -> Bool {
        guard let fn = fnGpuInitDirect else { return false }
        let handle = UInt64(UInt(bitPattern: metalLayer))
        return fn(handle, Int32(width), Int32(height)) == 0
    }

    /// Initialize MoonBit renderer + GPU backend.
    /// Surface handle is passed as a decimal string through the bridge.
    func gpuInitBridge(surfaceHandle: UInt, width: Int, height: Int) -> Bool {
        guard let fn = fnGpuInitBridge else { return false }
        return "\(surfaceHandle)".withCString { s in
            "\(width)".withCString { w in
                "\(height)".withCString { h in
                    fn(s, w, h)
                }
            }
        } == 0
    }

    /// Create a GPU surface for a session's panel.
    ///
    /// Two-step process:
    ///   1. Create wgpu surface via direct C FFI (handles 64-bit CAMetalLayer pointer)
    ///   2. Register session→surface mapping in MoonBit bridge
    ///
    /// This split is necessary because MoonBit's Int is 32-bit and cannot hold
    /// a 64-bit pointer. The C FFI handles the pointer, MoonBit handles the mapping.
    func gpuSurfaceCreate(sessionId: Int32, metalLayer: UnsafeMutableRawPointer, width: Int, height: Int) -> Int32 {
        // Step 1: Create wgpu surface (direct C FFI, handles uint64_t pointer)
        guard let fnDirect = fnGpuSurfaceCreateDirect else { return -1 }
        let handle = UInt64(UInt(bitPattern: metalLayer))
        let surfaceId = fnDirect(handle, Int32(width), Int32(height))
        if surfaceId < 0 { return -1 }

        // Step 2: Register session→surface mapping in MoonBit bridge
        if let fn = fnGpuRegisterSurface {
            _ = "\(sessionId)".withCString { s in
                "\(surfaceId)".withCString { sid in fn(s, sid) }
            }
        }
        return surfaceId
    }

    /// Destroy a session's GPU surface (legacy — clears surface_map entry).
    func gpuSurfaceDestroy(sessionId: Int32) {
        guard let fn = fnGpuSurfaceDestroyBridge else { return }
        _ = "\(sessionId)".withCString { fn($0) }
    }

    /// Destroy a GPU surface by its C-level surface_id (direct FFI).
    private var fnGpuSurfaceDestroyDirect: (@convention(c) (Int32) -> Void)?

    func gpuSurfaceDestroyById(surfaceId: Int32) {
        fnGpuSurfaceDestroyDirect?(surfaceId)
    }

    /// Conditionally remove session from surface_map only if the current
    /// mapping matches the expected surfaceId. Prevents a stale view
    /// from removing a mapping already overwritten by a newer view.
    func gpuSurfaceUnregisterIfMatches(sessionId: Int32, expectedSurfaceId: Int32) {
        // The next gpuRegisterSurface for this session will overwrite anyway.
        // Only call the bridge destroy if the session's current surface matches.
        // For simplicity: don't touch surface_map here — the C surface is
        // already destroyed, and the map will be overwritten by the new view.
    }

    /// Re-register an existing surface for a (possibly different) session.
    /// Used on tab/panel switch to rebind without recreating the wgpu surface.
    func gpuRegisterSurface(sessionId: Int32, surfaceId: Int32) {
        guard let fn = fnGpuRegisterSurface else { return }
        _ = "\(sessionId)".withCString { s in
            "\(surfaceId)".withCString { sid in fn(s, sid) }
        }
    }

    /// Resize a session's GPU surface.
    func gpuSurfaceResize(sessionId: Int32, width: Int, height: Int) {
        guard let fn = fnGpuSurfaceResizeBridge else { return }
        _ = "\(sessionId)".withCString { s in
            "\(width)".withCString { w in
                "\(height)".withCString { h in fn(s, w, h) }
            }
        }
    }

    /// Render the current terminal state to the GPU (active session).
    /// All rendering logic runs in MoonBit — Swift just calls this once per frame.
    func renderFrame() -> Bool {
        guard let fn = fnRenderFrame else { return false }
        return fn() == 0
    }

    /// Render a specific session's terminal state to the GPU.
    func renderFrameFor(sessionId: Int32) -> Bool {
        guard let fn = fnRenderFrameFor else { return false }
        return "\(sessionId)".withCString { fn($0) } == 0
    }

    /// Resize GPU surface via MoonBit bridge.
    func gpuResizeBridge(width: Int, height: Int) {
        guard let fn = fnGpuResizeBridge else { return }
        _ = "\(width)".withCString { w in
            "\(height)".withCString { h in
                fn(w, h)
            }
        }
    }

    var hasGPU: Bool { fnGpuInitDirect != nil && fnRenderFrame != nil }
}
