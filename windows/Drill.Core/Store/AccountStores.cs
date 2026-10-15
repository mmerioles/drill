namespace Drill.Core.Store;

/// <summary>
/// Sessions belong to one account. Each account gets its own store, and its
/// own sync state in prefs, so nothing ever moves between accounts. The old
/// offline store is left where it is, untouched, after the upgrade.
/// </summary>
public static class AccountStores
{
    /// <summary>Prefs keys for one account's sync state.</summary>
    public static string PushedAtKey(string userID) => "drill.sync.pushedAt." + userID;
    public static string CursorKey(string userID) => "drill.sync.cursor." + userID;

    // Before stores were per account, one push mark and cursor served everyone.
    private const string SharedPushedAt = "drill.sync.pushedAt";
    private const string SharedCursor = "drill.sync.cursor";
    private const string Upgraded = "drill.accountStores";

    /// <summary>
    /// Once: with an account already signed in, the one store this PC had
    /// becomes that account's, push mark and cursor included, so nothing
    /// uploads again; the offline store starts empty. With nobody signed in, nothing moves.
    /// </summary>
    public static void Upgrade(Prefs prefs, string offlinePath, string? userID)
    {
        if (prefs.Get<bool?>(Upgraded) == true) return;
        if (userID is not null)
        {
            var accountPath = SqliteSessionStore.AccountPath(userID, offlinePath);
            if (File.Exists(offlinePath) && !File.Exists(accountPath))
            {
                foreach (var suffix in Suffixes)
                {
                    if (File.Exists(offlinePath + suffix)) File.Move(offlinePath + suffix, accountPath + suffix);
                }
            }
            if (prefs.Get<DateTimeOffset?>(SharedPushedAt) is { } pushed) prefs.Set(PushedAtKey(userID), pushed);
            if (prefs.Get<string>(SharedCursor) is { } cursor) prefs.Set(CursorKey(userID), cursor);
        }
        prefs.Remove(SharedPushedAt);
        prefs.Remove(SharedCursor);
        prefs.Set(Upgraded, true);
    }

    /// <summary>An account's store and sync state, gone from this PC. The store must be closed first.</summary>
    public static void Forget(Prefs prefs, string userID, string? offlinePath = null)
    {
        prefs.Remove(PushedAtKey(userID));
        prefs.Remove(CursorKey(userID));
        var path = SqliteSessionStore.AccountPath(userID, offlinePath);
        foreach (var suffix in Suffixes)
        {
            try { File.Delete(path + suffix); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>The database and its write-ahead log files.</summary>
    private static readonly string[] Suffixes = ["", "-wal", "-shm"];
}
