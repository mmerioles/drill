import Foundation
import Observation

/// Shuzo Matsuoka's cheer-up videos. The list is shared/inspo.json (see
/// scripts/make-inspo.sh). The shuffle matches web/static/inspo.js, so every
/// device shows the same videos on the same day.
enum Inspo {
    struct Video: Identifiable {
        var number: Int
        var youtube: String
        /// False for skits, which only show in the full list.
        var daily: Bool
        var title: String
        var japanese: String

        var id: String { youtube }
        var url: URL { URL(string: "https://www.youtube.com/watch?v=\(youtube)")! }
    }

    static let perDay = 5

    /// Like 20260928: the watched key and the shuffle seed.
    static func day(_ date: Date = .now, calendar: Calendar = .current) -> Int {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return d.year! * 10000 + d.month! * 100 + d.day!
    }

    /// A daily handful, skipping videos watched before today (so today's
    /// list doesn't shift). Daily videos first, then skits, then start over.
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

    /// Bit-for-bit the same as inspo.js.
    private static func mulberry32(_ a: inout UInt32) -> UInt32 {
        a &+= 0x6D2B_79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return t ^ (t >> 14)
    }
}

/// Which videos were opened, and on which day. Local only.
@Observable @MainActor
final class Watched {
    private static let key = "drill.inspo.seen"
    private let defaults: UserDefaults
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
