using System.Net;
using System.Text.Json.Nodes;
using Drill.Core.Sync;

namespace Drill.Core.Tests;

/// <summary>SupabaseApi against canned replies: the username rule, the synthetic email, and the words for each error.</summary>
public class SupabaseApiTests
{
    [Fact]
    public void UsernameRule()
    {
        Assert.True(SupabaseApi.IsUsername("teto"));
        Assert.True(SupabaseApi.IsUsername("kasane_0401"));
        Assert.True(SupabaseApi.IsUsername(new string('a', 20)));
        Assert.False(SupabaseApi.IsUsername("te"));
        Assert.False(SupabaseApi.IsUsername(new string('a', 21)));
        Assert.False(SupabaseApi.IsUsername("Teto"));
        Assert.False(SupabaseApi.IsUsername("teto!"));
        Assert.False(SupabaseApi.IsUsername("te to"));
        Assert.False(SupabaseApi.IsUsername(""));
        Assert.Equal("teto_0401", SupabaseApi.TidyUsername(" Teto_ 0401 "));
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
    public void SyntheticEmail()
    {
        Assert.Equal("teto@users.mmerioles.github.io", SupabaseApi.EmailFor("teto"));
        Assert.Equal("teto", SupabaseApi.UsernameOf("teto@users.mmerioles.github.io"));
        Assert.Equal("teto", new Account("teto@users.mmerioles.github.io", "t").Username);
    }

    [Fact]
    public async Task SignsUpWithTheUsernameAsMetadata()
    {
        var (api, calls) = Fake(_ => Ok("""{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"email":"teto@users.mmerioles.github.io"}}"""));
        var me = await api.CreateAccount("teto", "kasane-0401");
        Assert.Equal("teto", me.Username);
        Assert.Equal("a", me.Token);
        Assert.Equal("r", me.RefreshToken);

        var call = Assert.Single(calls);
        Assert.Equal("/auth/v1/signup", call.Path);
        Assert.Equal("teto@users.mmerioles.github.io", (string?)call.Body["email"]);
        Assert.Equal("kasane-0401", (string?)call.Body["password"]);
        Assert.Equal("teto", (string?)call.Body["data"]?["username"]);
    }

    [Fact]
    public async Task SignsInWithTheSyntheticEmail()
    {
        var (api, calls) = Fake(_ => Ok("""{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"email":"teto@users.mmerioles.github.io"}}"""));
        Assert.Equal("teto", (await api.SignIn("teto", "kasane-0401")).Username);
        var call = Assert.Single(calls);
        Assert.Equal("/auth/v1/token", call.Path);
        Assert.Equal("teto@users.mmerioles.github.io", (string?)call.Body["email"]);
    }

    [Fact]
    public async Task AsksWhetherANameIsFree()
    {
        var (api, calls) = Fake(_ => Ok("false"));
        Assert.False(await api.UsernameAvailable("teto"));
        var call = Assert.Single(calls);
        Assert.Equal("/rest/v1/rpc/username_available", call.Path);
        Assert.Equal("teto", (string?)call.Body["name"]);

        var (free, _) = Fake(_ => Ok("true"));
        Assert.True(await free.UsernameAvailable("miku"));
    }

    [Fact]
    public async Task FriendlyRejections()
    {
        Assert.Equal("that username is taken", await Sentence(HttpStatusCode.InternalServerError,
            """{"code":500,"error_code":"unexpected_failure","msg":"Database error saving new user"}""",
            api => api.CreateAccount("teto", "kasane-0401")));
        Assert.Equal("that username is taken", await Sentence(HttpStatusCode.UnprocessableEntity,
            """{"code":422,"error_code":"user_already_exists","msg":"User already registered"}""",
            api => api.CreateAccount("teto", "kasane-0401")));
        Assert.Equal("use at least 6 characters", await Sentence(HttpStatusCode.UnprocessableEntity,
            """{"code":422,"error_code":"weak_password","msg":"Password should be at least 6 characters."}""",
            api => api.CreateAccount("teto", "short")));
        Assert.Equal("wrong username or password", await Sentence(HttpStatusCode.BadRequest,
            """{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}""",
            api => api.SignIn("teto", "not-it-at-all")));
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
