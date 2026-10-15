using System.Text;
using Drill.Core.Model;
using Drill.Core.Store;
using Drill.Core.Sync;

namespace Drill.Core.Tests;

public sealed class AccountStoresTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), $"drill-test-{Guid.NewGuid()}");
    private string Offline => Path.Combine(_folder, "drill.sqlite");

    public void Dispose()
    {
        if (Directory.Exists(_folder)) Directory.Delete(_folder, recursive: true);
    }

    private static FocusSession Session(long start, long? updated = null) => new()
    {
        StartedAt = DateTimeOffset.FromUnixTimeSeconds(start),
        EndedAt = DateTimeOffset.FromUnixTimeSeconds(start).AddMinutes(25),
        FocusSeconds = 1500, PlannedSeconds = 1500, Completed = true, DeviceID = "test",
        UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(updated ?? start),
    };

    private static IReadOnlyList<FocusSession> All(ISessionStore store) => store.Changes(DateTimeOffset.MinValue);

    [Fact]
    public void AccountStoresSitBesideTheOfflineOne()
    {
        Assert.Equal(Path.Combine(_folder, "drill-0b5e-42.sqlite"), SqliteSessionStore.AccountPath("0b5e-42", Offline));
        Assert.Equal(Path.Combine(_folder, "drill-ab.sqlite"), SqliteSessionStore.AccountPath("../a\\b", Offline));
    }

    [Fact]
    public void SigningInAsBUploadsNothingOfAs()
    {
        var prefs = Prefs.InMemory();
        using (var a = new SqliteSessionStore(SqliteSessionStore.AccountPath("a", Offline)))
        {
            a.Save(Session(100));
            a.Save(Session(200));
        }
        using var b = new SqliteSessionStore(SqliteSessionStore.AccountPath("b", Offline));
        var since = prefs.Get<DateTimeOffset?>(AccountStores.PushedAtKey("b")) ?? DateTimeOffset.MinValue;
        Assert.Empty(b.Changes(since));
        Assert.Equal(0, b.Unpushed(since, "test"));
        Assert.False(File.Exists(Offline));
    }

    [Fact]
    public void MakingAnAccountMovesTheOfflineRows()
    {
        using var offline = new SqliteSessionStore(Offline);
        var kept = Session(100);
        var gone = Session(200) with { DeletedAt = DateTimeOffset.FromUnixTimeSeconds(300), UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(300) };
        offline.Save(kept);
        offline.Save(gone);
        using var account = new SqliteSessionStore(SqliteSessionStore.AccountPath("new", Offline));

        AccountStores.MoveRows(offline, account);

        Assert.Empty(All(offline));
        Assert.Equal([kept.Id, gone.Id], All(account).Select(s => s.Id));
        Assert.Equal(2, account.Unpushed(DateTimeOffset.MinValue, "test"));
    }

    [Fact]
    public void UpgradeGivesTheStoreToTheSignedInAccountOnce()
    {
        var prefs = Prefs.InMemory();
        var mark = DateTimeOffset.FromUnixTimeSeconds(500);
        prefs.Set("drill.sync.pushedAt", mark);
        prefs.Set("drill.sync.cursor", "42");
        var old = Session(100, updated: 400);
        using (var store = new SqliteSessionStore(Offline)) store.Save(old);

        AccountStores.Upgrade(prefs, Offline, "me");

        var accountPath = SqliteSessionStore.AccountPath("me", Offline);
        Assert.False(File.Exists(Offline));
        Assert.True(File.Exists(accountPath));
        Assert.Equal(mark, prefs.Get<DateTimeOffset?>(AccountStores.PushedAtKey("me")));
        Assert.Equal("42", prefs.Get<string>(AccountStores.CursorKey("me")));
        Assert.Null(prefs.Get<string>("drill.sync.cursor"));
        using (var account = new SqliteSessionStore(accountPath))
        {
            Assert.Equal([old], All(account));
            Assert.Empty(account.Changes(mark)); // nothing uploads again
        }

        // Once: a new offline store is left where it is.
        using (var fresh = new SqliteSessionStore(Offline)) fresh.Save(Session(900));
        AccountStores.Upgrade(prefs, Offline, "me");
        Assert.True(File.Exists(Offline));
        using (var account = new SqliteSessionStore(accountPath)) Assert.Single(All(account));
    }

    [Fact]
    public void UpgradeWithNobodySignedInMovesNothing()
    {
        var prefs = Prefs.InMemory();
        using (var store = new SqliteSessionStore(Offline)) store.Save(Session(100));
        AccountStores.Upgrade(prefs, Offline, null);
        using var offline = new SqliteSessionStore(Offline);
        Assert.Single(All(offline));
        Assert.Empty(Directory.GetFiles(_folder, "drill-*.sqlite"));
    }

    [Fact]
    public void ForgettingDeletesTheStoreAndItsState()
    {
        var prefs = Prefs.InMemory();
        prefs.Set(AccountStores.PushedAtKey("me"), DateTimeOffset.FromUnixTimeSeconds(5));
        prefs.Set(AccountStores.CursorKey("me"), "7");
        using (var store = new SqliteSessionStore(SqliteSessionStore.AccountPath("me", Offline))) store.Save(Session(100));

        AccountStores.Forget(prefs, "me", Offline);

        Assert.False(File.Exists(SqliteSessionStore.AccountPath("me", Offline)));
        Assert.Null(prefs.Get<DateTimeOffset?>(AccountStores.PushedAtKey("me")));
        Assert.Null(prefs.Get<string>(AccountStores.CursorKey("me")));
    }

    [Fact]
    public void UserIDComesFromTheTokenWhenNotKept()
    {
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes("{\"sub\":\"6f1c-9a\",\"role\":\"authenticated\"}"))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        Assert.Equal("6f1c-9a", new Account("teto@x", $"h.{payload}.s").UserID);
        Assert.Equal("kept", new Account("teto@x", $"h.{payload}.s", Id: "kept").UserID);
        Assert.Equal("teto", new Account("teto@x", "not-a-jwt").UserID);
    }
}
