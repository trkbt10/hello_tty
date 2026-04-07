import Cocoa
import SwiftUI

/// Application delegate managing the terminal lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let tabManager = TabManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("hello_tty: application launched")

        if MoonBitBridge.shared.isLoaded {
            NSLog("hello_tty: MoonBit bridge loaded successfully")
        } else {
            NSLog("hello_tty: WARNING — MoonBit bridge not loaded, running in demo mode")
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Configure windows for behind-window blur.
        DispatchQueue.main.async { [self] in
            let theme = self.tabManager.theme
            for window in NSApp.windows {
                window.appearance = theme.appearance
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
            }

            // Self-test mode: run automated UI tests and exit
            if CommandLine.arguments.contains("--self-test") {
                let runner = SelfTestRunner(tabManager: self.tabManager)
                runner.run()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tabManager.closeAll()
        NSLog("hello_tty: application terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
