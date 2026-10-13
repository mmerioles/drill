using System.Text.Json.Serialization;
using Drill.Core.Model;

namespace Drill.Core.Sync;

/// <summary>
/// Who you're signed in as. The token stands in for the password on every
/// call after sign-in. Hosted tokens run out after an hour and come with a
/// refresh token to get the next one; self-hosted tokens never run out.
/// </summary>
public sealed record Account(
    string Email, string Token, bool Confirmed, string? RefreshToken = null, DateTimeOffset? ExpiresAt = null);

/// <summary>How making an account went.</summary>
public abstract record SignUp
{
    /// <summary>Ready to sync.</summary>
    public sealed record SignedIn(Account Account) : SignUp;
    /// <summary>Waiting on the link in the confirmation email.</summary>
    public sealed record ConfirmByLink(string UserID) : SignUp;
}

/// <summary>One page of a pull: rows after the cursor, the next cursor, and whether there's more.</summary>
public sealed record SyncPage(
    [property: JsonPropertyName("sessions")] IReadOnlyList<FocusSession> Sessions,
    [property: JsonPropertyName("cursor")] string Cursor,
    [property: JsonPropertyName("more")] bool More);

public enum SyncFailure
{
    /// <summary>No answer from the server; try again later.</summary>
    Unreachable,
    /// <summary>The token was revoked or never existed: sign in again.</summary>
    SignedOut,
    /// <summary>The server wants the email confirmed before it syncs.</summary>
    Unconfirmed,
    /// <summary>The server said no, with a sentence fit to show.</summary>
    Rejected,
}

public sealed class SyncException(SyncFailure failure, string? sentence = null)
    : Exception(sentence ?? failure.ToString())
{
    public SyncFailure Failure { get; } = failure;
    /// <summary>For <see cref="SyncFailure.Rejected"/>: like "wrong email or password".</summary>
    public string? Sentence { get; } = sentence;

    public static SyncException Rejected(string sentence) => new(SyncFailure.Rejected, sentence);
}

/// <summary>
/// Where an account lives: drill's hosted sync (<see cref="SupabaseApi"/>) or
/// a self-hosted server (<see cref="SyncApi"/>). Both throw <see cref="SyncException"/>.
/// </summary>
public interface ISyncBackend
{
    Task<Account> SignIn(string email, string password, CancellationToken ct = default);
    Task<SignUp> CreateAccount(string email, string password, CancellationToken ct = default);
    /// <summary>Whether the account made by CreateAccount has had its email link clicked yet.</summary>
    Task<bool> IsConfirmed(string userID, CancellationToken ct = default);
    /// <summary>Sends the confirmation email again.</summary>
    Task ResendLink(string email, CancellationToken ct = default);
    /// <summary>The account with a token good for a while yet: the same one
    /// unless it's about to run out, or `force` says the server turned it down.</summary>
    Task<Account> Refreshed(Account account, bool force, CancellationToken ct = default);
    /// <summary>Best effort: signing out locally never waits on it.</summary>
    Task SignOut(Account account);
    Task Push(IReadOnlyList<FocusSession> sessions, string deviceID, string token, CancellationToken ct = default);
    Task<SyncPage> Pull(string cursor, string token, CancellationToken ct = default);
}

internal static class Http
{
    /// <summary>One client for the app's life, so connections are reused.</summary>
    public static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(20) };
}
