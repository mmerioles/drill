using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Drill.Core.Inspo;
using Drill.Ink;

namespace Drill.Views;

/// <summary>
/// Videos to watch when focus runs thin, as InspoView.swift: today's
/// handful, and all of them, with the ones you've watched filled in.
/// </summary>
public sealed class InspoPage : UserControl
{
    private readonly Watched _watched;
    private readonly InkLink _today = new() { Content = "today", Margin = new Thickness(0, 0, 14, 0) };
    private readonly InkLink _all = new() { Content = "all" };
    private readonly StackPanel _body = new();
    private bool _showingAll;

    public InspoPage(Watched watched)
    {
        _watched = watched;
        Width = 440;
        var root = new StackPanel { Margin = new Thickness(28, 0, 28, 28) };

        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 18) };
        var links = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Bottom };
        links.Children.Add(_today);
        links.Children.Add(_all);
        DockPanel.SetDock(links, Dock.Right);
        header.Children.Add(links);
        header.Children.Add(Heading("inspo"));
        root.Children.Add(header);
        root.Children.Add(_body);
        Content = root;

        _today.Click += (_, _) => { _showingAll = false; Show(); };
        _all.Click += (_, _) => { _showingAll = true; Show(); };
        Show();
    }

    /// <summary>For --render: the full list.</summary>
    public void ShowAll()
    {
        _showingAll = true;
        Show();
    }

    private void Show()
    {
        _today.IsSelected = !_showingAll;
        _all.IsSelected = _showingAll;
        _body.Children.Clear();
        if (_showingAll) ShowAllVideos();
        else
        {
            foreach (var video in InspoVideos.ForToday(_watched.SeenBefore(InspoVideos.Today()), InspoVideos.Today()))
                _body.Children.Add(Row(video, numbered: false));
        }
    }

    /// <summary>Every video as a square, filled once watched, then the full list.</summary>
    private void ShowAllVideos()
    {
        var grid = new WrapPanel { Width = 25 * 14.5, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var video in InspoVideos.All)
        {
            var square = new Rectangle { Width = 11, Height = 11, RadiusX = 2, RadiusY = 2, Margin = new Thickness(0, 0, 3.5, 3.5), Cursor = Cursors.Hand };
            square.SetResourceReference(Shape.FillProperty, _watched.Contains(video) ? "Accent" : "Empty");
            square.ToolTip = $"{video.Number}. {video.Title}";
            square.MouseLeftButtonUp += (_, _) => Open(video);
            grid.Children.Add(square);
        }
        _body.Children.Add(grid);
        var count = Text($"{_watched.Count} of {InspoVideos.All.Count} watched", 13);
        count.Opacity = 0.45;
        count.Margin = new Thickness(0, 6, 0, 18);
        _body.Children.Add(count);

        var list = new StackPanel();
        foreach (var video in InspoVideos.All) list.Children.Add(Row(video, numbered: true));
        _body.Children.Add(new ScrollViewer
        {
            Height = 360,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            PanningMode = PanningMode.VerticalOnly,
            Content = list,
            Focusable = false,
        });
    }

    private Button Row(InspoVideos.Video video, bool numbered)
    {
        var line = new DockPanel();
        if (numbered)
        {
            var n = Text(video.Number.ToString("000"), 12);
            n.Opacity = 0.45;
            n.Margin = new Thickness(0, 1, 12, 0);
            Typography.SetNumeralAlignment(n, FontNumeralAlignment.Tabular);
            line.Children.Add(n);
        }
        var words = new StackPanel();
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        var name = Text(video.Title, 14);
        name.FontWeight = FontWeights.SemiBold;
        title.Children.Add(name);
        if (_watched.Contains(video))
        {
            var dot = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(6, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            dot.SetResourceReference(Shape.FillProperty, "Accent");
            title.Children.Add(dot);
        }
        words.Children.Add(title);
        var japanese = Text(video.Japanese, 13);
        japanese.Opacity = 0.45;
        japanese.TextWrapping = TextWrapping.Wrap;
        japanese.Margin = new Thickness(0, 2, 0, 0);
        words.Children.Add(japanese);
        line.Children.Add(words);

        var row = new Button
        {
            Content = line,
            Margin = new Thickness(0, 0, 0, 14),
            Cursor = Cursors.Hand,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            FocusVisualStyle = (Style)FindResource("FocusRing"),
            Template = Plain(),
        };
        row.MouseEnter += (_, _) => Animate.To(japanese, OpacityProperty, 1, 120);
        row.MouseLeave += (_, _) => Animate.To(japanese, OpacityProperty, 0.45, 120);
        row.Click += (_, _) => Open(video);
        System.Windows.Automation.AutomationProperties.SetName(row, video.Title);
        return row;
    }

    private void Open(InspoVideos.Video video)
    {
        _watched.Mark(video);
        try { Process.Start(new ProcessStartInfo(video.Url.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception) { } // no browser
        Show();
    }

    private static ControlTemplate Plain()
    {
        var t = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        border.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
        t.VisualTree = border;
        return t;
    }

    internal static TextBlock Heading(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 20, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Bottom };
        t.SetResourceReference(TextBlock.FontFamilyProperty, "Display");
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        TextOptions.SetTextFormattingMode(t, TextFormattingMode.Ideal);
        return t;
    }

    internal static TextBlock Text(string text, double size)
    {
        var t = new TextBlock { Text = text, FontSize = size };
        t.SetResourceReference(TextBlock.FontFamilyProperty, "Text");
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        return t;
    }
}
