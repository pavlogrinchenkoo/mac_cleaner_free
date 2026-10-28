import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.isRequested {
            // Безголовий режим: без Dock і без вікна, щоб не заважати користувачу.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
            return
        }
        // Потрібно, коли запускаємо не з .app (наприклад `swift run`): інакше вікно не отримує фокус.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Безголовий режим самоперевірки живе без вікон і завершується сам.
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
                // Інша мова: перебудовуємо все вікно, щоб кожен L(...) обчислився заново.
                .id(model.language)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
