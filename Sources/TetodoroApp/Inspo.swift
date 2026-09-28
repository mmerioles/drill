import Foundation
import Observation

/// Shuzo Matsuoka's challenge messages, from his own site, numbered as he
/// numbered them. Kept in step with web/static/inspo.js, list and shuffle
/// both, so every device shows the same few videos on the same day.
enum Inspo {
    struct Video: Identifiable {
        var number: Int
        /// In the daily rotation. The rest are tennis technique, kept for
        /// the full list.
        var daily: Bool
        var title: String
        var summary: String
        var slug: String

        var id: Int { number }
        var url: URL { URL(string: "https://www.shuzo.co.jp/challenge_message/\(slug)")! }
    }

    static let perDay = 5

    /// A fresh handful each day: the daily pool shuffled with the date as
    /// the seed.
    static func today(_ now: Date = .now, calendar: Calendar = .current) -> [Video] {
        let d = calendar.dateComponents([.year, .month, .day], from: now)
        var seed = UInt32(d.year! * 10000 + d.month! * 100 + d.day!)
        var pool = videos.filter(\.daily)
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

    static let videos: [Video] = [
        .init(number: 1, daily: true, title: "minus into plus",
              summary: "make a habit of turning the negatives into positives.", slug: "02"),
        .init(number: 2, daily: false, title: "take on your dream",
              summary: "what to do now if you want to hold your own in the world.", slug: "002"),
        .init(number: 3, daily: false, title: "aim for the grand slams",
              summary: "not number one. the top 100, and the main draw.", slug: "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%913%e7%9b%ae%e6%8c%87%e3%81%9b%e3%82%b0%e3%83%a9%e3%83%b3%e3%83%89%e3%82%b9%e3%83%a9%e3%83%a0"),
        .init(number: 4, daily: false, title: "who raises a player",
              summary: "not the coaches. your family and your home coach.", slug: "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%914%e9%81%b8%e6%89%8b%e3%82%92%e8%82%b2%e3%81%a6%e3%82%8b%e3%81%ae%e3%81%af"),
        .init(number: 5, daily: false, title: "the road to the world",
              summary: "there’s something to do at every age on the way up.", slug: "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%915%e4%b8%96%e7%95%8c%e3%81%b8%e3%81%ae%e9%81%93"),
        .init(number: 6, daily: false, title: "tennis breathing",
              summary: "how you breathe changes how you play.", slug: "matsuoka06"),
        .init(number: 7, daily: true, title: "think! don’t think!",
              summary: "think if it changes things. if it can’t, let it go.", slug: "matsuoka07"),
        .init(number: 8, daily: true, title: "set your goals",
              summary: "plan the week, then plan each day.", slug: "matsuoka08"),
        .init(number: 9, daily: true, title: "don’t let the ball run you",
              summary: "take the lead. run your own life, don’t let it run you.", slug: "matsuoka09"),
        .init(number: 10, daily: true, title: "decide",
              summary: "know when to keep it steady and when to go for it.", slug: "matsuoka10"),
        .init(number: 11, daily: false, title: "your tennis moves forward",
              summary: "meet the ball out in front.", slug: "matsuoka11"),
        .init(number: 12, daily: false, title: "attack with your feet",
              summary: "footwork, and why the first step matters.", slug: "matsuoka12"),
        .init(number: 13, daily: true, title: "just listen",
              summary: "when you can’t focus, listen to the ball and the racket. it calms you.", slug: "matsuoka13"),
        .init(number: 14, daily: false, title: "the three brothers",
              summary: "serve, return and the chance ball, and how they connect.", slug: "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%9114%e8%82%b2%e3%81%a6%e3%82%88%e3%81%86%e3%83%86%e3%83%8b%e3%82%b93%e5%85%84%e5%bc%9f"),
        .init(number: 15, daily: true, title: "your own clock",
              summary: "switch on, switch off, and use the time in between.", slug: "matsuoka15"),
        .init(number: 16, daily: true, title: "always 40-0 in your heart",
              summary: "keep the calm of someone way ahead, whatever the score.", slug: "matsuoka16"),
        .init(number: 17, daily: true, title: "advantage smile",
              summary: "smile through the hard part. it moves you forward.", slug: "matsuoka17"),
        .init(number: 18, daily: true, title: "hardship into happiness",
              summary: "add one stroke to 辛 and it becomes 幸. one more push gets you through.", slug: "matsuoka18"),
        .init(number: 19, daily: false, title: "no sorries needed",
              summary: "you don’t have to keep apologising.", slug: "matsuoka19"),
        .init(number: 20, daily: false, title: "ready changes everything",
              summary: "how you stand ready changes your tennis.", slug: "matsuoka20"),
        .init(number: 21, daily: false, title: "show me your shoulders",
              summary: "form you can practise without a racket.", slug: "matsuoka21"),
        .init(number: 22, daily: false, title: "timing matters",
              summary: "in tennis, timing is everything.", slug: "matsuoka22"),
        .init(number: 23, daily: false, title: "hit heavy",
              summary: "to hold up in the world, a heavy ball beats a fast one.", slug: "matsuoka23"),
        .init(number: 24, daily: false, title: "modern tennis",
              summary: "how to hit with real power.", slug: "matsuoka24"),
        .init(number: 25, daily: false, title: "wide stance, big base",
              summary: "build a wide, steady foundation.", slug: "matsuoka25"),
        .init(number: 26, daily: false, title: "200 km/h, bring it on",
              summary: "welcoming a bullet-train serve.", slug: "matsuoka26"),
        .init(number: 27, daily: true, title: "don’t fear change",
              summary: "if you want to reach the world, you have to be willing to change.", slug: "matsuoka27"),
        .init(number: 28, daily: true, title: "we’re watching you in ten years",
              summary: "it’s not about winning today. it’s who you’re becoming.", slug: "matsuoka28"),
        .init(number: 29, daily: true, title: "who makes your limits?",
              summary: "you do. before you say “i can’t”, try once more.", slug: "matsuoka29"),
        .init(number: 30, daily: true, title: "love beats perfect conditions",
              summary: "you don’t need the best setup. care makes it the best place.", slug: "matsuoka30"),
        .init(number: 31, daily: true, title: "basics first",
              summary: "you can’t move forward without the fundamentals.", slug: "matsuoka31"),
        .init(number: 32, daily: false, title: "heart, skill, body, and eyes",
              summary: "why how you use your eyes matters.", slug: "matsuoka32"),
        .init(number: 33, daily: false, title: "volley with a can",
              summary: "a tin can trick for feeling the volley.", slug: "matsuoka33"),
        .init(number: 34, daily: false, title: "make the space yours",
              summary: "take up more of your own space and your tennis changes.", slug: "matsuoka34"),
        .init(number: 35, daily: true, title: "the ones who repeat themselves care",
              summary: "people who tell you the same thing again really mean it.", slug: "matsuoka35"),
        .init(number: 36, daily: true, title: "don’t be afraid!",
              summary: "a short one. exactly what it says.", slug: "matsuoka36"),
        .init(number: 37, daily: true, title: "nice & easy, nice & smooth",
              summary: "keep it simple. no extra force.", slug: "matsuoka37"),
    ]
}

/// Which videos you've opened, by number. Local to this Mac.
@Observable @MainActor
final class Watched {
    private static let key = "tetodoro.inspo.watched"
    private let defaults: UserDefaults
    private(set) var numbers: Set<Int>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        numbers = Set(defaults.array(forKey: Self.key) as? [Int] ?? [])
    }

    func contains(_ video: Inspo.Video) -> Bool { numbers.contains(video.number) }

    func mark(_ video: Inspo.Video) {
        guard numbers.insert(video.number).inserted else { return }
        defaults.set(numbers.sorted(), forKey: Self.key)
    }
}
