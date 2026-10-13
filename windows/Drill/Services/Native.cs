using System.Runtime.InteropServices;
using System.Windows;
using Microsoft.Win32;

namespace Drill.Services;

/// <summary>The handful of Win32 calls WPF doesn't wrap.</summary>
public static partial class Native
{
    // Windows

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWA_CAPTION_COLOR = 35;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    private const int DWMWCP_ROUND = 2;
    private const int DWMWCP_ROUNDSMALL = 3;
    private const int DWMSBT_NONE = 1;

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    /// <summary>
    /// The frame Windows draws around ours: dark or light to match, rounded
    /// corners, a border and caption in paper, and no Mica behind the paper.
    /// Failing quietly on Windows 10, which has none of these.
    /// </summary>
    public static void StyleFrame(nint hwnd, bool dark, System.Windows.Media.Color paper, bool small = false)
    {
        var on = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int));
        var corner = small ? DWMWCP_ROUNDSMALL : DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
        var backdrop = DWMSBT_NONE;
        DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
        var caption = paper.R | paper.G << 8 | paper.B << 16; // COLORREF is 0x00BBGGRR
        DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
    }

    /// <summary>A 1px outline Windows draws on our rounded corners.</summary>
    public static void SetBorder(nint hwnd, System.Windows.Media.Color color)
    {
        var c = color.R | color.G << 8 | color.B << 16;
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref c, sizeof(int));
    }

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SetCurrentProcessExplicitAppUserModelID(string appID);

    /// <summary>Ties the taskbar button and toasts to the Start menu shortcut setup made.</summary>
    public static void SetAppId(string id) => SetCurrentProcessExplicitAppUserModelID(id);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(nint hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ShowWindow(nint hwnd, int cmd);

    public const int SW_RESTORE = 9;

    [LibraryImport("user32.dll")]
    public static partial int GetWindowLongW(nint hwnd, int index);

    [LibraryImport("user32.dll")]
    public static partial int SetWindowLongW(nint hwnd, int index, int value);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetLayeredWindowAttributes(nint hwnd, uint key, byte alpha, uint flags);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_LAYERED = 0x80000;
    public const int WS_EX_TOOLWINDOW = 0x80;
    public const uint LWA_ALPHA = 0x2;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);

    public const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(nint hwnd, out RECT rect);

    [LibraryImport("user32.dll")]
    public static partial uint GetDpiForWindow(nint hwnd);

    /// <summary>A window's display scale: 1.0 at 100%, 1.5 at 150%.</summary>
    public static double ScaleOf(nint hwnd) => GetDpiForWindow(hwnd) is var dpi and > 0 ? dpi / 96.0 : 1;

    // Monitors

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [LibraryImport("user32.dll")]
    private static partial nint MonitorFromRect(ref RECT rect, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetMonitorInfo(nint monitor, ref MONITORINFO info);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out POINT point);

    [LibraryImport("shcore.dll")]
    private static partial int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    /// <summary>The monitor and work area (in pixels) around a rect, and its scale.</summary>
    public static (RECT Monitor, RECT Work, double Scale) MonitorAround(RECT rect)
    {
        var monitor = MonitorFromRect(ref rect, 2 /* MONITOR_DEFAULTTONEAREST */);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(monitor, ref info);
        var scale = GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 ? dpi / 96.0 : 1;
        return (info.rcMonitor, info.rcWork, scale);
    }

    public static RECT CursorRect()
    {
        GetCursorPos(out var p);
        return new RECT { Left = p.X, Top = p.Y, Right = p.X + 1, Bottom = p.Y + 1 };
    }

    // Notification area

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATA
    {
        public int cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER
    {
        public int cbSize;
        public nint hWnd;
        public uint uID;
        public Guid guidItem;
    }

    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    public const uint NOTIFYICON_VERSION_4 = 4;
    public const int NIN_SELECT = 0x400, NIN_KEYSELECT = 0x401;
    public const int WM_CONTEXTMENU = 0x7B, WM_LBUTTONUP = 0x202, WM_RBUTTONUP = 0x205;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")]
    [return: MarshalAs(UnmanagedType.Bool)]
#pragma warning disable SYSLIB1054 // the struct has by-value strings, which LibraryImport can't marshal
    public static extern bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATA data);
#pragma warning restore SYSLIB1054

    [LibraryImport("shell32.dll")]
    public static partial int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT rect);

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint RegisterWindowMessageW(string name);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyIcon(nint icon);

    [LibraryImport("user32.dll")]
    public static partial nint CreateIconIndirect(ref ICONINFO info);

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO
    {
        public int fIcon; // BOOL
        public int xHotspot;
        public int yHotspot;
        public nint hbmMask;
        public nint hbmColor;
    }

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, nint bits);

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, [In] byte[] bits);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DeleteObject(nint obj);

    [LibraryImport("user32.dll")]
    public static partial int GetSystemMetricsForDpi(int index, uint dpi);

    [LibraryImport("user32.dll")]
    public static partial uint GetDpiForSystem();

    public const int SM_CXSMICON = 49;

    /// <summary>An HICON from premultiplied BGRA pixels, top row first.</summary>
    public static nint IconFromPixels(byte[] bgra, int size)
    {
        var mask = new byte[(size + 15) / 16 * 2 * size]; // all zeros: alpha decides
        var info = new ICONINFO
        {
            fIcon = 1,
            hbmColor = CreateBitmap(size, size, 1, 32, bgra),
            hbmMask = CreateBitmap(size, size, 1, 1, mask),
        };
        var icon = CreateIconIndirect(ref info);
        DeleteObject(info.hbmColor);
        DeleteObject(info.hbmMask);
        return icon;
    }

    /// <summary>Whether the taskbar (not apps) is in light mode — what tray icons should match.</summary>
    public static bool TaskbarIsLight()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    /// <summary>Pixels to DIPs on a monitor at `scale`.</summary>
    public static Rect ToDips(RECT r, double scale) =>
        new(r.Left / scale, r.Top / scale, r.Width / scale, r.Height / scale);
}
