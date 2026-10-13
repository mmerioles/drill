using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Drill.Core.Store;
using Drill.Core.Sync;

namespace Drill.Services;

public enum SyncState { SignedOut, Idle, Syncing, Offline, Unconfirmed }

/// <summary>
/// Your account and the sync loop (docs/SYNC.md, "Client loop"), as in
/// Sources/DrillApp/Sync.swift: push what changed here, then pull what
/// changed elsewhere. Runs at launch, after each logged block, every few
/// minutes, when you come back to the app, and when you press sync.
///
/// The account (and its tokens) is kept in prefs encrypted with DPAPI, so
/// only this Windows user on this PC can read it.
/// </summary>
public sealed class Sync : Observable
{
    /// <summary>A sentence fit to show.</summary>
    public sealed class Problem(string message) : Exception(message);

    /// <summary>
    /// An account made here whose email link hasn't been clicked yet. Lives
    /// in memory only, password and all, just long enough to sign in by
    /// itself once the link is clicked.
    /// </summary>
    public sealed record Waiting(string Email, string Password, string? UserID, bool Confirmed = false);

    private static readonly TimeSpan Every = TimeSpan.FromMinutes(5);

    private readonly ISessionStore _store;
    private readonly string _deviceID;
    private readonly Prefs _prefs;
    private readonly Action _onPulled;
    private readonly DispatcherTimer _loop;
    private Task? _running;
    private DateTimeOffset? _lastStarted;
    private CancellationTokenSource? _watching;

    public Sync(ISessionStore store, string deviceID, Prefs prefs, Action onPulled)
    {
        _store = store;
        _deviceID = deviceID;
        _prefs = prefs;
        _onPulled = onPulled;
        Account = LoadAccount();
        CustomServer = prefs.Get<string>(Keys.Server);
        State = Account is null ? SyncState.SignedOut : SyncState.Idle;
        _loop = new DispatcherTimer(DispatcherPriority.Background) { Interval = Every };
        _loop.Tick += (_, _) => SyncNow();
    }

    public SyncState State { get; private set { if (Set(ref field, value)) Raise(nameof(Label)); } }
    public Account? Account { get; private set { if (Set(ref field, value)) { Raise(nameof(IsSignedIn)); Raise(nameof(Label)); } } }
    /// <summary>True for a moment after a sync lands, for a quiet "synced".</summary>
    public bool JustSynced { get; private set { if (Set(ref field, value)) Raise(nameof(Label)); } }
    /// <summary>A self-hosted server from settings, or null for ours.</summary>
    public string? CustomServer { get; private set => Set(ref field, value); }
    public Waiting? WaitingFor { get; private set { if (Set(ref field, value)) Raise(nameof(Label)); } }

    public bool IsSignedIn => Account is not null;

    /// <summary>The header's word.</summary>
    public string Label
    {
        get
        {
            if (WaitingFor is { Confirmed: false }) return "check email";
            return State switch
            {
                SyncState.Syncing => "syncing…",
                SyncState.Offline => "offline",
                SyncState.Unconfirmed => "confirm email",
                _ => JustSynced ? "synced" : "sync",
            };
        }
    }

    /// <summary>The self-hosted server from settings, or ours on Supabase.</summary>
    public ISyncBackend Backend =>
        CustomServer is { } s && Uri.TryCreate(s, UriKind.Absolute, out var url) ? new SyncApi(url) : SupabaseApi.Hosted;

    /// <summary>
    /// Points sync at a self-hosted server, or back at ours with an empty
    /// string. Only while signed out: a token only works where it was made.
    /// </summary>
    public void SetServer(string text)
    {
        if (IsSignedIn) throw new Problem("sign out to change servers.");
        if (string.IsNullOrWhiteSpace(text))
        {
            CustomServer = null;
            _prefs.Remove(Keys.Server);
            return;
        }
        var url = SyncApi.ServerUrl(text) ?? throw new Problem("that address doesn't look right.");
        CustomServer = url.AbsoluteUri.TrimEnd('/');
        _prefs.Set(Keys.Server, CustomServer);
    }

    /// <summary>Syncs at launch, every few minutes, and whenever you come back to the app.</summary>
    public void Start()
    {
        _loop.Start();
        SyncNow();
        Application.Current.Activated += (_, _) => CameBack();
    }

    private void CameBack()
    {
        // Not on every click back in: skip when a sync just started.
        if (_lastStarted is not { } last || DateTimeOffset.UtcNow - last > TimeSpan.FromSeconds(20)) SyncNow();
    }

    // Account

    public async Task SignIn(string email, string password)
    {
        StopWaiting();
        try
        {
            var backend = Backend;
            Begin(await Attempt(() => backend.SignIn(email, password)));
        }
        catch (SyncException e) when (e.Failure == SyncFailure.Unconfirmed)
        {
            Watch(new Waiting(email, password, null));
        }
    }

    /// <summary>Makes the account, then signs in, or waits for the email link.</summary>
    public async Task CreateAccount(string email, string password)
    {
        StopWaiting();
        var backend = Backend;
        switch (await Attempt(() => backend.CreateAccount(email, password)))
        {
            case SignUp.SignedIn s: Begin(s.Account); break;
            case SignUp.ConfirmByLink c: Watch(new Waiting(email, password, c.UserID)); break;
        }
    }

    public async Task ResendLink()
    {
        if (WaitingFor is not { } waiting) return;
        var backend = Backend;
        await Attempt(async () => { await backend.ResendLink(waiting.Email); return true; });
    }

    /// <summary>Gives up waiting, for a wrong email or a change of mind.</summary>
    public void StopWaiting()
    {
        _watching?.Cancel();
        _watching = null;
        WaitingFor = null;
    }

