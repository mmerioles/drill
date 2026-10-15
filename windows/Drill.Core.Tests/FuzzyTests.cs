using Drill.Core.Search;

namespace Drill.Core.Tests;

public class FuzzyTests
{
    [Fact]
    public void SharedVectors()
    {
        Assert.Equal(10, Fuzzy.Score("st", "start"));
        Assert.Equal(0, Fuzzy.Score("st", "reset"));
        Assert.Equal(10, Fuzzy.Score("ST", "start"));
        Assert.Equal(10, Fuzzy.Score("sw", "switch to stopwatch"));
        Assert.Equal(10, Fuzzy.Score("op", "open settings"));
        Assert.Equal(9, Fuzzy.Score("set", "open settings"));
        Assert.Null(Fuzzy.Score("xyz", "start"));
        Assert.Equal(0, Fuzzy.Score("", "anything"));
        Assert.Equal(12, Fuzzy.Score("o s", "open settings"));
    }

    [Fact]
    public void MatchedIndices()
    {
        Assert.Equal(new[] { 5, 6, 7 }, Fuzzy.Find("set", "open settings")!.Indices.ToArray());
        Assert.Equal(new[] { 0, 5 }, Fuzzy.Find("o s", "open settings")!.Indices.ToArray());
    }

    private static readonly Command[] Items =
    [
        new("toggle", "start", "space", ["timer"]),
        new("reset", "reset", "ctrl+r"),
        new("settings", "open settings", null, ["preferences"]),
        new("inspo", "open inspo"),
    ];

    private static string[] Ids(IEnumerable<Ranked> rows) => rows.Select(r => r.Command.Id).ToArray();

    [Fact]
    public void RanksByScoreThenListOrder()
    {
        Assert.Equal(new[] { "toggle", "settings", "reset" }, Ids(Finder.Rank("st", Items, [])));
        Assert.Equal(new[] { "settings", "inspo" }, Ids(Finder.Rank("op", Items, [])));
    }

    [Fact]
    public void KeywordsCountTwoLess()
    {
        var rows = Finder.Rank("pref", Items, []);
        Assert.Equal(new[] { "settings" }, Ids(rows));
        Assert.Equal(Fuzzy.Score("pref", "preferences") - 2, rows[0].Score);
        Assert.Empty(rows[0].Highlight!);
    }

    [Fact]
    public void EmptyQueryPutsRecentFirst()
    {
        var recent = new List<string>();
        Finder.Remember(recent, "reset");
        Finder.Remember(recent, "inspo");
        Assert.Equal(new[] { "inspo", "reset", "toggle", "settings" }, Ids(Finder.Rank("", Items, recent)));
        for (var i = 0; i < 9; i++) Finder.Remember(recent, $"x{i}");
        Assert.Equal(Finder.RecentCount, recent.Count);
        Assert.Equal("x8", recent[0]);
    }

    [Fact]
    public void NewTagOnlyForUnknownTags()
    {
        Assert.Equal("studying \"Chem\"", Finder.NewTag(" Chem ", ["piano"])!.Title);
        Assert.Null(Finder.NewTag("Piano", ["piano"]));
        Assert.Null(Finder.NewTag("  ", ["piano"]));
    }
}
