import Foundation
import Observation

/// Shuzo Matsuoka's short cheer-up videos: the "〜あなたに" messages from
/// his official YouTube channel, with the clams clip first. The list lives in
/// Support/inspo.json; scripts/make-inspo.sh writes InspoVideos.swift from
/// it. The shuffle is kept in step with web/static/inspo.js, so every device
/// shows the same few videos on the same day.
enum Inspo {
    struct Video: Identifiable {
        var number: Int
        var youtube: String
        /// In the daily rotation. The rest are sponsor and travel skits,
        /// kept for the full list.
        var daily: Bool
        var title: String
        var japanese: String

        var id: String { youtube }
        var url: URL { URL(string: "https://www.youtube.com/watch?v=\(youtube)")! }
    }

    static let perDay = 5

    /// A day as a number, like 20260928: the key for watched videos and
    /// the seed for the daily shuffle.
    static func day(_ date: Date = .now, calendar: Calendar = .current) -> Int {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return d.year! * 10000 + d.month! * 100 + d.day!
    }

    /// A fresh handful each day, seeded by the date, leaving out anything
    /// watched before today. Cheer-up messages come first, the skits once
    /// those run out, and the full rotation again once you've seen everything.
    /// Videos watched today stay put, so the list doesn't shift under you.
    static func today(skipping seen: Set<String>, on day: Int = day()) -> [Video] {
        var seed = UInt32(day)
        let daily = shuffled(videos.filter(\.daily), &seed)
        let rest = shuffled(videos.filter { !$0.daily }, &seed)
        let fresh = (daily + rest).filter { !seen.contains($0.youtube) }
        return Array((fresh.isEmpty ? daily : fresh).prefix(perDay))
    }

    private static func shuffled(_ videos: [Video], _ seed: inout UInt32) -> [Video] {
        var pool = videos
        for i in stride(from: pool.count - 1, to: 0, by: -1) {
            let j = Int(mulberry32(&seed) % UInt32(i + 1))
            pool.swapAt(i, j)
        }
        return pool
    }

    /// A tiny seeded generator, bit-for-bit the same as the one in inspo.js.
    private static func mulberry32(_ a: inout UInt32) -> UInt32 {
        a &+= 0x6D2B_79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return t ^ (t >> 14)
    }
}

/// Which videos you've opened, and on which day. Local to this Mac.
@Observable @MainActor
final class Watched {
    private static let key = "drill.inspo.seen"
    private let defaults: UserDefaults
    /// YouTube id to the day it was first opened.
    private var days: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        days = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
    }

    var count: Int { days.count }

    func contains(_ video: Inspo.Video) -> Bool { days[video.youtube] != nil }

    func seen(before day: Int) -> Set<String> {
        Set(days.filter { $0.value < day }.keys)
    }

    func mark(_ video: Inspo.Video) {
        guard days[video.youtube] == nil else { return }
        days[video.youtube] = Inspo.day()
        defaults.set(days, forKey: Self.key)
    }
}
