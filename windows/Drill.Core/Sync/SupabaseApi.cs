using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Drill.Core.Model;

namespace Drill.Core.Sync;

/// <summary>
/// drill's hosted sync: Supabase Auth for accounts, and the functions in
/// supabase/migrations for sessions. The publishable key is meant to ship in
/// apps; row-level security keeps each account to its own rows.
/// </summary>
public sealed class SupabaseApi(Uri project, string key, HttpClient? http = null)
{
    private readonly HttpClient _http = http ?? Http.Shared;

    public static readonly SupabaseApi Hosted = new(
        new Uri("https://fgqtpetuzseozttapzem.supabase.co"), "sb_publishable_WeTl_T2-z_i1ycA7KSgCyQ_9a64WoAg");

    /// <summary>
    /// Supabase wants an email per user. Accounts are a username, so each
    /// gets one here and never sees it: a domain of ours that takes no mail.
    /// </summary>
    public const string Domain = "users.mmerioles.github.io";

    /// <summary>Tokens this close to running out are swapped before a sync.</summary>
    private static readonly TimeSpan Margin = TimeSpan.FromMinutes(5);

    // Usernames

    public static string EmailFor(string username) => username + "@" + Domain;

    public static string UsernameOf(string email) => email.Split('@')[0];

    /// <summary>3–20 of a-z, 0-9 and _, as the database checks.</summary>
    public static bool IsUsername(string name) =>
        name.Length is >= 3 and <= 20 && name.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '_');

    /// <summary>What a username field keeps as you type: lowercase, no spaces.</summary>
    public static string TidyUsername(string text) =>
        string.Concat(text.Where(c => !char.IsWhiteSpace(c))).ToLowerInvariant();

    // Accounts

    public Task<Account> SignIn(string username, string password, CancellationToken ct = default) =>
        Tokens("auth/v1/token?grant_type=password",
               new JsonObject { ["email"] = EmailFor(username), ["password"] = password }, ct);

    /// <summary>
    /// The username rides along as metadata; a trigger makes the profile from
    /// it. Confirmation is off, so the reply carries tokens: signed in at once.
    /// </summary>
    public Task<Account> CreateAccount(string username, string password, CancellationToken ct = default) =>
        Tokens("auth/v1/signup", new JsonObject
        {
            ["email"] = EmailFor(username), ["password"] = password,
            ["data"] = new JsonObject { ["username"] = username },
        }, ct);

    /// <summary>The live check while typing a name. False for one failing the rule too.</summary>
    public async Task<bool> UsernameAvailable(string name, CancellationToken ct = default) =>
        (await Call("rest/v1/rpc/username_available", null, new JsonObject { ["name"] = name }, ct)).Trim() == "true";

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
                RefreshToken: (string)t["refresh_token"]!,
                ExpiresAt: DateTimeOffset.UtcNow.AddSeconds((double)t["expires_in"]!),
                Id: (string?)t["user"]?["id"]);
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
            if ((status == 401 && token is not null) || (status == 403 && code == "28000")) throw new SyncException(SyncFailure.SignedOut);
            // The profile trigger refusing a sign-up: a name taken in a race, or one that fails the rule.
            if (text.Contains("Database error")) throw SyncException.Rejected(Taken);
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

    private const string Taken = "that username is taken";
    private const string TooMany = "too many tries. give it a minute.";

    /// <summary>Supabase's error codes, in the apps' words.</summary>
    private static readonly Dictionary<string, string> Sentences = new()
    {
        ["invalid_credentials"] = "wrong username or password",
        ["invalid_grant"] = "wrong username or password",
        ["user_already_exists"] = Taken,
        ["email_exists"] = Taken,
        ["weak_password"] = "use at least 8 characters",
        ["email_address_invalid"] = "that username doesn't look right",
        ["validation_failed"] = "that username doesn't look right",
        ["signup_disabled"] = "sign-ups are closed for now",
        ["over_request_rate_limit"] = TooMany,
        ["22023"] = "couldn't sync. try updating the app.",
    };
}
