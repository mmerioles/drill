import Testing
@testable import DrillCore

@Suite struct FuzzyTests {
    @Test func sharedVectors() {
        #expect(Fuzzy.score("st", "start") == 10)
        #expect(Fuzzy.score("st", "reset") == 0)
        #expect(Fuzzy.score("ST", "start") == 10)
        #expect(Fuzzy.score("sw", "switch to stopwatch") == 10)
        #expect(Fuzzy.score("op", "open settings") == 10)
        #expect(Fuzzy.score("set", "open settings") == 9)
        #expect(Fuzzy.score("xyz", "start") == nil)
        #expect(Fuzzy.score("", "anything") == 0)
        #expect(Fuzzy.score("o s", "open settings") == 12)
    }

    @Test func matchedIndices() {
        #expect(Fuzzy.match("set", "open settings")?.indices == [5, 6, 7])
        #expect(Fuzzy.match("o s", "open settings")?.indices == [0, 5])
    }

    private let items = [
        PaletteItem(id: "toggle", title: "start", keywords: ["timer"]),
        PaletteItem(id: "reset", title: "reset", keywords: ["timer"]),
        PaletteItem(id: "settings", title: "open settings", keywords: ["preferences"]),
        PaletteItem(id: "inspo", title: "open inspo"),
    ]

    @Test func ranksByScoreThenListOrder() {
        #expect(Palette.rank(items, query: "st").map(\.item.id) == ["toggle", "settings", "reset"])
        #expect(Palette.rank(items, query: "open").map(\.item.id) == ["settings", "inspo"])
    }

    @Test func keywordsCountTwoLess() {
        let r = Palette.rank(items, query: "pref")
        #expect(r.map(\.item.id) == ["settings"])
        #expect(r[0].score == Fuzzy.score("pref", "preferences")! - 2)
        #expect(r[0].highlights.isEmpty)
        #expect(Palette.rank(items, query: "timer").map(\.item.id) == ["toggle", "reset"])
    }

    @Test func emptyQueryPutsRecentFirst() {
        let r = Palette.rank(items, query: "", recent: ["inspo", "gone", "reset"])
        #expect(r.map(\.item.id) == ["inspo", "reset", "toggle", "settings"])
    }
}