    /// <summary>Checks every few seconds whether the link was clicked, then signs in.</summary>
    private void Watch(Waiting start)
    {
        _watching?.Cancel();
        var cts = new CancellationTokenSource();
        _watching = cts;
        WaitingFor = start;
        var backend = Backend;
        var began = DateTimeOffset.UtcNow;
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                // Quick at first, while they're likely at their inbox.
                var quick = DateTimeOffset.UtcNow - began < TimeSpan.FromMinutes(30);
                try { await Task.Delay(TimeSpan.FromSeconds(start.UserID is null ? 10 : quick ? 3 : 30), cts.Token); }
                catch (TaskCanceledException) { return; }
                try
                {
                    if (start.UserID is { } id && !await backend.IsConfirmed(id, cts.Token)) continue;
                    var account = await backend.SignIn(start.Email, start.Password, cts.Token);
                    await Application.Current.Dispatcher.InvokeAsync(() => Confirmed(account, cts));
                    return;
                }
                catch (SyncException e) when (e.Failure == SyncFailure.Rejected)
                {
                    // The password changed elsewhere: sign in by hand.
                    await Application.Current.Dispatcher.InvokeAsync(() => { if (_watching == cts) StopWaiting(); });
                    return;
                }
                catch (Exception) when (!cts.IsCancellationRequested)
                {
                    // not yet, or offline for a moment
                }
                catch (Exception)
                {
                    return;
                }
            }
        });
    }

    private async void Confirmed(Account account, CancellationTokenSource cts)
    {
        if (WaitingFor is null || _watching != cts) return;
        WaitingFor = WaitingFor with { Confirmed = true };
        Begin(account);
        await Task.Delay(TimeSpan.FromSeconds(2.5));
        if (WaitingFor?.Confirmed == true) WaitingFor = null;
        if (_watching == cts) _watching = null;
    }

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
        catch (SyncException e) when (e.Failure == SyncFailure.Unconfirmed)
        {
            throw;
        }
        catch (Exception)
        {
            throw new Problem("can't connect. try again in a bit.");
        }
    }

    public void SignOut()
    {
        StopWaiting();
        if (Account is { } account)
        {
            var backend = Backend;
            _ = Task.Run(() => backend.SignOut(account));
        }
        Save(null);
        State = SyncState.SignedOut;
    }

    /// <summary>For --render: waiting on an email link, without asking a server.</summary>
    internal void PretendWaiting(string email, bool confirmed = false) => WaitingFor = new Waiting(email, "", null, confirmed);

    // Syncing

    /// <summary>Starts a sync unless one is already running.</summary>
    public void SyncNow()
    {
        if (_running is not null || Account is not { } account) return;
        _lastStarted = DateTimeOffset.UtcNow;
        _running = Run(Backend, account);
    }

    private async Task Run(ISyncBackend api, Account start)
    {
        State = SyncState.Syncing;
        try
        {
            // Hosted tokens last an hour: swap one that's nearly out, and
            // once more if the server turns it down anyway.
            var token = await Fresh(api, start, force: false);
            try
            {
                await Exchange(api, token);
            }
            catch (SyncException e) when (e.Failure == SyncFailure.SignedOut && start.RefreshToken is not null)
            {
                token = await Fresh(api, start, force: true);
                await Exchange(api, token);
            }
            if (Account?.Token != token) return; // signed out meanwhile
            State = SyncState.Idle;
            FlashSynced();
        }
        catch (SyncException e) when (e.Failure == SyncFailure.SignedOut)
        {
            if (Account?.Email != start.Email) return;
            Save(null);
            State = SyncState.SignedOut;
        }
        catch (SyncException e) when (e.Failure == SyncFailure.Unconfirmed)
        {
            State = SyncState.Unconfirmed;
        }
        catch (Exception)
        {
            if (Account?.Email == start.Email) State = SyncState.Offline;
        }
        finally
        {
            _running = null;
            if (State == SyncState.Syncing) State = Account is null ? SyncState.SignedOut : SyncState.Idle;
        }
    }

    /// <summary>A token good for a while, saved for next time.</summary>
    private async Task<string> Fresh(ISyncBackend api, Account start, bool force)
    {
        var current = Account ?? start;
        var fresh = await api.Refreshed(current, force);
        if (fresh != current && Account?.Email == start.Email) Save(fresh);
        return fresh.Token;
    }

    /// <summary>Push what changed here, then pull what changed elsewhere.</summary>
    private async Task Exchange(ISyncBackend api, string token)
    {
        var mark = DateTimeOffset.UtcNow;
        var since = _prefs.Get<DateTimeOffset?>(Keys.PushedAt) ?? DateTimeOffset.MinValue;
        var changes = await Task.Run(() => _store.Changes(since));
        for (var i = 0; i < changes.Count; i += 200)
            await api.Push(changes.Skip(i).Take(200).ToList(), _deviceID, token);
        _prefs.Set(Keys.PushedAt, mark);

        var pulled = false;
        SyncPage page;
        do
        {
            page = await api.Pull(_prefs.Get<string>(Keys.Cursor) ?? "0", token);
            var rows = page.Sessions;
            await Task.Run(() => { foreach (var s in rows) _store.Save(s); });
            pulled |= rows.Count > 0;
            _prefs.Set(Keys.Cursor, page.Cursor);
        } while (page.More);
        if (pulled) _onPulled();
    }

    private async void FlashSynced()
    {
        JustSynced = true;
        await Task.Delay(TimeSpan.FromSeconds(2));
        JustSynced = false;
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
        public const string Server = "drill.sync.server"; // self-hosted only
        public const string Cursor = "drill.sync.cursor";
        public const string PushedAt = "drill.sync.pushedAt";
    }
}
