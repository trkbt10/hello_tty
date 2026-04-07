import Cocoa
import SwiftUI

/// Application delegate managing the terminal lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let tabManager = TabManager(theme: .midnight)

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
        //
        // The blur itself comes from the NSVisualEffectView
        // (VisualEffectBackground) in the SwiftUI view hierarchy.
        // The window must cooperate by:
        //
        //   1. isOpaque = false — tells the compositor this window has
        //      transparent regions that need compositing.
        //   2. backgroundColor = .clear — the window's own fill must be
        //      fully transparent, otherwise it paints OVER the blur.
        //      (Setting it to a semi-transparent NSColor gives see-through
        //      but NO blur — that's the original bug.)
        //   3. titlebarAppearsTransparent = true — makes the titlebar
        //      area transparent so the NSVisualEffectView blur (which
        //      extends under the titlebar via .ignoresSafeArea()) shows
        //      through the toolbar chrome.
        //   4. fullSizeContentView — lets content (including the blur
        //      view) extend into the titlebar region.
        //
        DispatchQueue.main.async { [self] in
            let theme = self.tabManager.theme
            for window in NSApp.windows {
                window.appearance = theme.appearance
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                // Do NOT set isMovableByWindowBackground — it intercepts
                // mouse drags before NSView.mouseDown, preventing text selection.
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
