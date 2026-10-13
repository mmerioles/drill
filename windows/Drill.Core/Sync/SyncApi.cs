using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Drill.Core.Model;

namespace Drill.Core.Sync;

/// <summary>
/// A self-hosted sync server's API, as in docs/SYNC.md. Stateless: callers
/// keep the account, cursor and push mark.
/// </summary>
public sealed class SyncApi(Uri server, HttpClient? http = null) : ISyncBackend
{
    private readonly HttpClient _http = http ?? Http.Shared;
    public Uri Server { get; } = server;

    /// <summary>
    /// "teto.example.com" and "https://teto.example.com/" both become
    /// https://teto.example.com. Plain http is kept when typed, for a server
    /// on your own network.
    /// </summary>
    public static Uri? ServerUrl(string text)
    {
        text = text.Trim().TrimEnd('/');
        if (!text.Contains("://")) text = "https://" + text;
        return Uri.TryCreate(text, UriKind.Absolute, out var url)
               && url.Scheme is "http" or "https" && url.Host.Length > 0 ? url : null;
    }

    // Accounts

    public async Task<Account> SignIn(string email, string password, CancellationToken ct = default) =>
        ParseAccount(await Call("v1/signin", null, new JsonObject { ["email"] = email, ["password"] = password }, ct));

    /// <summary>Always signed in: a self-hosted account syncs before it's confirmed, unless the server says otherwise.</summary>
    public async Task<SignUp> CreateAccount(string email, string password, CancellationToken ct = default) =>
        new SignUp.SignedIn(ParseAccount(await Call("v1/accounts", null, new JsonObject { ["email"] = email, ["password"] = password }, ct)));

    public Task<bool> IsConfirmed(string userID, CancellationToken ct = default) => Task.FromResult(true);

    public Task ResendLink(string email, CancellationToken ct = default) =>
        throw SyncException.Rejected("this server sends its own confirmation emails");

    public Task<Account> Refreshed(Account account, bool force, CancellationToken ct = default) =>
        force ? throw new SyncException(SyncFailure.SignedOut) : Task.FromResult(account);

    /// <summary>Revokes the token.</summary>
    public async Task SignOut(Account account)
    {
        try { await Call("v1/signout", account.Token, new JsonObject(), CancellationToken.None); }
        catch (SyncException) { }
    }

    // Sessions

    public async Task Push(IReadOnlyList<FocusSession> sessions, string deviceID, string token, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["deviceID"] = deviceID,
            ["sessions"] = JsonSerializer.SerializeToNode(sessions, FocusSession.Json),
        };
        await Call("v1/sessions/push", token, body, ct);
    }

    public async Task<SyncPage> Pull(string cursor, string token, CancellationToken ct = default)
    {
        var text = await Call("v1/sessions/pull?cursor=" + Uri.EscapeDataString(cursor), token, null, ct);
        try { return JsonSerializer.Deserialize<SyncPage>(text, FocusSession.Json) ?? throw new JsonException(); }
        catch (Exception e) when (e is JsonException or FormatException) { throw new SyncException(SyncFailure.Unreachable); }
    }

    // Plumbing

    private static Account ParseAccount(string text)
    {
        try
        {
            var json = JsonNode.Parse(text)!;
            return new Account((string)json["email"]!, (string)json["token"]!, (bool?)json["confirmed"] ?? false);
        }
        catch (Exception e) when (e is JsonException or NullReferenceException or InvalidOperationException or FormatException)
        {
            throw new SyncException(SyncFailure.Unreachable);
        }
    }

    private async Task<string> Call(string path, string? token, JsonNode? body, CancellationToken ct)
    {
        var url = new Uri(new Uri(Server.AbsoluteUri.TrimEnd('/') + "/"), path);
        using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, url);
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

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
            if (response.IsSuccessStatusCode) return text;
            if (response.StatusCode == HttpStatusCode.Unauthorized && token is not null) throw new SyncException(SyncFailure.SignedOut);
            if (response.StatusCode == HttpStatusCode.Forbidden) throw new SyncException(SyncFailure.Unconfirmed);
            string? message = null;
            try { message = (string?)JsonNode.Parse(text)?["error"]; } catch (JsonException) { }
            throw message is not null ? SyncException.Rejected(message) : new SyncException(SyncFailure.Unreachable);
        }
    }
}
