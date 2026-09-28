import AppKit
import InkKit
import SwiftUI

@main
struct TetodoroApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        Window("tetodoro", id: "main") {
            MainView()
                .environment(model)
                .frame(width: 780, height: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { TimerCommands(model: model) }

        Window("inspo", id: "inspo") {
            InspoView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

private struct TimerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Timer") {
            Button(model.isRunning ? "Pause" : "Start", action: model.toggle)
                .keyboardShortcut(.return, modifiers: .command)
            Button("Skip", action: model.skip)
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Reset", action: model.reset)
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The timer keeps running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
