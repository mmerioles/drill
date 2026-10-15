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
/// DPAPI-encrypted to this Windows user.
/// </summary>
public sealed class Sync : Observable
{
    /// <summary>A sentence fit to show.</summary>
    public sealed class Problem(string message) : Exception(message);

    private static readonly TimeSpan Every = TimeSpan.FromMinutes(5);
    private static readonly SupabaseApi Api = SupabaseApi.Hosted;

    private readonly ISessionStore _store;
    private readonly string _deviceID;
    private readonly Prefs _prefs;
    private readonly Action _onPulled;
    private readonly DispatcherTimer _loop;
    private Task? _running;
    private DateTimeOffset? _lastStarted;
    private bool _auto;

    public Sync(ISessionStore store, string deviceID, Prefs prefs, Action onPulled)
    {
        _store = store;
        _deviceID = deviceID;
        _prefs = prefs;
        _onPulled = onPulled;
        Account = LoadAccount();
        _auto = prefs.Get<bool?>(Keys.Auto) ?? true;
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
        var since = _prefs.Get<DateTimeOffset?>(Keys.PushedAt) ?? DateTimeOffset.MinValue;
        try { HasUnpushed = _store.Unpushed(since, _deviceID) > 0; } catch (Exception) { HasUnpushed = false; }
    }

    // Account

    public async Task SignIn(string username, string password) =>
        Begin(await Attempt(() => Api.SignIn(username, password)));

    /// <summary>Makes the account and signs in; confirmation is off, so there's nothing to wait for.</summary>
    public async Task CreateAccount(string username, string password) =>
        Begin(await Attempt(() => Api.CreateAccount(username, password)));

    /// <summary>The live check while typing a name on the create form.</summary>
    public Task<bool> UsernameAvailable(string name, CancellationToken ct) => Api.UsernameAvailable(name, ct);

    /// <summary>Everything already on this PC joins the account.</summary>
    private void Begin(Account account)
    {
        Save(account);
        // Upload everything, and catch up from the start.
        _prefs.Remove(Keys.PushedAt);
        _prefs.Remove(Keys.Cursor);
        State = SyncState.Idle;
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

    public void SignOut()
    {
        if (Account is { } account) _ = Task.Run(() => Api.SignOut(account));
        Save(null);
        State = SyncState.SignedOut;
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
        try
        {
            // Tokens last an hour: swap one that's nearly out, and once more
            // if the server turns it down anyway.
            var token = await Fresh(start, force: false);
            try
            {
                await Exchange(token);
            }
            catch (SyncException e) when (e.Failure == SyncFailure.SignedOut && start.RefreshToken is not null)
            {
                token = await Fresh(start, force: true);
                await Exchange(token);
            }
            if (Account?.Token != token) return; // signed out meanwhile
            State = SyncState.Idle;
        }
        catch (SyncException e) when (e.Failure == SyncFailure.SignedOut)
        {
            if (Account?.Email != start.Email) return;
            Save(null);
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
    private async Task Exchange(string token)
    {
        var mark = DateTimeOffset.UtcNow;
        var since = _prefs.Get<DateTimeOffset?>(Keys.PushedAt) ?? DateTimeOffset.MinValue;
        var changes = await Task.Run(() => _store.Changes(since));
        for (var i = 0; i < changes.Count; i += 200)
            await Api.Push(changes.Skip(i).Take(200).ToList(), _deviceID, token);
        _prefs.Set(Keys.PushedAt, mark);

        var pulled = false;
        SyncPage page;
        do
        {
            page = await Api.Pull(_prefs.Get<string>(Keys.Cursor) ?? "0", token);
            var rows = page.Sessions;
            await Task.Run(() => { foreach (var s in rows) _store.Save(s); });
            pulled |= rows.Count > 0;
            _prefs.Set(Keys.Cursor, page.Cursor);
        } while (page.More);
        if (pulled) _onPulled();
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

    private Account? LoadAccount()
    {
        if (_prefs.Get<string>(Keys.Account) is not { } sealed_) return null;
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
        public const string Cursor = "drill.sync.cursor";
        public const string PushedAt = "drill.sync.pushedAt";
        public const string Auto = "drill.sync.auto";
    }
}
