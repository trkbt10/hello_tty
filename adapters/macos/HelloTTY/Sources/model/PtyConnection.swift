import Foundation

/// Owns a PTY master file descriptor and drives the I/O read loop.
///
/// Responsibilities:
///   - Start/stop the background read thread
///   - Poll + batch-read from the PTY master fd
///   - Write escape sequences and raw text to the PTY
///   - LF→CR conversion for shell compatibility
///
/// NOT responsible for:
///   - Parsing PTY output (that's MoonBit's job)
///   - Knowing which session this belongs to
///   - UI/SwiftUI concerns
class PtyConnection {
    /// PTY master file descriptor. -1 if not connected.
    private(set) var masterFd: Int32 = -1
    private var thread: Thread?
    private var running = false

    private let bridge = MoonBitBridge.shared

    /// Called on the main thread when data is read from the PTY.
    /// The closure receives the decoded UTF-8 string.
    var onOutput: ((String) -> Void)?

    /// Called when the PTY connection ends (EOF or error).
    var onDisconnect: (() -> Void)?

    /// Start the PTY I/O read loop with an already-spawned master_fd.
    func start(masterFd: Int32) {
        self.masterFd = masterFd
        running = true
        NSLog("hello_tty: PTY loop started, master_fd=%d", masterFd)

        thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread?.name = "hello_tty.pty_reader.\(masterFd)"
        thread?.start()
    }

    /// Stop the PTY I/O loop.
    /// Does NOT close the fd — MoonBit's destroy_session handles that.
    func stop() {
        running = false
        masterFd = -1
    }

    var isConnected: Bool { masterFd >= 0 && running }

    /// Write raw data to the PTY, converting LF to CR for shell compatibility.
    func write(_ data: Data) {
        guard masterFd >= 0 else { return }
        var bytes = [UInt8](data)
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A { bytes[i] = 0x0D }
        }
        _ = bridge.ptyWrite(masterFd: masterFd, data: Data(bytes))
    }

    /// Write a string to the PTY.
    func writeText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        write(data)
    }

    /// Write an escape sequence (from handleKey) to the PTY.
    func writeEscapeSequence(_ seq: String) {
        guard let data = seq.data(using: .utf8) else { return }
        write(data)
    }

    // MARK: - Background read loop

    /// IMPORTANT: MoonBit's GC is NOT thread-safe. Only pure-C functions
    /// (ptyPoll, ptyRead) may be called from this background thread.
    private func readLoop() {
        let fd = masterFd
        while running {
            let pollResult = bridge.ptyPoll(masterFd: fd, timeoutMs: 16)
            if pollResult > 0 {
                var accumulated = Data()
                while true {
                    guard let data = bridge.ptyRead(masterFd: fd) else {
                        running = false
                        break
                    }
                    accumulated.append(data)
                    let moreResult = bridge.ptyPoll(masterFd: fd, timeoutMs: 0)
                    if moreResult <= 0 { break }
                }
                if !running { break }
                if accumulated.isEmpty { continue }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.running else { return }
                    if let str = String(data: accumulated, encoding: .utf8) {
                        self.onOutput?(str)
                    }
                }
            } else if pollResult == -2 {
                running = false
                DispatchQueue.main.async { [weak self] in
                    self?.onDisconnect?()
                }
                break
            }
        }
        NSLog("hello_tty: PTY read loop ended (fd=%d)", fd)
    }
}
