import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.isRequested {
            // Headless mode: no Dock icon and no window, so it doesn't get in the user's way.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
            return
        }
        // Needed when launching outside an .app bundle (e.g. `swift run`): otherwise the window doesn't get focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// The headless self-test mode runs without windows and exits on its own.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !SelfTest.isRequested }
}

@main
struct CleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        SelfTest.runIfRequested(model: AppModel.shared)
    }

    var body: some Scene {
        Window("Cleaner", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                // Different language: rebuild the whole window so every L(...) is evaluated again.
                .id(model.language)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
