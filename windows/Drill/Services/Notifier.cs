using System.IO;
using System.Media;
using System.Security;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace Drill.Services;

/// <summary>
/// "focus done" toasts, as Windows notifications from drill (the Start menu
/// shortcut setup made carries drill's AppUserModelID, which is what lets an
/// unpackaged app post them). Silent: drill plays its own chime, so it
/// doesn't sound twice. Quietly does nothing where toasts aren't available.
/// </summary>
public sealed class Notifier
{
    public const string AppId = "mmerioles.drill";

    private ToastNotifier? _notifier;

    /// <summary>When the toast's one button ("start") or its body ("open") is pressed.</summary>
    public event Action<string>? Acted;

    /// <param name="action">A button, like ("start break", "start").</param>
    /// <returns>Whether the toast went out.</returns>
    public bool Post(string title, string body, (string Label, string Argument)? action = null)
    {
        try
        {
            _notifier ??= ToastNotificationManager.CreateToastNotifier(AppId);
            var actions = action is { } a
                ? $"""<actions><action content="{Escape(a.Label)}" arguments="{Escape(a.Argument)}" activationType="foreground"/></actions>"""
                : "";
            var xml = new XmlDocument();
            xml.LoadXml($"""
                <toast launch="open">
                  <visual><binding template="ToastGeneric"><text>{Escape(title)}</text><text>{Escape(body)}</text></binding></visual>
                  <audio silent="true"/>
                  {actions}
                </toast>
                """);
            var toast = new ToastNotification(xml) { ExpirationTime = DateTimeOffset.Now.AddMinutes(30) };
            toast.Activated += (_, args) =>
            {
                if (args is ToastActivatedEventArgs e && e.Arguments.Length > 0) Acted?.Invoke(e.Arguments);
            };
            _notifier.Show(toast);
            // Turned off for drill (or all apps): nothing shows, though Show didn't complain.
            return _notifier.Setting == NotificationSetting.Enabled;
        }
        catch (Exception)
        {
            // No shortcut with our id (a dev build), or notifications are off.
            return false;
        }
    }

    private static string Escape(string s) => SecurityElement.Escape(s) ?? "";
}

/// <summary>
/// drill's two sounds, made at launch rather than borrowed from Windows, so
/// they're the same on every PC: a glassy two-note chime when focus ends, a
/// single soft tink when a break does.
/// </summary>
public static class Chime
{
    private static readonly Lazy<byte[]> Glass = new(() => Wave([(1318.5, 0, 1.0), (1975.5, 0.11, 0.75)], 1.6));
    private static readonly Lazy<byte[]> Tink = new(() => Wave([(2093.0, 0, 0.8)], 0.7));
    private static SoundPlayer? _player;

    public static void FocusDone() => Play(Glass.Value);

    public static void BreakOver() => Play(Tink.Value);

    private static void Play(byte[] wav)
    {
        try
        {
            _player?.Stop();
            _player = new SoundPlayer(new MemoryStream(wav, writable: false));
            _player.Play(); // on its own thread; never blocks the UI
        }
        catch (Exception) { } // no audio device
    }

    /// <summary>
    /// Bell-like notes: each a sine with a quieter octave and twelfth above
    /// it, a 4ms attack and an exponential ring-out. 16-bit mono, 44.1kHz.
    /// </summary>
    private static byte[] Wave((double Hz, double Start, double Gain)[] notes, double seconds)
    {
        const int rate = 44100;
        var count = (int)(rate * seconds);
        var samples = new double[count];
        foreach (var (hz, start, gain) in notes)
        {
            var from = (int)(start * rate);
            for (var i = from; i < count; i++)
            {
                var t = (double)(i - from) / rate;
                var attack = Math.Min(1, t / 0.004);
                var decay = Math.Exp(-t * 4.2);
                var tone = Math.Sin(2 * Math.PI * hz * t)
                           + 0.28 * Math.Sin(2 * Math.PI * hz * 2.0 * t) * Math.Exp(-t * 6)
                           + 0.12 * Math.Sin(2 * Math.PI * hz * 3.0 * t) * Math.Exp(-t * 9);
                samples[i] += tone * attack * decay * gain;
            }
        }
        var peak = samples.Max(Math.Abs);
        var scale = peak > 0 ? 0.32 / peak : 0; // soft: about -10 dBFS

        using var stream = new MemoryStream();
        using (var w = new BinaryWriter(stream, System.Text.Encoding.ASCII, leaveOpen: true))
        {
            w.Write("RIFF"u8);
            w.Write(36 + count * 2);
            w.Write("WAVEfmt "u8);
            w.Write(16);
            w.Write((short)1); // PCM
            w.Write((short)1); // mono
            w.Write(rate);
            w.Write(rate * 2);
            w.Write((short)2);
            w.Write((short)16);
            w.Write("data"u8);
            w.Write(count * 2);
            // A short fade at the very end, so it never clicks.
            for (var i = 0; i < count; i++)
            {
                var tail = Math.Min(1, (count - i) / (rate * 0.05));
                w.Write((short)Math.Round(samples[i] * scale * tail * short.MaxValue));
            }
        }
        return stream.ToArray();
    }
}
