using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Drill.Core.Store;
using Drill.Core.Sync;

namespace Drill.Services;

public enum SyncState { SignedOut, Idle, Syncing, Offline }

/// <summary>
/// The account and the sync loop (docs/SYNC.md, as mac's Sync.swift): push
/// local changes, then pull remote ones. The account is kept in prefs,
/// DPAPI-encrypted to this Windows user. Each account has its own store and
/// sync state (<see cref="AccountStores"/>); the model shows whichever is in use.
/// </summary>
public sealed class Sync : Observable
{
    /// <summary>A sentence fit to show.</summary>
    public sealed class Problem(string message) : Exception(message);

    private static readonly TimeSpan Every = TimeSpan.FromMinutes(5);
    private static readonly SupabaseApi Api = SupabaseApi.Hosted;

    private readonly AppModel _model;
    private readonly string _deviceID;
    private readonly Prefs _prefs;
    private readonly DispatcherTimer _loop;
    private Task? _running;
    private DateTimeOffset? _lastStarted;
    private bool _auto;
    /// <summary>Whose store the model is showing; null for the offline one.</summary>
    private string? _userID;

    public Sync(AppModel model)
    {
        _model = model;
        _deviceID = model.DeviceID;
        _prefs = model.Prefs;
        Account = StoredAccount(_prefs);
        _userID = Account?.UserID;
        _auto = _prefs.Get<bool?>(Keys.Auto) ?? true;
        State = Account is null ? SyncState.SignedOut : SyncState.Idle;
        _loop = new DispatcherTimer(DispatcherPriority.Background) { Interval = Every };
        _loop.Tick += (_, _) => SyncNow();
        Refresh();
    }

    public SyncState State { get; private set { if (Set(ref field, value)) { Raise(nameof(Label)); Raise(nameof(ShowsLink)); } } }
    public Account? Account { get; private set { if (Set(ref field, value)) { Raise(nameof(IsSignedIn)); Raise(nameof(ShowsLink)); } } }
    /// <summary>Sessions logged here that haven't reached the server yet.</summary>
    public bool HasUnpushed { get; private set { if (Set(ref field, value)) Raise(nameof(ShowsLink)); } }

    public bool IsSignedIn => Account is not null;

    /// <summary>Off: nothing syncs unless you ask. Back on: syncs at once.</summary>
    public bool AutoSync
    {
        get => _auto;
        set
        {
            if (!Set(ref _auto, value)) return;
            _prefs.Set(Keys.Auto, value);
            _loop.IsEnabled = IsSignedIn && value;
            if (value) SyncNow();
        }
    }

    /// <summary>The header's link: only while there's something to push and nothing pushing it.</summary>
    public bool ShowsLink => IsSignedIn && HasUnpushed && State != SyncState.Syncing;

    /// <summary>The header link's word.</summary>
    public string Label => State == SyncState.Offline ? "offline" : "sync";

    /// <summary>With auto sync on: syncs at launch, every few minutes, and whenever you come back to the app.</summary>
    public void Start()
    {
        // The loop only runs while there's an account to sync: no wakeups signed out.
        _loop.IsEnabled = IsSignedIn && AutoSync;
        PropertyChanged += (_, e) => { if (e.PropertyName == nameof(IsSignedIn)) _loop.IsEnabled = IsSignedIn && AutoSync; };
        if (AutoSync) SyncNow();
        Application.Current.Activated += (_, _) => CameBack();
    }

    private void CameBack()
    {
        // Not on every click back in: skip when a sync just started.
        if (AutoSync && (_lastStarted is not { } last || DateTimeOffset.UtcNow - last > TimeSpan.FromSeconds(20))) SyncNow();
    }

    /// <summary>A session was logged here.</summary>
    public void Logged()
    {
        Refresh();
        if (AutoSync) SyncNow();
    }

    private void Refresh()
    {
        if (_userID is not { } id)
        {
            HasUnpushed = false;
            return;
        }
        var since = _prefs.Get<DateTimeOffset?>(AccountStores.PushedAtKey(id)) ?? DateTimeOffset.MinValue;
        try { HasUnpushed = _model.Store.Unpushed(since, _deviceID) > 0; } catch (Exception) { HasUnpushed = false; }
    }

