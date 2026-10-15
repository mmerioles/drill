using System.Net;
using System.Text.Json.Nodes;
using Drill.Core.Sync;

namespace Drill.Core.Tests;

/// <summary>SupabaseApi against canned replies: the email rule, the calls, and the words for each error.</summary>
public class SupabaseApiTests
{
    [Fact]
    public void EmailRule()
    {
        Assert.True(SupabaseApi.IsEmail("teto@example.com"));
        Assert.True(SupabaseApi.IsEmail("kasane.teto+drill@mail.example.co.jp"));
        Assert.False(SupabaseApi.IsEmail(""));
        Assert.False(SupabaseApi.IsEmail("teto"));
        Assert.False(SupabaseApi.IsEmail("teto@example"));
        Assert.False(SupabaseApi.IsEmail("@example.com"));
        Assert.False(SupabaseApi.IsEmail("teto@@example.com"));
        Assert.False(SupabaseApi.IsEmail("te to@example.com"));
        Assert.True(SupabaseApi.IsEmail(new string('a', 242) + "@example.com")); // 254
        Assert.False(SupabaseApi.IsEmail(new string('a', 243) + "@example.com"));
        Assert.Equal("teto@example.com", SupabaseApi.TidyEmail(" Teto@Example.COM "));
    }

    [Fact]
    public void PasswordRule()
    {
        Assert.False(SupabaseApi.IsPassword(""));
        Assert.False(SupabaseApi.IsPassword("12345"));
        Assert.True(SupabaseApi.IsPassword("123456"));
        Assert.True(SupabaseApi.IsPassword("kä se ✨"));
        Assert.True(SupabaseApi.IsPassword(new string('a', 72)));
        Assert.False(SupabaseApi.IsPassword(new string('a', 73)));
        Assert.False(SupabaseApi.IsPassword(new string('é', 37))); // 74 bytes
        Assert.True(SupabaseApi.IsConfirmed("kasane", "kasane"));
        Assert.False(SupabaseApi.IsConfirmed("kasane", "kasan"));
        Assert.False(SupabaseApi.IsConfirmed("kasa", "kasa"));
    }

    [Fact]
    public async Task SignsUpWithTheEmail()
    {
        var (api, calls) = Fake(_ => Ok("""{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u","email":"teto@example.com"}}"""));
        var me = await api.CreateAccount(" Teto@Example.com", "kasane-0401");
        Assert.Equal("teto@example.com", me.Email);
        Assert.Equal("a", me.Token);
        Assert.Equal("r", me.RefreshToken);

        var call = Assert.Single(calls);
        Assert.Equal("/auth/v1/signup", call.Path);
        Assert.Equal("teto@example.com", (string?)call.Body["email"]);
        Assert.Equal("kasane-0401", (string?)call.Body["password"]);
        Assert.Null(call.Body["data"]);
    }

    [Fact]
    public async Task SignsInWithTheEmail()
    {
        var (api, calls) = Fake(_ => Ok("""{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"email":"teto@example.com"}}"""));
        Assert.Equal("teto@example.com", (await api.SignIn("teto@example.com", "kasane-0401")).Email);
        var call = Assert.Single(calls);
        Assert.Equal("/auth/v1/token", call.Path);
        Assert.Equal("teto@example.com", (string?)call.Body["email"]);
    }

    [Fact]
    public async Task AsksWhetherAnEmailIsFree()
    {
        var (api, calls) = Fake(_ => Ok("false"));
        Assert.False(await api.EmailAvailable("teto@example.com"));
        var call = Assert.Single(calls);
        Assert.Equal("/rest/v1/rpc/email_available", call.Path);
        Assert.Equal("teto@example.com", (string?)call.Body["email"]);

        var (free, _) = Fake(_ => Ok("true"));
        Assert.True(await free.EmailAvailable("miku@example.com"));
    }

    [Fact]
    public async Task RefreshTakesTheRealEmailForAnOldAccount()
    {
        var old = new Account("teto@users.mmerioles.github.io", "t", "r0", DateTimeOffset.UtcNow.AddHours(1), "u");
        Assert.True(old.IsLegacy);
        var (api, calls) = Fake(_ => Ok("""{"access_token":"a","refresh_token":"r1","expires_in":3600,"user":{"id":"u","email":"teto@example.com"}}"""));
        var fresh = await api.Refreshed(old, force: true);
        Assert.Equal("teto@example.com", fresh.Email);
        Assert.False(fresh.IsLegacy);
        Assert.Equal(old.UserID, fresh.UserID);
        Assert.Equal("r0", (string?)Assert.Single(calls).Body["refresh_token"]);
    }

    [Fact]
    public async Task FriendlyRejections()
    {
        const string Taken = "an account with this email already exists";
        Assert.Equal(Taken, await Sentence(HttpStatusCode.InternalServerError,
            """{"code":500,"error_code":"unexpected_failure","msg":"Database error saving new user"}""",
            api => api.CreateAccount("teto@example.com", "kasane-0401")));
        Assert.Equal(Taken, await Sentence(HttpStatusCode.UnprocessableEntity,
            """{"code":422,"error_code":"user_already_exists","msg":"User already registered"}""",
            api => api.CreateAccount("teto@example.com", "kasane-0401")));
        Assert.Equal(Taken, await Sentence(HttpStatusCode.UnprocessableEntity,
            """{"code":422,"error_code":"email_exists","msg":"Email address already registered"}""",
            api => api.CreateAccount("teto@example.com", "kasane-0401")));
        Assert.Equal("that email doesn't look right", await Sentence(HttpStatusCode.BadRequest,
            """{"code":400,"error_code":"email_address_invalid","msg":"Email address is invalid"}""",
            api => api.CreateAccount("teto@example.com", "kasane-0401")));
        Assert.Equal("use at least 6 characters", await Sentence(HttpStatusCode.UnprocessableEntity,
            """{"code":422,"error_code":"weak_password","msg":"Password should be at least 6 characters."}""",
            api => api.CreateAccount("teto@example.com", "short")));
        Assert.Equal("wrong email or password", await Sentence(HttpStatusCode.BadRequest,
            """{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}""",
            api => api.SignIn("teto@example.com", "not-it-at-all")));
    }

    [Fact]
    public async Task UnreachableServer()
    {
        var e = await Assert.ThrowsAsync<SyncException>(() => new SupabaseApi(new Uri("http://127.0.0.1:9"), "k").Pull("0", "x"));
        Assert.Equal(SyncFailure.Unreachable, e.Failure);
    }

    // Plumbing

    private static async Task<string?> Sentence(HttpStatusCode status, string reply, Func<SupabaseApi, Task> call)
    {
        var (api, _) = Fake(_ => Reply(status, reply));
        return (await Assert.ThrowsAsync<SyncException>(() => call(api))).Sentence;
    }

    private sealed record Call(string Path, JsonObject Body);

    /// <summary>An API on a fake project that answers every call with `answer`, and the calls it got.</summary>
    private static (SupabaseApi Api, List<Call> Calls) Fake(Func<Call, HttpResponseMessage> answer)
    {
        var calls = new List<Call>();
        var handler = new Handler(async request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync()) as JsonObject ?? new JsonObject();
            var call = new Call(path, body);
            calls.Add(call);
            return answer(call);
        });
        return (new SupabaseApi(new Uri("https://example.test"), "key", new HttpClient(handler)), calls);
    }

    private static HttpResponseMessage Ok(string json) => Reply(HttpStatusCode.OK, json);

    private static HttpResponseMessage Reply(HttpStatusCode status, string json) =>
        new(status) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") };

    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => answer(request);
    }
}
