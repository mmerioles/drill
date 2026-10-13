using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Drill.Ink;

namespace Drill.Services;

/// <summary>
/// drill in the notification area: the drill curl while idle, and while a
/// phase is live a small ring that fills with progress (faded while
/// paused). Monochrome, matching the taskbar's own light or dark, never
/// drill's crimson. It's redrawn only when a pixel would change: about
/// every half minute over a 25 minute block.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private const uint Id = 1;
    private const int CallbackMessage = 0x8000 + 1; // WM_APP + 1

    /// <summary>Left click, or Enter on the icon: where the icon is, in pixels.</summary>
    public event Action<Native.RECT>? Clicked;
    /// <summary>Right click, or the menu key.</summary>
    public event Action<Native.RECT>? MenuRequested;

    private readonly HwndSource _window;
    private readonly uint _taskbarCreated;
    private nint _icon;
    private string _tip = "drill";
    private (bool Live, int Bucket, bool Paused, bool Light, int Size) _drawn;
    private (bool Live, double Progress, bool Paused) _state;
    private bool _added;

    public TrayIcon()
    {
        // A hidden top-level window (not message-only: those miss the
        // broadcasts for theme changes and Explorer restarting).
        _window = new HwndSource(new HwndSourceParameters("drill tray")
        {
            Width = 0, Height = 0, WindowStyle = unchecked((int)0x80000000), // WS_POPUP
            ExtendedWindowStyle = Native.WS_EX_TOOLWINDOW,
        });
        _window.AddHook(Hook);
        _taskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");
        Add();
    }

    public void Update(bool live, double progress, bool paused, string tip)
    {
        _state = (live, progress, paused);
        var changed = Redraw();
        if (tip != _tip)
        {
            _tip = tip;
            changed = true;
        }
        if (changed) Modify();
    }

    /// <summary>Where the icon is on screen, in pixels; null when it's hidden in the overflow.</summary>
    public Native.RECT? Bounds()
    {
        var id = new Native.NOTIFYICONIDENTIFIER { cbSize = Marshal.SizeOf<Native.NOTIFYICONIDENTIFIER>(), hWnd = _window.Handle, uID = Id };
        return Native.Shell_NotifyIconGetRect(ref id, out var rect) == 0 && rect.Width > 0 ? rect : null;
    }

    public void Dispose()
    {
        if (_added)
        {
            var data = Data(0);
            Native.Shell_NotifyIcon(Native.NIM_DELETE, ref data);
            _added = false;
        }
        if (_icon != 0) Native.DestroyIcon(_icon);
        _icon = 0;
        _window.Dispose();
    }

    private Native.NOTIFYICONDATA Data(uint flags) => new()
    {
        cbSize = Marshal.SizeOf<Native.NOTIFYICONDATA>(),
        hWnd = _window.Handle,
        uID = Id,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = _tip,
        szInfo = "",
        szInfoTitle = "",
    };

    private void Add()
    {
        _drawn = default;
        Redraw();
        var data = Data(Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP);
        _added = Native.Shell_NotifyIcon(Native.NIM_ADD, ref data);
        data.uVersion = Native.NOTIFYICON_VERSION_4;
        Native.Shell_NotifyIcon(Native.NIM_SETVERSION, ref data);
    }

    private void Modify()
    {
        if (!_added) return;
        var data = Data(Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP);
        Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref data);
    }

    private nint Hook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            // Version 4: the event is in the low word of lParam, and wParam
            // holds the anchor point in screen pixels.
            var anchor = new Native.RECT
            {
                Left = (short)(wParam & 0xFFFF), Top = (short)((wParam >> 16) & 0xFFFF),
            };
            anchor.Right = anchor.Left + 1;
            anchor.Bottom = anchor.Top + 1;
            var at = Bounds() ?? anchor;
            switch ((int)(lParam & 0xFFFF))
            {
                case Native.NIN_SELECT:
                case Native.NIN_KEYSELECT:
                    Clicked?.Invoke(at);
                    break;
                case Native.WM_CONTEXTMENU:
                    MenuRequested?.Invoke(at);
                    break;
            }
            handled = true;
        }
        else if (msg == _taskbarCreated)
        {
            Add(); // Explorer restarted
        }
        else if (msg is 0x001A /* WM_SETTINGCHANGE */ or 0x007E /* WM_DISPLAYCHANGE */ or 0x02E0 /* WM_DPICHANGED */)
        {
            if (Redraw()) Modify(); // taskbar theme or scale changed
        }
        return 0;
    }

    /// <summary>Draws a new icon when the pixels would differ; true if it did.</summary>
    private bool Redraw()
    {
        var size = Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, Native.GetDpiForSystem());
        if (size <= 0) size = 16;
        var light = Native.TaskbarIsLight();
        // One step per pixel of the ring's circumference.
        var steps = (int)Math.Ceiling(Math.PI * size * 0.75);
        var bucket = _state.Live ? (int)Math.Round(_state.Progress * steps) : 0;
        var key = (_state.Live, bucket, _state.Live && _state.Paused, light, size);
        if (key == _drawn && _icon != 0) return false;
        _drawn = key;

        var old = _icon;
        _icon = Render(size, key.Live, (double)bucket / steps, key.Item3, light);
        if (old != 0) Native.DestroyIcon(old);
        return true;
    }

    /// <summary>The icon's pixels, drawn with the same ink code as the app.</summary>
    public static BitmapSource Picture(int size, bool live, double progress, bool paused, bool light)
    {
        var ink = light ? Color.FromRgb(0x1A, 0x1A, 0x1A) : Colors.White;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var s = (double)size;
            if (!live)
            {
                Glyph.Draw(dc, GlyphKind.Drill, s, Math.Clamp(s / 11, 1.25, 2), 0, ink, roughness: 0);
            }
            else
            {
                // Whole-pixel strokes: 2px at 16, so the ring's radius is 6.
                var stroke = Math.Max(2, Math.Round(s / 8));
                // Running: the arc over a faint track, at least 20° of it so a
                // fresh block still shows. Paused: pause bars, centred, with the
                // arc around them once there's room (at 16px, bars alone).
                if (!paused || size >= 20)
                    DoodleRing.Draw(dc, new Size(s, s), Math.Max(progress, 20.0 / 360), stroke / 2, 0, Palette.Current,
                                    track: paused ? Colors.Transparent : Palette.WithAlpha(ink, 0.3), ink: ink,
                                    trackWidth: stroke, dotted: false, tip: size >= 24);
                if (paused)
                {
                    var bar = Math.Max(2, Math.Round(s / 10));
                    var tall = size < 20 ? 7 : Math.Round(s * 0.28);
                    var left = Math.Round((s - (bar * 2 + 2)) / 2);
                    var top = Math.Round((s - tall) / 2);
                    var brush = Palette.Brush(ink);
                    dc.DrawRectangle(brush, null, new Rect(left, top, bar, tall));
                    dc.DrawRectangle(brush, null, new Rect(left + bar + 2, top, bar, tall));
                }
            }
        }
        var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    private static nint Render(int size, bool live, double progress, bool paused, bool light)
    {
        var bitmap = Picture(size, live, progress, paused, light);
        var pixels = new byte[size * size * 4];
        bitmap.CopyPixels(pixels, size * 4, 0);
        // Icons want straight alpha; WPF renders premultiplied.
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var a = pixels[i + 3];
            if (a is 0 or 255) continue;
            pixels[i] = (byte)Math.Min(255, pixels[i] * 255 / a);
            pixels[i + 1] = (byte)Math.Min(255, pixels[i + 1] * 255 / a);
            pixels[i + 2] = (byte)Math.Min(255, pixels[i + 2] * 255 / a);
        }
        return Native.IconFromPixels(pixels, size);
    }
}
