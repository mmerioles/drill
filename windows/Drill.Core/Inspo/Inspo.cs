using System.Text.Json;
using System.Text.Json.Serialization;
using Drill.Core.Store;

namespace Drill.Core.Inspo;

/// <summary>
/// Shuzo Matsuoka's short cheer-up videos. The list is Support/inspo.json,
/// built into this assembly. The shuffle is kept in step with
/// Sources/DrillApp/Inspo.swift and web/static/inspo.js, so every device
/// shows the same few videos on the same day.
/// </summary>
public static class InspoVideos
{
    /// <param name="Daily">In the daily rotation. The rest are sponsor and
    /// travel skits, kept for the full list.</param>
    public sealed record Video(int Number, string Youtube, bool Daily, string Title, string Japanese)
    {
        public Uri Url => new($"https://www.youtube.com/watch?v={Youtube}");
    }

    public const int PerDay = 5;

    public static IReadOnlyList<Video> All { get; } = Load();

    private sealed record Row(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("title")] string Title,
        [property: JsonPropertyName("japanese")] string Japanese,
        [property: JsonPropertyName("daily")] bool Daily);

    private static List<Video> Load()
    {
        using var stream = typeof(InspoVideos).Assembly.GetManifestResourceStream("inspo.json")!;
        var rows = JsonSerializer.Deserialize<List<Row>>(stream)!;
        return rows.Select((r, i) => new Video(i + 1, r.Id, r.Daily, r.Title, r.Japanese)).ToList();
    }

    /// <summary>A day as a number, like 20260928: the key for watched videos and the shuffle's seed.</summary>
    public static int Day(DateTime local) => local.Year * 10000 + local.Month * 100 + local.Day;

    public static int Today() => Day(DateTime.Now);

    /// <summary>
    /// A fresh handful each day, seeded by the date, leaving out anything
    /// watched before today. Cheer-up messages come first, the skits once
    /// those run out, and the full rotation again once you've seen everything.
    /// </summary>
    public static IReadOnlyList<Video> ForToday(IReadOnlySet<string> seen, int day)
    {
        var seed = (uint)day;
        var daily = Shuffled(All.Where(v => v.Daily).ToList(), ref seed);
        var rest = Shuffled(All.Where(v => !v.Daily).ToList(), ref seed);
        var fresh = daily.Concat(rest).Where(v => !seen.Contains(v.Youtube)).ToList();
        return (fresh.Count == 0 ? daily : fresh).Take(PerDay).ToList();
    }

    private static List<Video> Shuffled(List<Video> pool, ref uint seed)
    {
        for (var i = pool.Count - 1; i > 0; i--)
        {
            var j = (int)(Mulberry32(ref seed) % (uint)(i + 1));
            (pool[i], pool[j]) = (pool[j], pool[i]);
        }
        return pool;
    }

    /// <summary>A tiny seeded generator, bit-for-bit the same as the one in inspo.js.</summary>
    internal static uint Mulberry32(ref uint a)
    {
        unchecked
        {
            a += 0x6D2B79F5;
            var t = a;
            t = (t ^ (t >> 15)) * (t | 1);
            t ^= t + ((t ^ (t >> 7)) * (t | 61));
            return t ^ (t >> 14);
        }
    }
}

/// <summary>Which videos you've opened, and on which day. Local to this PC.</summary>
public sealed class Watched(Prefs prefs)
{
    private const string Key = "drill.inspo.seen";
    /// <summary>YouTube id to the day it was first opened.</summary>
    private readonly Dictionary<string, int> _days = prefs.Get<Dictionary<string, int>>(Key) ?? [];

    public int Count => _days.Count;

    public bool Contains(InspoVideos.Video video) => _days.ContainsKey(video.Youtube);

    public IReadOnlySet<string> SeenBefore(int day) =>
        _days.Where(d => d.Value < day).Select(d => d.Key).ToHashSet();

    public void Mark(InspoVideos.Video video)
    {
        if (!_days.TryAdd(video.Youtube, InspoVideos.Today())) return;
        prefs.Set(Key, _days);
    }
}
