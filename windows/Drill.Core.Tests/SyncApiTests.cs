using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Drill.Core.Model;
using Drill.Core.Sync;

namespace Drill.Core.Tests;

/// <summary>
/// Runs SyncApi against the real server in web/server.py, so the two can't
/// drift apart. Needs python3 on the PATH; skipped without it.
/// </summary>
public class SyncApiTests
{
    private static readonly FocusSession Sample = new()
    {
        Id = Guid.NewGuid(),
        StartedAt = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000),
        EndedAt = DateTimeOffset.FromUnixTimeSeconds(1_790_001_500),
        FocusSeconds = 1500, PlannedSeconds = 1500, Completed = true, Tag = "15-213",
        DeviceID = "windows", UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(1_790_001_500),
    };

    [Fact]
    public async Task AccountsAndSessionsRoundTrip()
    {
        using var server = await TestServer.Start();
        if (server is null) return;
        var api = new SyncApi(server.Url);

        var me = Assert.IsType<SignUp.SignedIn>(await api.CreateAccount("Teto@Example.test", "kasane-0401")).Account;
        Assert.Equal("teto@example.test", me.Email);
        Assert.False(me.Confirmed);

        await api.Push([Sample], "windows", me.Token);
        var page = await api.Pull("0", me.Token);
        Assert.Equal([Sample], page.Sessions);
        Assert.False(page.More);
        Assert.Empty((await api.Pull(page.Cursor, me.Token)).Sessions);

        // Another account sees none of it.
        var other = Assert.IsType<SignUp.SignedIn>(await api.CreateAccount("miku@example.test", "hatsune-0831")).Account;
        Assert.Empty((await api.Pull("0", other.Token)).Sessions);

        // Signing in again works; signing out ends that token.
        var again = await api.SignIn("teto@example.test", "kasane-0401");
        await api.SignOut(again);
        var e = await Assert.ThrowsAsync<SyncException>(() => api.Pull("0", again.Token));
        Assert.Equal(SyncFailure.SignedOut, e.Failure);
    }

    [Fact]
    public async Task FriendlyRejections()
    {
        using var server = await TestServer.Start();
        if (server is null) return;
        var api = new SyncApi(server.Url);
        await api.CreateAccount("teto@example.test", "kasane-0401");

        var wrong = await Assert.ThrowsAsync<SyncException>(() => api.SignIn("teto@example.test", "not-it-at-all"));
        Assert.Equal("wrong email or password", wrong.Sentence);
        var taken = await Assert.ThrowsAsync<SyncException>(() => api.CreateAccount("teto@example.test", "kasane-0401"));
        Assert.Equal("there's already an account with that email", taken.Sentence);
    }

    [Fact]
    public async Task UnreachableServer()
    {
        var e = await Assert.ThrowsAsync<SyncException>(() => new SyncApi(new Uri("http://127.0.0.1:9")).Pull("0", "x"));
        Assert.Equal(SyncFailure.Unreachable, e.Failure);
    }

    [Fact]
    public void ServerAddresses()
    {
        Assert.Equal("https://teto.example.com/", SyncApi.ServerUrl("teto.example.com")?.AbsoluteUri);
        Assert.Equal("https://teto.example.com/", SyncApi.ServerUrl(" https://teto.example.com/ ")?.AbsoluteUri);
        Assert.Equal("http://192.168.1.4:8080/", SyncApi.ServerUrl("http://192.168.1.4:8080")?.AbsoluteUri);
        Assert.Null(SyncApi.ServerUrl(""));
        Assert.Null(SyncApi.ServerUrl("ftp://teto.example.com"));
    }

    /// <summary>web/server.py on a free port with a throwaway data folder.</summary>
    private sealed class TestServer : IDisposable
    {
        public Uri Url { get; }
        private readonly Process _process;
        private readonly string _data;

        private TestServer(Process process, Uri url, string data) => (_process, Url, _data) = (process, url, data);

        public static async Task<TestServer?> Start()
        {
            var repo = AppContext.BaseDirectory;
            while (repo is not null && !File.Exists(Path.Combine(repo, "web", "server.py"))) repo = Path.GetDirectoryName(repo);
            if (repo is null) return null;

            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();

            var data = Path.Combine(Path.GetTempPath(), $"drill-test-{Guid.NewGuid()}");
            Directory.CreateDirectory(data);
            var info = new ProcessStartInfo(OperatingSystem.IsWindows() ? "python" : "python3", Path.Combine(repo, "web", "server.py"))
            {
                RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false,
            };
            info.Environment["PORT"] = port.ToString();
            info.Environment["DRILL_DATA"] = data;
            Process process;
            try { process = Process.Start(info)!; } catch (System.ComponentModel.Win32Exception) { return null; }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            var server = new TestServer(process, new Uri($"http://127.0.0.1:{port}"), data);
            using var http = new HttpClient();
            for (var i = 0; i < 100; i++)
            {
                try
                {
                    if ((await http.GetAsync(new Uri(server.Url, "healthz"))).IsSuccessStatusCode) return server;
                }
                catch (HttpRequestException) { }
                await Task.Delay(50);
            }
            server.Dispose();
            throw new InvalidOperationException("web/server.py didn't start");
        }

        public void Dispose()
        {
            try { _process.Kill(); _process.WaitForExit(); } catch (InvalidOperationException) { }
            try { Directory.Delete(_data, recursive: true); } catch (IOException) { }
        }
    }
}
