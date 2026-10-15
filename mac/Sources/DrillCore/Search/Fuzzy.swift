import Foundation

/// The command palette's matcher: greedy, left to right, favouring word starts and runs.
public enum Fuzzy {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Character offsets into the text, for highlighting.
        public let indices: [Int]
    }

    public static func score(_ query: String, _ text: String) -> Int? {
        match(query, text)?.score
    }

    public static func match(_ query: String, _ text: String) -> Match? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return Match(score: 0, indices: []) }
        let t = Array(text.lowercased())
        var indices: [Int] = []
        var score = 0
        var from = 0
        for c in q {
            guard let i = t[from...].firstIndex(of: c) else { return nil }
            score += 1
            if i == 0 || " -_/".contains(t[i - 1]) { score += 5 }
            if let last = indices.last, i == last + 1 { score += 3 }
            indices.append(i)
            from = i + 1
        }
        return Match(score: score - indices[0], indices: indices)
    }
}

/// A palette row: what it says and what else finds it. Actions live with the UI.
public struct PaletteItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let hint: String?

    public init(id: String, title: String, keywords: [String] = [], hint: String? = nil) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.hint = hint
    }
}

public struct PaletteResult: Equatable, Sendable {
    public let item: PaletteItem
    public let score: Int
    /// Title characters to draw in full ink; empty when a keyword matched.
    public let highlights: [Int]

    public init(item: PaletteItem, score: Int, highlights: [Int]) {
        self.item = item
        self.score = score
        self.highlights = highlights
    }
}

public enum Palette {
    /// Matches by score, ties in list order. An empty query lists the recently
    /// run (most recent first, up to 5), then everything else in order.
    public static func rank(_ items: [PaletteItem], query: String, recent: [String] = []) -> [PaletteResult] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let first = recent.compactMap { id in items.first { $0.id == id } }.prefix(5)
            let firstIDs = Set(first.map(\.id))
            return (Array(first) + items.filter { !firstIDs.contains($0.id) })
                .map { PaletteResult(item: $0, score: 0, highlights: []) }
        }
        let scored: [(Int, PaletteResult)] = items.enumerated().compactMap { n, item in
            let title = Fuzzy.match(query, item.title)
            let keyword = item.keywords.compactMap { Fuzzy.score(query, $0) }.max().map { $0 - 2 }
            if let title, title.score >= keyword ?? .min {
                return (n, PaletteResult(item: item, score: title.score, highlights: title.indices))
            }
            return keyword.map { (n, PaletteResult(item: item, score: $0, highlights: [])) }
        }
        return scored.sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0 < $1.0 }.map(\.1)
    }
}
