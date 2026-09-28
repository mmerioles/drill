import InkKit
import SwiftUI

/// Videos to watch when focus runs thin: today's handful, and all of them
/// with the ones you've watched filled in.
struct InspoView: View {
    private enum Page { case today, all }

    @State private var page = Page.today
    @State private var watched = Watched()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("inspo").font(Ink.word(20)).foregroundStyle(Ink.ink)
                Spacer()
                HStack(spacing: 14) {
                    Button("today") { page = .today }.buttonStyle(.inkLink(selected: page == .today))
                    Button("all") { page = .all }.buttonStyle(.inkLink(selected: page == .all))
                }
            }
            switch page {
            case .today:
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Inspo.today(skipping: watched.seen(before: Inspo.day()))) { InspoRow(video: $0, numbered: false) }
                }
            case .all:
                AllVideos()
            }
        }
        .environment(watched)
        .padding(28)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Ink.paper)
    }
}

/// Every video as a square, filled once watched, then the full list.
private struct AllVideos: View {
    @Environment(Watched.self) private var watched
    @Environment(\.openURL) private var openURL

    private let columns = Array(repeating: GridItem(.fixed(11), spacing: 3.5), count: 25)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 3.5) {
                    ForEach(Inspo.videos) { video in
                        Button {
                            watched.mark(video)
                            openURL(video.url)
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(watched.contains(video) ? Ink.accent : Ink.ink.opacity(0.055))
                                .frame(width: 11, height: 11)
                        }
                        .buttonStyle(.plain)
                        .help("\(video.number). \(video.title)")
                    }
                }
                Text("\(watched.count) of \(Inspo.videos.count) watched")
                    .font(Ink.text(13)).foregroundStyle(Ink.faint)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Inspo.videos) { InspoRow(video: $0, numbered: true) }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 360)
        }
        .animation(Ink.ease, value: watched.count)
    }
}

private struct InspoRow: View {
    let video: Inspo.Video
    let numbered: Bool
    @Environment(Watched.self) private var watched
    @Environment(\.openURL) private var openURL
    @State private var hovered = false

    var body: some View {
        Button {
            watched.mark(video)
            openURL(video.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if numbered {
                    Text(String(format: "%03d", video.number))
                        .font(Ink.text(12).monospacedDigit()).foregroundStyle(Ink.faint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(video.title).font(Ink.text(14, .medium)).foregroundStyle(Ink.ink)
                        if watched.contains(video) {
                            Circle().fill(Ink.accent).frame(width: 5, height: 5)
                        }
                    }
                    Text(video.japanese).font(Ink.text(13))
                        .foregroundStyle(hovered ? Ink.ink : Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
