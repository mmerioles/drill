using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Drill.Core.Model;

namespace Drill.Core.Sync;

/// <summary>
/// drill's hosted sync: Supabase Auth for accounts, and the two functions in
/// supabase/migrations for sessions. Same contract as a self-hosted server
/// (docs/SYNC.md), so Sync doesn't care which one it's talking to.
///
/// The publishable key is meant to ship inside apps. It can only sign people
/// up and call the functions as whoever signed in; the database keeps each
/// account to its own rows.
/// </summary>
public sealed class SupabaseApi(Uri project, string key, HttpClient? http = null) : ISyncBackend
{
    private readonly HttpClient _http = http ?? Http.Shared;

    public static readonly SupabaseApi Hosted = new(
        new Uri("https://fgqtpetuzseozttapzem.supabase.co"), "sb_publishable_WeTl_T2-z_i1ycA7KSgCyQ_9a64WoAg");

    /// <summary>Where the link in the confirmation email lands.</summary>
    public const string ConfirmedPage = "https://mmerioles.github.io/drill/confirmed/";

    private static readonly string Redirect = Uri.EscapeDataString(ConfirmedPage);

    /// <summary>Tokens this close to running out are swapped before a sync.</summary>
    private static readonly TimeSpan Margin = TimeSpan.FromMinutes(5);

    // Accounts

    public Task<Account> SignIn(string email, string password, CancellationToken ct = default) =>
        Tokens("auth/v1/token?grant_type=password", new JsonObject { ["email"] = email, ["password"] = password }, ct);

    /// <summary>
    /// Supabase answers a taken email the same as a new one, so nobody can
    /// probe who has an account, except that the user it sends back has no
    /// identities.
    /// </summary>
    public async Task<SignUp> CreateAccount(string email, string password, CancellationToken ct = default)
    {
        var text = await Call("auth/v1/signup?redirect_to=" + Redirect, null,
                              new JsonObject { ["email"] = email, ["password"] = password }, ct);
        JsonNode? reply = null;
        try { reply = JsonNode.Parse(text); } catch (JsonException) { }
        if (reply?["access_token"] is not null) return new SignUp.SignedIn(ParseAccount(text)); // confirmation is off
        if (reply?["identities"] is JsonArray { Count: 0 }) throw SyncException.Rejected("that email already has an account");
        if ((string?)reply?["id"] is not { } id) throw new SyncException(SyncFailure.Unreachable);
        return new SignUp.ConfirmByLink(id);
    }

    public async Task<bool> IsConfirmed(string userID, CancellationToken ct = default) =>
        (await Call("rest/v1/rpc/email_confirmed", null, new JsonObject { ["user_id"] = userID }, ct)).Trim() == "true";

    public Task ResendLink(string email, CancellationToken ct = default) =>
        Call("auth/v1/resend?redirect_to=" + Redirect, null, new JsonObject { ["type"] = "signup", ["email"] = email }, ct);

    public async Task<Account> Refreshed(Account account, bool force, CancellationToken ct = default)
    {
        if (account.RefreshToken is not { } refresh) throw new SyncException(SyncFailure.SignedOut);
        if (!force && account.ExpiresAt is { } expires && expires - DateTimeOffset.UtcNow > Margin) return account;
        try
        {
            return await Tokens("auth/v1/token?grant_type=refresh_token", new JsonObject { ["refresh_token"] = refresh }, ct);
        }
        catch (SyncException e) when (e.Failure == SyncFailure.Rejected)
        {
            throw new SyncException(SyncFailure.SignedOut); // the refresh token was used up or revoked
        }
    }

    public async Task SignOut(Account account)
    {
        try { await Call("auth/v1/logout?scope=local", account.Token, new JsonObject(), CancellationToken.None); }
        catch (SyncException) { }
    }

    // Sessions

    public Task Push(IReadOnlyList<FocusSession> sessions, string deviceID, string token, CancellationToken ct = default) =>
        Call("rest/v1/rpc/push_sessions", token,
             new JsonObject { ["sessions"] = JsonSerializer.SerializeToNode(sessions, FocusSession.Json) }, ct);

