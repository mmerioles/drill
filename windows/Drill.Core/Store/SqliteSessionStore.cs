using Drill.Core.Model;
using Microsoft.Data.Sqlite;

namespace Drill.Core.Store;

public interface ISessionStore
{
    /// <summary>
    /// Inserts or updates by id. An incoming row only replaces an existing
    /// one if its UpdatedAt is newer — the same rule sync merges by.
    /// </summary>
    void Save(FocusSession session);

    /// <summary>Live (non-deleted) sessions that started within [from, to), oldest first.</summary>
    IReadOnlyList<FocusSession> Sessions(DateTimeOffset from, DateTimeOffset to);

    /// <summary>Distinct tags, most recently used first.</summary>
    IReadOnlyList<string> Tags(int limit);

    /// <summary>Every row touched after `since`, tombstones included. The sync push set.</summary>
    IReadOnlyList<FocusSession> Changes(DateTimeOffset since);

    /// <summary>How many rows made on `deviceID` were touched after `since`: local changes not yet pushed.</summary>
    int Unpushed(DateTimeOffset since, string deviceID);

    /// <summary>Removes every row, tombstones included.</summary>
    void Clear();
}

/// <summary>SQLite, with the mac app's schema (dates are Unix seconds).</summary>
public sealed class SqliteSessionStore : ISessionStore, IDisposable
{
    private readonly SqliteConnection _db;
    private readonly Lock _gate = new();

