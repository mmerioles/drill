using System.Text.Json.Serialization;
using Drill.Core.Model;

namespace Drill.Core.Sync;

/// <summary>
/// Who you're signed in as. The token stands in for the password on every
/// call after sign-in; it runs out after an hour, and the refresh token gets
/// the next one. The email is the one signed in with, and the one shown.
/// </summary>
public sealed record Account(string Email, string Token, string? RefreshToken = null, DateTimeOffset? ExpiresAt = null, string? Id = null)
{
    /// <summary>
    /// Kept by a version that made each account a username, with a stand-in
    /// email; the next token refresh brings the real one.
    /// </summary>
    [JsonIgnore]
    public bool IsLegacy => Email.EndsWith("@users.mmerioles.github.io", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The Supabase user id, which names this account's store. Accounts saved
    /// before it was kept have it in their token's `sub`.
    /// </summary>
    [JsonIgnore]
    public string UserID => Id is { Length: > 0 } id ? id : SubjectOf(Token) ?? Email;

    private static string? SubjectOf(string token)
    {
        var parts = token.Split('.');
        if (parts.Length < 2) return null;
        try
        {
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');
            var json = System.Text.Json.Nodes.JsonNode.Parse(Convert.FromBase64String(payload));
            return (string?)json?["sub"] is { Length: > 0 } sub ? sub : null;
        }
        catch (Exception e) when (e is FormatException or System.Text.Json.JsonException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }
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
    /// <summary>For <see cref="SyncFailure.Rejected"/>: like "wrong email or password".</summary>
    public string? Sentence { get; } = sentence;

    public static SyncException Rejected(string sentence) => new(SyncFailure.Rejected, sentence);
}

internal static class Http
{
    /// <summary>One client for the app's life, so connections are reused.</summary>
    public static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(20) };
}
