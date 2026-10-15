using System.Text.Json.Serialization;
using Drill.Core.Model;

namespace Drill.Core.Sync;

/// <summary>
/// Who you're signed in as. The token stands in for the password on every
/// call after sign-in; it runs out after an hour, and the refresh token gets
/// the next one. The email is the synthetic one Supabase keys the user by.
/// </summary>
public sealed record Account(string Email, string Token, string? RefreshToken = null, DateTimeOffset? ExpiresAt = null)
{
    /// <summary>The name shown in the app: the email without its domain.</summary>
    [JsonIgnore]
    public string Username => SupabaseApi.UsernameOf(Email);
}

/// <summary>One page of a pull: rows after the cursor, the next cursor, and whether there's more.</summary>
public sealed record SyncPage(IReadOnlyList<FocusSession> Sessions, string Cursor, bool More);

public enum SyncFailure
{
    /// <summary>No answer from the server; try again later.</summary>
    Unreachable,
    /// <summary>The token was revoked or never existed: sign in again.</summary>
    SignedOut,
    /// <summary>The server said no, with a sentence fit to show.</summary>
    Rejected,
}

public sealed class SyncException(SyncFailure failure, string? sentence = null)
    : Exception(sentence ?? failure.ToString())
{
    public SyncFailure Failure { get; } = failure;
    /// <summary>For <see cref="SyncFailure.Rejected"/>: like "wrong username or password".</summary>
    public string? Sentence { get; } = sentence;

    public static SyncException Rejected(string sentence) => new(SyncFailure.Rejected, sentence);
}

internal static class Http
{
    /// <summary>One client for the app's life, so connections are reused.</summary>
    public static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(20) };
}
