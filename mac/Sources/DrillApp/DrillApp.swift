import AppKit
import InkKit
import SwiftUI

@main
struct DrillApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel
    @State private var updater: Updater
    @State private var sync: Sync

    init() {
        Render.runIfAsked()
        Rename.carryOver()
        let model = AppModel.live()
        let sync = Sync(store: model.store, deviceID: model.deviceID, onPulled: { [weak model] in model?.reload() })
        model.onLogged = { [weak sync] in sync?.logged() }
        // Checks run from launch, whether or not the main window opens.
        let updater = Updater()
        updater.start()
        sync.start()
        _model = State(initialValue: model)
        _updater = State(initialValue: updater)
        _sync = State(initialValue: sync)
    }

    var body: some Scene {
        Window("drill", id: "main") {
            MainView()
                .environment(model)
                .environment(updater)
                .environment(sync)
                .frame(width: MainView.windowSize.width, height: MainView.windowSize.height)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            TimerCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check() } }
                    .disabled(!updater.isEnabled)
            }
        }

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
            SettingsView().environment(model).environment(updater).environment(sync)
        }
    }
}

private struct TimerCommands: Commands {
    let model: AppModel
    @FocusedValue(\.palette) private var palette

    var body: some Commands {
        CommandMenu("Timer") {
            Button("Commands…") { palette?.wrappedValue.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(palette == nil)
            Divider()
            Button(model.isRunning ? "Pause" : (model.isActive ? "Resume" : "Start"), action: model.toggle)
                .keyboardShortcut(.return, modifiers: .command)
            Button("Skip", action: model.skip)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model.isStopwatch)
            Button(Copy.reset(intervals: model.isIntervals).capitalized, action: model.reset)
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Switch to \(Copy.modeName(model.mode.next).capitalized)", action: model.switchMode)
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.isActive)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The timer keeps running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
