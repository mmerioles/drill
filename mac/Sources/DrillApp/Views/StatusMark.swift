import InkKit
import SwiftUI

/// A spinner, a yellow dot, a green check or a red cross.
struct StatusMark: View {
    enum Status: Equatable { case none, working, pending, done, failed }

    let status: Status
    /// Pulses the yellow dot.
    var breathing = false

    var body: some View {
        ZStack {
            switch status {
            case .working:
                Spinner()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Ink.ok)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Ink.bad)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .pending:
                Dot(breathing: breathing)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .none:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
        .animation(.spring(response: 0.42, dampingFraction: 0.58), value: status)
    }
}

private struct Dot: View {
    let breathing: Bool
    @State private var out = false

    var body: some View {
        Circle().fill(.yellow)
            .frame(width: 10, height: 10)
            .scaleEffect(out ? 0.78 : 1)
            .opacity(out ? 0.6 : 1)
            .animation(breathing ? .easeInOut(duration: 1.1).repeatForever() : .default, value: out)
            .onAppear { if breathing { out = true } }
    }
}

private struct Spinner: View {
    @State private var turned = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(turned ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turned)
            .onAppear { turned = true }
            .transition(.opacity)
    }
}
