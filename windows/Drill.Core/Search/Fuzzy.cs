namespace Drill.Core.Search;

/// <summary>The command palette's fuzzy match, the same on every platform.</summary>
public static class Fuzzy
{
    public sealed record Match(int Score, IReadOnlyList<int> Indices);

    public static int? Score(string query, string text) => Find(query, text)?.Score;

    /// <summary>Greedy left to right; null when a query character is missing.</summary>
    public static Match? Find(string query, string text)
    {
        var q = query.ToLowerInvariant().Replace(" ", "");
        if (q.Length == 0) return new Match(0, []);
        var t = text.ToLowerInvariant();
        var indices = new List<int>(q.Length);
        var score = 0;
        var at = -1;
        foreach (var c in q)
        {
            var i = t.IndexOf(c, at + 1);
            if (i < 0) return null;
            score += 1;
            if (i == 0 || t[i - 1] is ' ' or '-' or '_' or '/') score += 5;
            if (at >= 0 && i == at + 1) score += 3;
            indices.Add(i);
            at = i;
        }
        return new Match(score - indices[0], indices);
    }
}

public sealed record Command(string Id, string Title, string? Hint = null, IReadOnlyList<string>? Keywords = null);

/// <summary>A row to show. Highlight is null when nothing was typed (or for the new-tag row).</summary>
public sealed record Ranked(Command Command, int Score, IReadOnlyList<int>? Highlight);

public static class Finder
{
    public const int RecentCount = 5;

    /// <summary>
    /// Empty query: recently run first, then list order. Otherwise the matches,
    /// best first, ties in list order; a keyword match counts two less.
    /// </summary>
    public static IReadOnlyList<Ranked> Rank(string query, IReadOnlyList<Command> items, IReadOnlyList<string> recent)
    {
        if (query.Trim().Length == 0)
        {
            var first = recent.Select(id => items.FirstOrDefault(c => c.Id == id)).OfType<Command>().ToList();
            return first.Concat(items.Where(c => !first.Contains(c))).Select(c => new Ranked(c, 0, null)).ToList();
        }
        var ranked = new List<Ranked>();
        foreach (var c in items)
        {
            var title = Fuzzy.Find(query, c.Title);
            var keyword = (c.Keywords ?? Array.Empty<string>()).Select(word => Fuzzy.Score(query, word)).Max();
            if (title is null && keyword is null) continue;
            var score = Math.Max(title?.Score ?? int.MinValue, keyword is { } best ? best - 2 : int.MinValue);
            ranked.Add(new Ranked(c, score, title?.Indices ?? Array.Empty<int>()));
        }
        return ranked.OrderByDescending(r => r.Score).ToList();
    }

    /// <summary>The `studying "query"` row, unless the query is empty or already a tag.</summary>
    public static Command? NewTag(string query, IEnumerable<string> tags)
    {
        var tag = query.Trim();
        if (tag.Length == 0 || tags.Contains(tag.ToLowerInvariant())) return null;
        return new Command("new-tag", $"studying \"{tag}\"");
    }

    /// <summary>Moves `id` to the front of the recently run, keeping five.</summary>
    public static void Remember(List<string> recent, string id)
    {
        recent.Remove(id);
        recent.Insert(0, id);
        if (recent.Count > RecentCount) recent.RemoveRange(RecentCount, recent.Count - RecentCount);
    }
}
