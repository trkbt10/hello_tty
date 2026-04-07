import Cocoa
import SwiftUI

/// Application delegate managing the terminal lifecycle.
///
/// Following bartleby's pattern:
///   1. Initialize MoonBit bridge (loads dylib)
///   2. Set up terminal state
///   3. Manage PTY subprocess (future: IPC via Unix socket)
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let terminalState = TerminalState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("hello_tty: application launched")

        // Verify bridge is loaded
        if MoonBitBridge.shared.isLoaded {
            NSLog("hello_tty: MoonBit bridge loaded successfully")
        } else {
            NSLog("hello_tty: WARNING — MoonBit bridge not loaded, running in demo mode")
        }

        // Set activation policy to regular (show in dock)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminalState.shutdown()
        NSLog("hello_tty: application terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
