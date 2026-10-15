using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Drill.Core.Search;
using Drill.Ink;

namespace Drill.Views;

/// <summary>Ctrl+K over the main page: type to find a command, Enter runs it.</summary>
public sealed class CommandPalette : Grid
{
    private const double RowHeight = 32;
    private const int VisibleRows = 8;
    private static readonly List<string> Recent = [];

    private readonly Shell _shell;
    private readonly Action _closed;
    private readonly Border _dim = new() { Opacity = 0.25 };
    private readonly Border _card = new()
    {
        CornerRadius = new CornerRadius(8),
        BorderThickness = new Thickness(1),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        Effect = new System.Windows.Media.Effects.DropShadowEffect
        {
            BlurRadius = 32, ShadowDepth = 8, Direction = 270, Opacity = 0.18, Color = Colors.Black,
        },
    };
    private readonly TranslateTransform _slide = new();
    private readonly TextBox _input = new() { FontSize = 15 };
    private readonly TextBlock _placeholder = new() { Text = "type a command…", FontSize = 15, IsHitTestVisible = false };
    private readonly StackPanel _list = new();
    private readonly ScrollViewer _scroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        MaxHeight = RowHeight * VisibleRows,
        Focusable = false,
    };
    private IReadOnlyList<Ranked> _rows = [];
    private Dictionary<string, Action> _actions = new();
    private int _selected;
    private bool _open;
    private Point _mouse;

    public CommandPalette(Shell shell, Action closed)
    {
        _shell = shell;
        _closed = closed;
        Visibility = Visibility.Collapsed;

        _dim.SetResourceReference(Border.BackgroundProperty, "Smoke");
        _dim.MouseLeftButtonDown += (_, _) => Close();
        _card.SetResourceReference(Border.BackgroundProperty, "Raised");
        _card.SetResourceReference(Border.BorderBrushProperty, "Border");
        _card.RenderTransform = _slide;

        _input.SetResourceReference(StyleProperty, "Bare");
        InkFrame.AutomationName(_input, "command");
        _placeholder.SetResourceReference(TextBlock.ForegroundProperty, "Hint");
        _placeholder.SetResourceReference(TextBlock.FontFamilyProperty, "Text");
        _input.TextChanged += (_, _) =>
        {
            _placeholder.Visibility = _input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _selected = 0;
            Show();
        };
        _input.PreviewKeyDown += OnKey;

        var field = new Grid { Margin = new Thickness(16, 12, 16, 12) };
        field.Children.Add(_placeholder);
        field.Children.Add(_input);
        var rule = new Border { Height = 1 };
        rule.SetResourceReference(Border.BackgroundProperty, "Ghost");
        _list.Margin = new Thickness(6);
        _scroll.Content = _list;
        var body = new StackPanel();
        body.Children.Add(field);
        body.Children.Add(rule);
        body.Children.Add(_scroll);
        _card.Child = body;

        Children.Add(_dim);
        Children.Add(_card);
        SizeChanged += (_, _) => Place();
        MouseMove += (_, e) => _mouse = e.GetPosition(this);
    }

    public bool IsOpen => _open;

    public void Open(string query = "")
    {
        _open = true;
        IsHitTestVisible = true;
        Visibility = Visibility.Visible;
        _input.Text = query;
        _input.CaretIndex = query.Length;
        _selected = 0;
        Show();
        Place();
        Animate.Settle(_card, OpacityProperty, 0, 1, 120, BezierEase.Out);
        Animate.Settle(_slide, TranslateTransform.YProperty, -6, 0, 120, BezierEase.Out);
        Animate.Settle(_dim, OpacityProperty, 0, 0.25, 120, BezierEase.Out);
        Dispatcher.InvokeAsync(() => _input.Focus(), DispatcherPriority.Input);
    }

    public void Close()
    {
        if (!_open) return;
        _open = false;
        IsHitTestVisible = false;
        Animate.Settle(_dim, OpacityProperty, _dim.Opacity, 0, 80, BezierEase.Accelerate);
        Animate.Settle(_card, OpacityProperty, _card.Opacity, 0, 80, BezierEase.Accelerate, () =>
        {
            if (_open) return; // reopened meanwhile
            Visibility = Visibility.Collapsed;
        });
        _closed();
    }

    private void Place()
    {
        _card.Width = Math.Min(520, Math.Max(0, ActualWidth - 32));
        _card.Margin = new Thickness(0, ActualHeight * 0.2, 0, 0);
    }

    /// <summary>What applies right now, with what each one does.</summary>
    private List<Command> Commands()
    {
        var model = _shell.Model;
        var sync = _shell.Sync;
        var list = new List<Command>();
        _actions = new();
        void Add(Command c, Action run)
        {
            list.Add(c);
            _actions[c.Id] = run;
        }

        Add(new("toggle", model.PrimaryLabel, "space", ["timer", "start", "pause", "resume"]), model.Toggle);
        Add(new("skip", "skip", "ctrl+→", ["timer"]), model.Skip);
        if (model.IsActive) Add(new("reset", "reset", "ctrl+r", ["timer"]), model.Reset);
        Add(new("settings", "open settings", "ctrl+,", ["preferences"]), _shell.OpenSettings);
        Add(new("inspo", "open inspo"), _shell.OpenInspo);
        if (sync.IsSignedIn)
        {
            Add(new("sync", "sync now"), sync.SyncNow);
            Add(new("autosync", sync.AutoSync ? "turn auto sync off" : "turn auto sync on"), () => sync.AutoSync = !sync.AutoSync);
        }
        foreach (var tag in model.RecentTags) Add(new($"tag:{tag}", $"studying {tag}"), () => model.Tag = tag);
        Add(new("filter:", "show all"), () => model.TagFilter = null);
        foreach (var tag in model.RecentTags) Add(new($"filter:{tag}", $"show {tag}"), () => model.TagFilter = tag);
        return list;
    }

    private void Show()
    {
        var query = _input.Text;
        var rows = Finder.Rank(query, Commands(), Recent).ToList();
        if (Finder.NewTag(query, _shell.Model.RecentTags) is { } fresh)
        {
            var tag = query.Trim();
            _actions[fresh.Id] = () => _shell.Model.Tag = tag;
            rows.Add(new Ranked(fresh, 0, null));
        }
        _rows = rows;
        _list.Children.Clear();
        if (rows.Count == 0)
        {
            var none = new TextBlock { Text = "no matches", FontSize = 14, Opacity = InkLink.Rest, Margin = new Thickness(10, 7, 10, 7) };
            none.SetResourceReference(StyleProperty, "Base");
            _list.Children.Add(none);
            return;
        }
        for (var i = 0; i < rows.Count; i++) _list.Children.Add(Row(rows[i], i));
        Highlight();
    }

    private Border Row(Ranked row, int index)
    {
        var dock = new DockPanel { LastChildFill = true };
        if (row.Command.Hint is { } hint)
        {
            var h = new TextBlock { Text = hint, FontSize = 12, Opacity = InkLink.Rest, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
            h.SetResourceReference(StyleProperty, "Base");
            DockPanel.SetDock(h, Dock.Right);
            dock.Children.Add(h);
        }
        var title = new TextBlock { FontSize = 14, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        title.SetResourceReference(StyleProperty, "Base");
        var text = row.Command.Title;
        for (var i = 0; i < text.Length; i++)
        {
            var run = new Run(text[i].ToString());
            run.SetResourceReference(TextElement.ForegroundProperty, row.Highlight is null || row.Highlight.Contains(i) ? "Ink" : "Faint");
            title.Inlines.Add(run);
        }
        dock.Children.Add(title);

        var border = new Border
        {
            Child = dock,
            Height = RowHeight,
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(5),
            Background = Brushes.Transparent,
        };
        border.MouseMove += (_, e) =>
        {
            // Only a real move selects: rows appearing under a still pointer don't.
            var at = e.GetPosition(this);
            if (at == _mouse || _selected == index) return;
            _mouse = at;
            _selected = index;
            Highlight();
        };
        border.MouseLeftButtonUp += (_, _) => Execute(index);
        return border;
    }

    private void Highlight()
    {
        for (var i = 0; i < _list.Children.Count; i++)
        {
            if (_list.Children[i] is not Border b) continue;
            if (i == _selected)
            {
                b.SetResourceReference(Border.BackgroundProperty, "Hover");
                b.BringIntoView();
            }
            else b.Background = Brushes.Transparent;
        }
    }

    private void Move(int by)
    {
        if (_rows.Count == 0) return;
        _selected = ((_selected + by) % _rows.Count + _rows.Count) % _rows.Count;
        Highlight();
    }

    private void Execute(int index)
    {
        if (index < 0 || index >= _rows.Count) return;
        var id = _rows[index].Command.Id;
        var action = _actions[id];
        Close();
        if (id != "new-tag") Finder.Remember(Recent, id);
        action();
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers == ModifierKeys.Control;
        switch (e.Key)
        {
            case Key.Escape:
                Close();
                break;
            case Key.Enter:
                Execute(_selected);
                break;
            case Key.Down:
            case Key.N when ctrl:
                Move(1);
                break;
            case Key.Up:
            case Key.P when ctrl:
                Move(-1);
                break;
            default:
                return;
        }
        e.Handled = true;
    }
}