    // Account

    /// <summary>Signed out, the account was ended on quit, and it ends at next launch if it wasn't.</summary>
    public bool IsEphemeral => Account is not null && _prefs.Get<bool?>(Keys.Ephemeral) == true;

    /// <summary>An existing account: its own store (empty unless kept from before), caught up from the start.</summary>
    public async Task SignIn(string username, string password, bool stay = true) =>
        await Begin(await Attempt(() => Api.SignIn(username, password)), stay, creating: false);

    /// <summary>Makes the account and signs in; confirmation is off, so there's nothing to wait for.</summary>
    public async Task CreateAccount(string username, string password, bool stay = true) =>
        await Begin(await Attempt(() => Api.CreateAccount(username, password)), stay, creating: true);

    /// <summary>The live check while typing a name on the create form.</summary>
    public Task<bool> UsernameAvailable(string name, CancellationToken ct) => Api.UsernameAvailable(name, ct);

    /// <summary>
    /// Switches the model to the account's store. Only a new account takes
    /// the sessions logged here offline; signing in uploads nothing from before.
    /// </summary>
    private async Task Begin(Account account, bool stay, bool creating)
    {
        if (_running is { } running) await running;
        var id = account.UserID;
        var store = id == _userID ? _model.Store : AppModel.Open(SqliteSessionStore.AccountPath(id));
        if (creating && _userID is null)
        {
            var offline = _model.Store;
            try { await Task.Run(() => AccountStores.MoveRows(offline, store)); } catch (Exception) { }
            _prefs.Remove(AccountStores.PushedAtKey(id));
        }
        _prefs.Remove(AccountStores.CursorKey(id)); // catch up from the start
        if (stay) _prefs.Remove(Keys.Ephemeral);
        else _prefs.Set(Keys.Ephemeral, true);
        _userID = id;
        _model.UseStore(store);
        Save(account);
        State = SyncState.Idle;
        Refresh();
        SyncNow();
    }

    private static async Task<T> Attempt<T>(Func<Task<T>> call)
    {
        try
        {
            return await call();
        }
        catch (SyncException e) when (e.Failure == SyncFailure.Rejected)
        {
            throw new Problem(e.Sentence ?? "something went wrong. try again.");
        }
        catch (Exception)
        {
            throw new Problem("can't connect. try again in a bit.");
        }
    }

    /// <summary>
    /// Before signing out: pushes what's left, for up to `limit`. True when
    /// nothing's left unpushed (or there's no account).
    /// </summary>
    public async Task<bool> Flush(TimeSpan limit)
    {
        if (Account is null || _userID is null) return true;
        var work = FlushAll();
        await Task.WhenAny(work, Task.Delay(limit));
        Refresh();
        return work.IsCompleted && !HasUnpushed;
    }

    private async Task FlushAll()
    {
        if (_running is { } running) await running;
        Refresh();
        if (!HasUnpushed) return;
        SyncNow();
        if (_running is { } again) await again;
    }

    /// <summary>
    /// Signs out and leaves no trace of the account here: its store and sync
    /// state are deleted, and the model goes back to the offline store.
    /// Returns the token's revocation, for a caller that's quitting to wait on.
    /// </summary>
    public Task SignOut()
    {
        var revoke = Account is { } account ? Task.Run(() => Api.SignOut(account)) : Task.CompletedTask;
        Save(null);
        Drop(forget: true);
        State = SyncState.SignedOut;
        return revoke;
    }

    /// <summary>Back to the offline store; with `forget`, the account's store is deleted too.</summary>
    private void Drop(bool forget)
    {
        var id = _userID;
        _userID = null;
        _prefs.Remove(Keys.Ephemeral);
        if (id is null) return;
        _model.UseStore(AppModel.Open(SqliteSessionStore.OfflinePath)); // closes the account's
        if (forget) AccountStores.Forget(_prefs, id);
        Refresh();
    }

    // Syncing

