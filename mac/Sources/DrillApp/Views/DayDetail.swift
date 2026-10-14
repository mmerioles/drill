import InkKit
import SwiftUI
import DrillCore

/// One day, opened from its square in your year: the total, then each
/// block with when it started, what it was, and how long — a tomato or a
/// stopwatch says which timer it came from.
struct DayDetail: View {
    let day: Date
    let sessions: [FocusSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.formatted(Copy.dayFormat).lowercased())
                    .font(Ink.word(15))
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 16)
                if !sessions.isEmpty {
                    Text(Copy.amount(total))
                        .font(Ink.text(13, .medium))
                        .foregroundStyle(Ink.ink)
                        .monospacedDigit()
                }
            }

            if sessions.isEmpty {
                Text("nothing logged.")
                    .font(Ink.text(13))
                    .foregroundStyle(Ink.faint)
            } else if sessions.count <= 8 {
                list
            } else {
                // A busy day scrolls rather than growing past the screen.
                ScrollView { list }
                    .scrollIndicators(.never)
                    .frame(height: 260)
            }
        }
        .padding(18)
        .frame(width: 280)
        .background(Ink.paper)
        .accessibilityElement(children: .contain)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sessions) { SessionRow(session: $0) }
        }
    }

    private var total: TimeInterval { sessions.reduce(0) { $0 + $1.focusSeconds } }
}

private struct SessionRow: View {
    let session: FocusSession

    var body: some View {
        HStack(spacing: 10) {
            // Stopwatch blocks have no plan; pomodoro blocks do.
            Glyph(session.plannedSeconds == 0 ? .stopwatch : .tomato, size: 13, boiling: false,
                  lineWidth: 1.2, tint: Ink.faint)
            Text(session.startedAt.formatted(Copy.timeFormat).lowercased())
                .foregroundStyle(Ink.faint)
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)
            Text(session.tag ?? "untagged")
                .foregroundStyle(session.tag == nil ? Ink.faint : Ink.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(Copy.amount(session.focusSeconds))
                .foregroundStyle(Ink.ink)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(Ink.text(13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.tag ?? "untagged"), \(Copy.amount(session.focusSeconds)), at \(session.startedAt.formatted(Copy.timeFormat))")
    }
}

/// Today against the daily goal: a small ring that fills, then a check
/// once it's met.
struct GoalRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            if progress >= 1 {
                Glyph(.check, size: 14, boiling: false, lineWidth: 1.6, tint: Ink.accent)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                Circle().stroke(Ink.ghost, lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Ink.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .transition(.opacity)
            }
        }
        .frame(width: 11, height: 11)
        .animation(.spring(response: 0.42, dampingFraction: 0.6), value: progress >= 1)
        .animation(Ink.ease, value: progress)
    }
}
