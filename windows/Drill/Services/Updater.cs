using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Threading;
using Drill.Core.Update;

namespace Drill.Services;

public enum UpdateState { Idle, Checking, UpToDate, Available, Installing, Failed }

/// <summary>
/// Keeps the app current from GitHub releases, like mac/Sources/DrillApp/
/// Updater.swift: finds the newest release, downloads the installer for this
/// PC (arm64 on ARM, even if this build is x64), runs it silently, and quits;
/// the installer opens the new drill when it's done. Your sessions live in
/// %LOCALAPPDATA%\Drill and are untouched.
///
/// It checks at launch, every hour, when you come back to the app after a
/// while, and when you open settings.
/// </summary>
public sealed class Updater : Observable
{
    public sealed record Release(AppVersion Version, Uri Installer, Uri Page);

    private static readonly Uri Latest = new("https://api.github.com/repos/mmerioles/drill/releases/latest");
    private static readonly TimeSpan Every = TimeSpan.FromHours(1);
    /// <summary>Coming back to the app checks again once the last check is this old.</summary>
    private static readonly TimeSpan Stale = TimeSpan.FromMinutes(15);

    private static readonly HttpClient Http = MakeClient();

    private readonly DispatcherTimer _loop;
    private DateTimeOffset? _lastChecked;

    public Updater()
    {
        Current = AppVersion.Parse(Assembly.GetEntryAssembly()?
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);
        _loop = new DispatcherTimer(DispatcherPriority.Background) { Interval = Every };
        _loop.Tick += async (_, _) => await Check(quietly: true);
    }

    public AppVersion? Current { get; private set; }

    /// <summary>For --render: an installed build in a given state.</summary>
    internal void Pretend(AppVersion current, UpdateState state, AppVersion? available = null)
    {
        Current = current;
        _pretending = true;
        Available = available is { } v ? new Release(v, new Uri("https://example.invalid/"), new Uri("https://example.invalid/")) : null;
        State = state;
    }

    private bool _pretending;

    public UpdateState State
    {
        get;
        private set { if (Set(ref field, value)) { Raise(nameof(Note)); Raise(nameof(IsWorking)); } }
    } = UpdateState.Idle;

    public Release? Available { get; private set { if (Set(ref field, value)) Raise(nameof(Note)); } }
    public string? Failure { get; private set { if (Set(ref field, value)) Raise(nameof(Note)); } }

    /// <summary>Only an installed build updates itself; dev builds are 0.0.0.</summary>
    public bool IsEnabled => _pretending || (Current is { } v && v > new AppVersion(0, 0, 0) && IsInstalled);

    public bool IsWorking => State is UpdateState.Checking or UpdateState.Installing;

    public string? Note => State switch
    {
        UpdateState.UpToDate => "you're up to date.",
        UpdateState.Available => "an update is available.",
        UpdateState.Failed => Failure,
        _ => null,
    };

    /// <summary>Installed by setup, into %LOCALAPPDATA%\Programs: the folder setup owns.</summary>
    private static bool IsInstalled =>
        Environment.ProcessPath is { } exe &&
        exe.StartsWith(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"),
                       StringComparison.OrdinalIgnoreCase);

    public void Start()
    {
        if (!IsEnabled) return;
        _loop.Start();
        _ = Check(quietly: true);
        Application.Current.Activated += (_, _) => CheckIfStale(Stale);
    }

    /// <summary>A quiet check, unless one ran within `age`. Settings asks with a short age.</summary>
    public void CheckIfStale(TimeSpan? age = null)
    {
        if (State == UpdateState.Available) return; // already found one
        if (_lastChecked is { } last && DateTimeOffset.UtcNow - last < (age ?? TimeSpan.FromMinutes(1))) return;
        _ = Check(quietly: true);
    }

    /// <summary>
    /// `quietly` keeps a failed background check from showing an error. A
    /// check you asked for spins a moment even when GitHub answers at once,
    /// so the answer reads as an answer.
    /// </summary>
    public async Task Check(bool quietly = false)
    {
        if (!IsEnabled || Current is not { } current || IsWorking || _pretending) return;
        State = UpdateState.Checking;
        _lastChecked = DateTimeOffset.UtcNow;
        var settle = Task.Delay(quietly ? 0 : 900);
        Release? release;
        try { release = await FetchLatest(); } catch (Exception) { release = null; }
        await settle;
        if (release is not null)
        {
            Available = release.Version > current ? release : null;
            State = Available is null ? UpdateState.UpToDate : UpdateState.Available;
        }
        else
        {
            Failure = quietly ? null : "couldn't check for updates.";
            State = quietly ? UpdateState.Idle : UpdateState.Failed;
        }
    }

    public async Task Install()
    {
        if (Available is not { } release) return;
        State = UpdateState.Installing;
        try
        {
            var setup = await Download(release);
            Process.Start(new ProcessStartInfo(setup, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-")
            {
                UseShellExecute = true,
            });
            // Setup waits for this process to go, then opens the new drill.
            ((App)Application.Current).Quit();
        }
        catch (Exception)
        {
            Failure = "update didn't finish. try again, or grab it from the site.";
            State = UpdateState.Failed;
        }
    }

    /// <summary>The installer for this PC's processor, not this build's.</summary>
    public static string ArchSuffix =>
        RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "_arm64.exe" : "_x64.exe";

    private static async Task<Release> FetchLatest()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Latest);
        request.Headers.Add("Accept", "application/vnd.github+json");
        using var response = await Http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var json = JsonNode.Parse(await response.Content.ReadAsStringAsync())!;
        var version = AppVersion.Parse((string?)json["tag_name"]) ?? throw new FormatException();
        var asset = json["assets"]!.AsArray()
            .FirstOrDefault(a => ((string?)a?["name"])?.EndsWith(ArchSuffix, StringComparison.OrdinalIgnoreCase) == true)
            ?? throw new FormatException("no installer for this PC");
        return new Release(version, new Uri((string)asset["browser_download_url"]!), new Uri((string)json["html_url"]!));
    }

    private static string Downloads => Path.Combine(Path.GetTempPath(), "drill-update");

    /// <summary>
    /// Throws away installers from earlier updates (or half-finished
    /// downloads), off the UI thread. One still running stays, locked, till next time.
    /// </summary>
    public static void SweepDownloads() => Task.Run(() =>
    {
        try
        {
            if (!Directory.Exists(Downloads)) return;
            foreach (var file in Directory.EnumerateFiles(Downloads))
            {
                try { File.Delete(file); } catch (Exception) { } // in use
            }
        }
        catch (Exception) { }
    });

    private static async Task<string> Download(Release release)
    {
        var folder = Downloads;
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"drill_{release.Version}{ArchSuffix}");
        var partial = path + ".part";
        using (var response = await Http.GetAsync(release.Installer, HttpCompletionOption.ResponseHeadersRead))
        {
            response.EnsureSuccessStatusCode();
            await using var file = File.Create(partial);
            await response.Content.CopyToAsync(file);
        }
        File.Move(partial, path, overwrite: true);
        return path;
    }

    private static HttpClient MakeClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("drill-windows");
        return http;
    }
}
