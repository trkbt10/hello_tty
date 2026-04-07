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

    // Session management
    private typealias CreateSessionFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias DestroySessionFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias SwitchSessionFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias ListSessionsFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias GetActiveSessionFn = @convention(c) () -> Int32

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

    // Direct GPU FFI (for surface init that needs raw pointer)
    private typealias GpuInitDirectFn = @convention(c) (UInt64, Int32, Int32) -> Int32

    // Loaded function pointers
    private var fnInit: InitFn?
    private var fnShutdown: ShutdownFn?
    private var fnProcessOutput: ProcessOutputFn?
    private var fnHandleKey: HandleKeyFn?
    private var fnGetGrid: GetGridFn?
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

    // Session management
    private var fnCreateSession: CreateSessionFn?
    private var fnDestroySession: DestroySessionFn?
    private var fnSwitchSession: SwitchSessionFn?
    private var fnListSessions: ListSessionsFn?
    private var fnGetActiveSession: GetActiveSessionFn?

    // Theme
    private var fnGetTheme: GetThemeFn?

    // Font
    private var fnFontInit: FontInitFn?
    private var fnFontRasterize: FontRasterizeFn?
    private var fnFontGetMetrics: FontGetMetricsFn?
    private var fnFontShutdown: FontShutdownFn?

    // GPU (MoonBit pipeline bridge)
    private var fnGpuInitBridge: GpuInitBridgeFn?
    private var fnRenderFrame: RenderFrameFn?
    private var fnGpuResizeBridge: GpuResizeBridgeFn?
    // Direct GPU FFI (for raw surface init)
    private var fnGpuInitDirect: GpuInitDirectFn?

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

        // Theme
        fnGetTheme = sym("hello_tty_get_theme")

        // Font
        fnFontInit = sym("hello_tty_font_init")
        fnFontRasterize = sym("hello_tty_font_rasterize")
        fnFontGetMetrics = sym("hello_tty_font_get_metrics")
        fnFontShutdown = sym("hello_tty_font_shutdown")

        // GPU (MoonBit pipeline bridge)
        fnGpuInitBridge = sym("hello_tty_gpu_init_bridge")
        fnRenderFrame = sym("hello_tty_render_frame")
        fnGpuResizeBridge = sym("hello_tty_gpu_resize_bridge")
        // Direct GPU FFI (for raw surface init)
        fnGpuInitDirect = sym("hello_tty_gpu_init")
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

    enum KeyClassification: Int32 {
        case directToPty = 0
        case forwardToIme = 1
        case clipboardCopy = 2
        case clipboardPaste = 3
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
        return KeyClassification(rawValue: result) ?? .forwardToIme
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

    // MARK: - Theme (MoonBit SoT)

    struct ThemeInfo {
        let name: String
        let isDark: Bool
        let bgAlpha: Double
        let fg: (Int, Int, Int)
        let bg: (Int, Int, Int)
        let cursor: (Int, Int, Int)
        let selection: (Int, Int, Int)
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

        func parseRGB(_ value: Any?) -> (Int, Int, Int)? {
            guard let arr = value as? [Int], arr.count == 3 else { return nil }
            return (arr[0], arr[1], arr[2])
        }

        return ThemeInfo(
            name: obj["name"] as? String ?? "Unknown",
            isDark: obj["is_dark"] as? Bool ?? true,
            bgAlpha: obj["bg_alpha"] as? Double ?? 1.0,
            fg: parseRGB(obj["fg"]) ?? (230, 230, 230),
            bg: parseRGB(obj["bg"]) ?? (20, 20, 26),
            cursor: parseRGB(obj["cursor"]) ?? (102, 179, 255),
            selection: parseRGB(obj["selection"]) ?? (64, 115, 191)
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

    /// Render the current terminal state to the GPU.
    /// All rendering logic runs in MoonBit — Swift just calls this once per frame.
    func renderFrame() -> Bool {
        guard let fn = fnRenderFrame else { return false }
        return fn() == 0
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
