import InkKit
import SwiftUI

/// A short list of videos to watch when focus runs thin: Shuzo Matsuoka's
/// challenge messages, from his own site.
struct InspoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("inspo").font(Ink.word(20)).foregroundStyle(Ink.ink)
                Text("shuzo matsuoka, never give up · in japanese")
                    .font(Ink.text(13)).foregroundStyle(Ink.faint)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Inspo.today(), id: \.url) { InspoRow(video: $0) }
            }
        }
        .padding(28)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Ink.paper)
    }
}

private struct InspoRow: View {
    let video: Inspo.Video
    @State private var hovered = false

    var body: some View {
        Link(destination: video.url) {
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(Ink.text(14, .medium)).foregroundStyle(Ink.ink)
                Text(video.summary).font(Ink.text(13))
                    .foregroundStyle(hovered ? Ink.ink : Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Kept in step with web/static/inspo.js, pool and shuffle both, so every
/// device shows the same few videos on the same day.
enum Inspo {
    struct Video {
        var title: String
        var summary: String
        var url: URL
    }

    static let perDay = 5

    /// A fresh handful each day: the pool shuffled with the date as the seed.
    static func today(_ now: Date = .now, calendar: Calendar = .current) -> [Video] {
        let d = calendar.dateComponents([.year, .month, .day], from: now)
        var seed = UInt32(d.year! * 10000 + d.month! * 100 + d.day!)
        var pool = videos
        for i in stride(from: pool.count - 1, to: 0, by: -1) {
            let j = Int(mulberry32(&seed) % UInt32(i + 1))
            pool.swapAt(i, j)
        }
        return Array(pool.prefix(perDay))
    }

    /// A tiny seeded generator, bit-for-bit the same as the one in inspo.js.
    private static func mulberry32(_ a: inout UInt32) -> UInt32 {
        a &+= 0x6D2B_79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return t ^ (t >> 14)
    }

    private static func video(_ title: String, _ summary: String, _ slug: String) -> Video {
        Video(title: title, summary: summary,
              url: URL(string: "https://www.shuzo.co.jp/challenge_message/\(slug)")!)
    }

    static let videos = [
        video("who makes your limits?", "you do. before you say “i can’t”, try once more.", "matsuoka29"),
        video("hardship into happiness", "add one stroke to 辛 and it becomes 幸. one more push gets you through.", "matsuoka18"),
        video("don’t fear change", "if you want to reach the world, you have to be willing to change.", "matsuoka27"),
        video("always 40-0 in your heart", "keep the calm of someone way ahead, whatever the score.", "matsuoka16"),
        video("your own clock", "switch on, switch off, and use the time in between.", "matsuoka15"),
        video("we’re watching you in ten years", "it’s not about winning today. it’s who you’re becoming.", "matsuoka28"),
        video("the ones who repeat themselves care", "people who tell you the same thing again really mean it.", "matsuoka35"),
        video("don’t be afraid!", "a short one. exactly what it says.", "matsuoka36"),
        video("advantage smile", "smile through the hard part. it moves you forward.", "matsuoka17"),
        video("love beats perfect conditions", "you don’t need the best setup. care makes it the best place.", "matsuoka30"),
        video("basics first", "you can’t move forward without the fundamentals.", "matsuoka31"),
        video("decide", "know when to keep it steady and when to go for it.", "matsuoka10"),
        video("don’t let the ball run you", "take the lead. run your own life, don’t let it run you.", "matsuoka09"),
        video("nice & easy, nice & smooth", "keep it simple. no extra force.", "matsuoka37"),
    ]
}
