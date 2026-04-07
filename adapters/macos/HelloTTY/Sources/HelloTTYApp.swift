import SwiftUI

/// hello_tty macOS application entry point.
///
/// Architecture (following bartleby's pattern):
///   SwiftUI App → AppDelegate → TerminalState → MoonBitBridge → libhello_tty.dylib
///
/// The MoonBit dylib provides the terminal core (VT parser, terminal state,
/// color resolution). The Swift layer handles:
///   - Window management and rendering (CoreText + CoreGraphics)
///   - Keyboard/mouse input
///   - PTY subprocess management
///   - Clipboard integration
@main
struct HelloTTYApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.terminalState)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 640, height: 480)
    }
}

/// Main content view wrapping the terminal renderer.
struct ContentView: View {
    @EnvironmentObject var state: TerminalState

    var body: some View {
        TerminalView(state: state)
            .background(Color.black)
            .onAppear {
                state.initialize()
                // Demo: process a sample escape sequence
                state.processOutput("\u{1b}[31mhello_tty\u{1b}[0m — MoonBit Terminal Emulator\r\n")
                state.processOutput("\u{1b}[32m$\u{1b}[0m ")
            }
            .onChange(of: state.title) { newTitle in
                // Update window title from OSC 0/2
                if let window = NSApp.mainWindow {
                    window.title = newTitle.isEmpty ? "hello_tty" : newTitle
                }
            }
    }
}
