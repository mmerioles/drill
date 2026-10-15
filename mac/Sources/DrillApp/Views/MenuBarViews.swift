import AppKit
import InkKit
import SwiftUI

/// The menu bar item: a drill curl, plus the countdown while a phase is live.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isActive {
            Text("\(word) \(model.clock)".trimmingCharacters(in: .whitespaces))
                .monospacedDigit()
        } else {
            Image(nsImage: Self.drill)
                .accessibilityLabel("drill")
        }
    }

    /// Nothing for running focus or stopwatch: the digits say enough.
    private var word: String {
        if !model.isRunning { return "paused" }
        if model.isStopwatch { return "" }
        return model.phase.isBreak ? "break" : ""
    }

    /// A template image, so it tints like a system icon.
    @MainActor static let drill: NSImage = {
        let renderer = ImageRenderer(content: Glyph(.drill, size: 18, boiling: false, lineWidth: 1.7))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "timer", accessibilityDescription: nil)!
        image.isTemplate = true
        image.accessibilityDescription = "drill"
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Glyph(.drill, size: 16, boiling: model.isRunning, lineWidth: 1.4, tint: Ink.accent)
                Text("drill").font(Ink.word(14)).foregroundStyle(Ink.ink)
                Spacer()
                if let status = model.status {
                    Text(status).font(Ink.text(12)).foregroundStyle(Ink.faint)
                }
            }

            HStack(alignment: .center) {
                Text(model.clock)
                    .font(Ink.digits(34))
                    .foregroundStyle(Ink.ink)
                    .contentTransition(.numericText(countsDown: !model.isStopwatch))
                    .animation(.snappy, value: model.shownSecond)
                    .modifier(SpokenTimer())
                Spacer()
                DoodleRing(progress: model.progress, lineWidth: 2, boiling: false)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 16) {
                Button(Copy.toggle(running: model.isRunning, active: model.isActive), action: model.toggle)
                    .buttonStyle(InkCapsuleStyle(size: 13, minWidth: 64))
                if !model.isStopwatch {
                    Button("skip", action: model.skip).buttonStyle(.inkLink(selected: false, size: 13))
                }
                if model.isActive {
                    Button("reset", action: model.reset).buttonStyle(.inkLink(selected: false, size: 13))
                }
            }

            Rectangle().fill(Ink.ghost).frame(height: 1)

            HStack(spacing: 5) {
                Text("today").foregroundStyle(Ink.faint)
                Text(Copy.amount(model.todayTotal)).foregroundStyle(Ink.ink).fontWeight(.medium)
                if model.dailyGoal > 0 {
                    Text("/ \(Copy.amount(model.dailyGoal))").foregroundStyle(Ink.faint)
                    GoalRing(progress: model.todayTotal / model.dailyGoal)
                }
                Spacer()
                HStack(spacing: 14) {
                    Button("open") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    Button("quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.inkLink(selected: false, size: 13))
            }
            .font(Ink.text(13))
        }
        .padding(18)
        .frame(width: 260)
        .background(Ink.paper)
    }
}
