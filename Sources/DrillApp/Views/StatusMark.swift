import SwiftUI

/// How something stands, in one small mark: a spinner while working, a
/// yellow dot while it waits on you, a green check once it's done. Changes
/// between them pop, with a little spring.
struct StatusMark: View {
    enum Status: Equatable { case none, working, pending, done }

    let status: Status
    /// A slow breath on the yellow dot, for when it's waiting on something
    /// that'll happen by itself.
    var breathing = false

    var body: some View {
        ZStack {
            switch status {
            case .working:
                Spinner()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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

/// An open ring turning at an even pace.
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
