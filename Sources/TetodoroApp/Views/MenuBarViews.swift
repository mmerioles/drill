import AppKit
import InkKit
import SwiftUI

/// The menu bar item: a drill curl, plus the countdown while a phase is live.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isActive {
            Text("\(model.phase.isBreak ? "break" : "") \(Copy.clock(model.remaining))"
                .trimmingCharacters(in: .whitespaces))
                .monospacedDigit()
        } else {
            Image(nsImage: Self.drill)
        }
    }

    /// The drill glyph rendered once as a template image, so it tints like a
    /// system icon in light, dark, and tinted menu bars.
    @MainActor static let drill: NSImage = {
        let renderer = ImageRenderer(content: Glyph(.drill, size: 18, boiling: false, lineWidth: 1.7))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "timer", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// The panel under the menu bar item: enough to run a session without
/// opening the window.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Glyph(.drill, size: 16, boiling: model.isRunning, lineWidth: 1.4, tint: Ink.accent)
                Text("tetodoro").font(Ink.word(14)).foregroundStyle(Ink.ink)
                Spacer()
                if let status = Copy.status(model.phase, running: model.isRunning, active: model.isActive) {
                    Text(status).font(Ink.text(12)).foregroundStyle(Ink.faint)
                }
            }

            HStack(alignment: .center) {
                Text(Copy.clock(model.remaining))
                    .font(Ink.digits(34))
                    .foregroundStyle(Ink.ink)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(model.remaining.rounded(.up)))
                Spacer()
                DoodleRing(progress: model.progress, lineWidth: 2, boiling: false)
                    .frame(width: 34, height: 34)
            }

            HStack(spacing: 16) {
                Button(model.isRunning ? "pause" : (model.isActive ? "resume" : "start"), action: model.toggle)
                    .buttonStyle(InkCapsuleStyle(size: 13, minWidth: 64))
                Button("skip", action: model.skip).buttonStyle(.inkLink(selected: false, size: 13))
                if model.isActive {
                    Button("reset", action: model.reset).buttonStyle(.inkLink(selected: false, size: 13))
                }
            }

            Rectangle().fill(Ink.ghost).frame(height: 1)

            HStack(spacing: 5) {
                Text("today").foregroundStyle(Ink.faint)
                Text(Copy.amount(model.heatmap.today)).foregroundStyle(Ink.ink).fontWeight(.medium)
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