    /// <summary>Starts a sync unless one is already running.</summary>
    public void SyncNow()
    {
        if (_running is not null || Account is not { } account) return;
        _lastStarted = DateTimeOffset.UtcNow;
        _running = Run(account);
    }

    private async Task Run(Account start)
    {
        State = SyncState.Syncing;
        // This account's store and state, whatever's swapped in meanwhile.
        var store = _model.Store;
        var id = _userID ?? start.UserID;
        try
        {
            // Tokens last an hour: swap one that's nearly out, and once more
            // if the server turns it down anyway.
            var token = await Fresh(start, force: false);
            try
            {
                await Exchange(token, store, id);
            }
            catch (SyncException e) when (e.Failure == SyncFailure.SignedOut && start.RefreshToken is not null)
            {
                token = await Fresh(start, force: true);
                await Exchange(token, store, id);
            }
            if (Account?.Token != token) return; // signed out meanwhile
            State = SyncState.Idle;
        }
        catch (SyncException e) when (e.Failure == SyncFailure.SignedOut)
        {
            if (Account?.Email != start.Email) return;
            // The server ended the session: back to offline. The account's
            // store stays for signing in again, unless it wasn't to be kept.
            var ephemeral = IsEphemeral;
            Save(null);
            Drop(forget: ephemeral);
            State = SyncState.SignedOut;
        }
        catch (Exception)
        {
            if (Account?.Email == start.Email) State = SyncState.Offline;
        }
        finally
        {
            _running = null;
            Refresh();
            if (State == SyncState.Syncing) State = Account is null ? SyncState.SignedOut : SyncState.Idle;
        }
    }

    /// <summary>A token good for a while, saved for next time.</summary>
    private async Task<string> Fresh(Account start, bool force)
    {
        var current = Account ?? start;
        var fresh = await Api.Refreshed(current, force);
        if (fresh != current && Account?.Email == start.Email) Save(fresh);
        return fresh.Token;
    }

    /// <summary>Push what changed here, then pull what changed elsewhere.</summary>
    private async Task Exchange(string token, ISessionStore store, string id)
    {
        var pushedAt = AccountStores.PushedAtKey(id);
        var cursor = AccountStores.CursorKey(id);
        var mark = DateTimeOffset.UtcNow;
        var since = _prefs.Get<DateTimeOffset?>(pushedAt) ?? DateTimeOffset.MinValue;
        var changes = await Task.Run(() => store.Changes(since));
        for (var i = 0; i < changes.Count; i += 200)
            await Api.Push(changes.Skip(i).Take(200).ToList(), _deviceID, token);
        _prefs.Set(pushedAt, mark);

        var pulled = false;
        SyncPage page;
        do
        {
            page = await Api.Pull(_prefs.Get<string>(cursor) ?? "0", token);
            var rows = page.Sessions;
            await Task.Run(() => { foreach (var s in rows) store.Save(s); });
            pulled |= rows.Count > 0;
            _prefs.Set(cursor, page.Cursor);
        } while (page.More);
        if (pulled && ReferenceEquals(store, _model.Store)) _model.Reload();
    }

    // Keeping the account

    private static readonly byte[] Entropy = "drill.sync.account"u8.ToArray();

    private void Save(Account? account)
    {
        Account = account;
        if (account is null)
        {
            _prefs.Remove(Keys.Account);
            return;
        }
        var json = JsonSerializer.SerializeToUtf8Bytes(account);
        _prefs.Set(Keys.Account, Convert.ToBase64String(ProtectedData.Protect(json, Entropy, DataProtectionScope.CurrentUser)));
    }

    /// <summary>The account kept in `prefs`, if it can be read.</summary>
    public static Account? StoredAccount(Prefs prefs)
    {
        if (prefs.Get<string>(Keys.Account) is not { } sealed_) return null;
        try
        {
            var json = ProtectedData.Unprotect(Convert.FromBase64String(sealed_), Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Account>(json);
        }
        catch (Exception)
        {
            return null; // another user's, or damaged: sign in again
        }
    }

    private static class Keys
    {
        public const string Account = "drill.sync.account";
        public const string Auto = "drill.sync.auto";
        public const string Ephemeral = "drill.sync.ephemeral";
    }
}