    /// <summary>Opens (creating if needed) the database at `path`.</summary>
    public SqliteSessionStore(string path)
    {
        if (path != ":memory:") Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        _db = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Pooling = false,
        }.ToString());
        _db.Open();
        Migrate();
    }

    public static SqliteSessionStore InMemory() => new(":memory:");

    /// <summary>%LOCALAPPDATA%\Drill\drill.sqlite</summary>
    public static string DefaultPath => Path.Combine(Paths.DataFolder, "drill.sqlite");

    /// <summary>The store used while nobody's signed in: DRILL_DB when set (for trying things out), else <see cref="DefaultPath"/>.</summary>
    public static string OfflinePath =>
        Environment.GetEnvironmentVariable("DRILL_DB") is { Length: > 0 } db ? db : DefaultPath;

    /// <summary>One account's store, drill-&lt;userID&gt;.sqlite next to the offline one.</summary>
    public static string AccountPath(string userID, string? offlinePath = null)
    {
        var safe = string.Concat(userID.Where(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_'));
        var folder = Path.GetDirectoryName(Path.GetFullPath(offlinePath ?? OfflinePath))!;
        return Path.Combine(folder, $"drill-{safe}.sqlite");
    }

    /// <summary>Closes the file, waiting for any read or write in flight (sync runs off the UI thread).</summary>
    public void Dispose()
    {
        lock (_gate) _db.Dispose();
    }

    private void Migrate()
    {
        Exec("PRAGMA journal_mode = WAL");
        var version = Convert.ToInt32(Scalar("PRAGMA user_version"));
        if (version < 1)
        {
            Exec("""
                CREATE TABLE sessions (
                    id              TEXT PRIMARY KEY,
                    started_at      REAL NOT NULL,
                    ended_at        REAL NOT NULL,
                    focus_seconds   REAL NOT NULL,
                    planned_seconds REAL NOT NULL,
                    completed       INTEGER NOT NULL,
                    tag             TEXT,
                    device_id       TEXT NOT NULL,
                    updated_at      REAL NOT NULL,
                    deleted_at      REAL
                );
                CREATE INDEX sessions_started ON sessions(started_at);
                CREATE INDEX sessions_updated ON sessions(updated_at);
                PRAGMA user_version = 1;
                """);
        }
    }

    public void Save(FocusSession s)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = """
                INSERT INTO sessions (id, started_at, ended_at, focus_seconds, planned_seconds,
                                      completed, tag, device_id, updated_at, deleted_at)
                VALUES ($id, $started, $ended, $focus, $planned, $completed, $tag, $device, $updated, $deleted)
                ON CONFLICT(id) DO UPDATE SET
                    started_at = excluded.started_at, ended_at = excluded.ended_at,
                    focus_seconds = excluded.focus_seconds, planned_seconds = excluded.planned_seconds,
                    completed = excluded.completed, tag = excluded.tag, device_id = excluded.device_id,
                    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
                WHERE excluded.updated_at > sessions.updated_at
                """;
            cmd.Parameters.AddWithValue("$id", s.Id.ToString("D").ToUpperInvariant());
            cmd.Parameters.AddWithValue("$started", Seconds(s.StartedAt));
            cmd.Parameters.AddWithValue("$ended", Seconds(s.EndedAt));
            cmd.Parameters.AddWithValue("$focus", s.FocusSeconds);
            cmd.Parameters.AddWithValue("$planned", s.PlannedSeconds);
            cmd.Parameters.AddWithValue("$completed", s.Completed ? 1 : 0);
            cmd.Parameters.AddWithValue("$tag", (object?)s.Tag ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$device", s.DeviceID);
            cmd.Parameters.AddWithValue("$updated", Seconds(s.UpdatedAt));
            cmd.Parameters.AddWithValue("$deleted", s.DeletedAt is { } d ? Seconds(d) : DBNull.Value);
            cmd.ExecuteNonQuery();
        }
    }

    public IReadOnlyList<FocusSession> Sessions(DateTimeOffset from, DateTimeOffset to) =>
        Read($"SELECT {Columns} FROM sessions WHERE deleted_at IS NULL AND started_at >= $a AND started_at < $b ORDER BY started_at",
             ("$a", Seconds(from)), ("$b", Seconds(to)));

    public IReadOnlyList<string> Tags(int limit)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT tag FROM sessions WHERE tag IS NOT NULL AND deleted_at IS NULL GROUP BY tag ORDER BY MAX(started_at) DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$n", limit);
            using var r = cmd.ExecuteReader();
            var tags = new List<string>();
            while (r.Read()) tags.Add(r.GetString(0));
            return tags;
        }
    }

    public IReadOnlyList<FocusSession> Changes(DateTimeOffset since) =>
        Read($"SELECT {Columns} FROM sessions WHERE updated_at > $a ORDER BY updated_at", ("$a", Seconds(since)));

    public int Unpushed(DateTimeOffset since, string deviceID)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT COUNT(*) FROM sessions WHERE updated_at > $a AND device_id = $device";
            cmd.Parameters.AddWithValue("$a", Seconds(since));
            cmd.Parameters.AddWithValue("$device", deviceID);
            return Convert.ToInt32(cmd.ExecuteScalar());
        }
    }

    public void Clear()
    {
        lock (_gate) Exec("DELETE FROM sessions");
    }

    private const string Columns =
        "id, started_at, ended_at, focus_seconds, planned_seconds, completed, tag, device_id, updated_at, deleted_at";

    private List<FocusSession> Read(string sql, params (string Name, double Value)[] args)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = sql;
            foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value);
            using var r = cmd.ExecuteReader();
            var rows = new List<FocusSession>();
            while (r.Read())
            {
                rows.Add(new FocusSession
                {
                    Id = Guid.TryParse(r.GetString(0), out var id) ? id : Guid.NewGuid(),
                    StartedAt = Date(r.GetDouble(1)),
                    EndedAt = Date(r.GetDouble(2)),
                    FocusSeconds = r.GetDouble(3),
                    PlannedSeconds = r.GetDouble(4),
                    Completed = r.GetInt64(5) != 0,
                    Tag = r.IsDBNull(6) ? null : r.GetString(6),
                    DeviceID = r.IsDBNull(7) ? "" : r.GetString(7),
                    UpdatedAt = Date(r.GetDouble(8)),
                    DeletedAt = r.IsDBNull(9) ? null : Date(r.GetDouble(9)),
                });
            }
            return rows;
        }
    }

    private static double Seconds(DateTimeOffset d) =>
        d == DateTimeOffset.MinValue ? double.MinValue
        : d == DateTimeOffset.MaxValue ? double.MaxValue
        : (d - DateTimeOffset.UnixEpoch).TotalSeconds;

    private static DateTimeOffset Date(double seconds) => DateTimeOffset.UnixEpoch.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));

    private void Exec(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private object? Scalar(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return cmd.ExecuteScalar();
    }
}