    public async Task<SyncPage> Pull(string cursor, string token, CancellationToken ct = default)
    {
        var after = long.TryParse(cursor, out var n) ? n : 0;
        var text = await Call("rest/v1/rpc/pull_sessions", token, new JsonObject { ["after"] = after }, ct);
        try
        {
            // The cursor may come back as a number or a string.
            var json = JsonNode.Parse(text)!;
            var sessions = json["sessions"].Deserialize<List<FocusSession>>(FocusSession.Json) ?? [];
            var next = json["cursor"]?.ToString() ?? cursor;
            return new SyncPage(sessions, next, (bool?)json["more"] ?? false);
        }
        catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException or NullReferenceException)
        {
            throw new SyncException(SyncFailure.Unreachable);
        }
    }

    // Plumbing

    private async Task<Account> Tokens(string path, JsonObject fields, CancellationToken ct) =>
        ParseAccount(await Call(path, null, fields, ct));

    private static Account ParseAccount(string text)
    {
        try
        {
            var t = JsonNode.Parse(text)!;
            return new Account(
                Email: (string?)t["user"]?["email"] ?? "",
                Token: (string)t["access_token"]!,
                Confirmed: t["user"]?["email_confirmed_at"] is not null,
                RefreshToken: (string)t["refresh_token"]!,
                ExpiresAt: DateTimeOffset.UtcNow.AddSeconds((double)t["expires_in"]!));
        }
        catch (Exception e) when (e is JsonException or NullReferenceException or InvalidOperationException or FormatException)
        {
            throw new SyncException(SyncFailure.Unreachable);
        }
    }

    /// <summary>
    /// Auth errors come as { code: 400, error_code, msg } (older ones as
    /// { error, error_description }), database errors as { code: "42501", message }.
    /// </summary>
    private static string? ErrorCode(string text)
    {
        try
        {
            var json = JsonNode.Parse(text) as JsonObject;
            foreach (var name in new[] { "error_code", "error", "code" })
            {
                if (json?[name] is JsonValue v && v.TryGetValue<string>(out var s)) return s;
            }
        }
        catch (JsonException) { }
        return null;
    }

    private async Task<string> Call(string path, string? token, JsonNode body, CancellationToken ct)
    {
        var url = new Uri(new Uri(project.AbsoluteUri.TrimEnd('/') + "/"), path);
        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        request.Headers.Add("apikey", key);
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        HttpResponseMessage response;
        string text;
        try
        {
            response = await _http.SendAsync(request, ct);
            text = await response.Content.ReadAsStringAsync(ct);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            throw new SyncException(SyncFailure.Unreachable);
        }

        using (response)
        {
            var status = (int)response.StatusCode;
            if (status is >= 200 and < 300) return text;

            var code = ErrorCode(text);
            if (code == "email_not_confirmed" || (status == 403 && code == "42501")) throw new SyncException(SyncFailure.Unconfirmed);
            if ((status == 401 && token is not null) || (status == 403 && code == "28000")) throw new SyncException(SyncFailure.SignedOut);
            if (code is not null)
            {
                if (Sentences.TryGetValue(code, out var sentence)) throw SyncException.Rejected(sentence);
                if (status >= 500) throw new SyncException(SyncFailure.Unreachable);
                throw SyncException.Rejected("something went wrong. try again.");
            }
            if (status == 429) throw SyncException.Rejected(TooMany);
            throw new SyncException(SyncFailure.Unreachable);
        }
    }

    private const string TooMany = "too many tries. give it a minute.";

    /// <summary>Supabase's error codes, in the apps' words.</summary>
    private static readonly Dictionary<string, string> Sentences = new()
    {
        ["invalid_credentials"] = "wrong email or password",
        ["invalid_grant"] = "wrong email or password",
        ["user_already_exists"] = "that email already has an account",
        ["email_exists"] = "that email already has an account",
        ["weak_password"] = "password needs 8+ characters",
        ["email_address_invalid"] = "that email doesn't look right",
        ["validation_failed"] = "that email doesn't look right",
        ["signup_disabled"] = "sign-ups are closed for now",
        ["over_email_send_rate_limit"] = "just sent one. try again in a minute.",
        ["over_request_rate_limit"] = TooMany,
        ["22023"] = "couldn't sync. try updating the app.",
    };
}
