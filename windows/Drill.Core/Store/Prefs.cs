using System.Text.Json;
using System.Text.Json.Nodes;

namespace Drill.Core.Store;

public static class Paths
{
    /// <summary>%LOCALAPPDATA%\Drill, or DRILL_HOME when set (for trying things out).</summary>
    public static string DataFolder =>
        Environment.GetEnvironmentVariable("DRILL_HOME") is { Length: > 0 } home ? home
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Drill");
}

/// <summary>
/// Small settings that outlive the app, like the mac's UserDefaults: one JSON
/// object in prefs.json, keyed with the mac's names ("drill.theme"). Writes
/// go to a temp file first and replace the old one, so a crash mid-write
/// never leaves half a file.
/// </summary>
public sealed class Prefs
{
    private readonly string? _path;
    private readonly JsonObject _values;
    private readonly Lock _gate = new();

    public Prefs(string? path)
    {
        _path = path;
        _values = Load(path);
    }

    /// <summary>Kept in memory only; for tests.</summary>
    public static Prefs InMemory() => new(null);

    public static Prefs Standard() => new(Path.Combine(Paths.DataFolder, "prefs.json"));

    public T? Get<T>(string key)
    {
        lock (_gate)
        {
            if (!_values.TryGetPropertyValue(key, out var node) || node is null) return default;
            try { return node.Deserialize<T>(); } catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return default; }
        }
    }

    public bool Has(string key)
    {
        lock (_gate) return _values.ContainsKey(key);
    }

    public void Set<T>(string key, T value)
    {
        lock (_gate)
        {
            _values[key] = JsonSerializer.SerializeToNode(value);
            Persist();
        }
    }

    public void Remove(string key)
    {
        lock (_gate)
        {
            if (_values.Remove(key)) Persist();
        }
    }

    private void Persist()
    {
        if (_path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, _values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, _path, overwrite: true);
        }
        catch (IOException) { } // a full or locked disk keeps the old prefs
        catch (UnauthorizedAccessException) { }
    }

    private static JsonObject Load(string? path)
    {
        if (path is null || !File.Exists(path)) return [];
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? []; }
        catch (Exception e) when (e is JsonException or IOException) { return []; }
    }
}

/// <summary>A stable per-install id stamped on every session.</summary>
public static class DeviceIdentity
{
    private const string Key = "drill.deviceID";

    public static string Current(Prefs prefs)
    {
        if (prefs.Get<string>(Key) is { Length: > 0 } id) return id;
        id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        prefs.Set(Key, id);
        return id;
    }
}
