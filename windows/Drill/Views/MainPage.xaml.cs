using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Shapes;
using Drill.Core;
using Drill.Core.Stats;
using Drill.Ink;
using Drill.Services;

namespace Drill.Views;

/// <summary>The main window's page: header, timer, and your year.</summary>
public partial class MainPage : UserControl
{
    private readonly Shell _shell;
    private AppModel Model => _shell.Model;
    private bool _listening;
    /// <summary>Something changed while the window was hidden in the tray; caught up when it's back.</summary>
    private bool _stale;

    public MainPage(Shell shell)
    {
        _shell = shell;
        DataContext = shell;
        InitializeComponent();

        // The app's objects outlive this page: listen only while it's in a window.
        Loaded += (_, _) => Listen(true);
        Unloaded += (_, _) => Listen(false);
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible || !_stale) return;
            _stale = false;
            Show();
        };
        TagBox.GotKeyboardFocus += (_, _) => Underline.SetResourceReference(Shape.FillProperty, "Faint");
        TagBox.LostKeyboardFocus += (_, _) => Underline.SetResourceReference(Shape.FillProperty, "Ghost");
        TagBox.KeyDown += (_, e) =>
        {
            if (e.Key is Key.Enter or Key.Escape)
            {
                Focus(); // done typing: back to the page, where space starts the timer
                e.Handled = true;
            }
        };
        // Clicking empty paper ends tag editing.
        Paper.MouseLeftButtonDown += (_, _) => Focus();
        Year.HoveredChanged += ShowCaption;
        Loaded += (_, _) => Focus();

        for (var level = 0; level < 5; level++)
        {
            var swatch = new Rectangle { Width = 9, Height = 9, RadiusX = 1.5, RadiusY = 1.5, Margin = new Thickness(2, 0, 2, 0) };
            if (level == 0) swatch.SetResourceReference(Shape.FillProperty, "Empty");
            else swatch.Fill = AccentBrush(HeatGrid.Levels[level]);
            Swatches.Children.Add(swatch);
        }

        Show();
    }

    private void Listen(bool on)
    {
        if (on == _listening) return;
        _listening = on;
        if (on)
        {
            Model.PropertyChanged += OnModel;
            _shell.Updater.PropertyChanged += OnUpdater;
            Palette.Changed += Recolor;
            Recolor();
            Show(); // whatever changed while away
        }
        else
        {
            Model.PropertyChanged -= OnModel;
            _shell.Updater.PropertyChanged -= OnUpdater;
            Palette.Changed -= Recolor;
        }
    }

    private void OnUpdater(object? sender, PropertyChangedEventArgs e) => ShowUpdate();

    // Keys: space and Enter start and pause (not while typing a tag, nor
    // on a focused button, which they press), and the menu-less shortcuts
    // the mac keeps in its Timer menu.
    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        var ctrl = Keyboard.Modifiers == ModifierKeys.Control;
        var plain = Keyboard.Modifiers == ModifierKeys.None;
        var typing = TagBox.IsKeyboardFocusWithin || Keyboard.FocusedElement is TextBoxBase or PasswordBox;
        var onButton = Keyboard.FocusedElement is ButtonBase;
        switch (e.Key)
        {
            case Key.Space or Key.Enter when plain && !typing && !onButton:
            case Key.Enter when ctrl:
                Model.Toggle();
                break;
            case Key.Right when ctrl && !typing:
                Model.Skip();
                break;
            case Key.R when ctrl:
                Model.Reset();
                break;
            case Key.OemComma when ctrl:
                _shell.OpenSettings();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        // Hidden in the tray: no clock work every second, just one catch-up on return.
        if (!IsVisible)
        {
            _stale = true;
            return;
        }
        switch (e.PropertyName)
        {
            case nameof(AppModel.Clock):
                Clock.Text = Model.Clock;
                break;
            case nameof(AppModel.Spoken):
                AutomationProperties.SetName(Clock, Model.Spoken);
                break;
            case nameof(AppModel.Status):
                Status.Text = Model.Status;
                break;
            case nameof(AppModel.IsActive):
                Animate.To(ResetLink, OpacityProperty, Model.IsActive ? 1 : 0, 500, BezierEase.Out);
                ResetLink.IsEnabled = ResetLink.IsTabStop = Model.IsActive;
                ShowUpdate();
                break;
            case nameof(AppModel.Suggestions):
                ShowSuggestions();
                break;
            case nameof(AppModel.Tag):
                Hint.Visibility = Model.Tag.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
                break;
            case nameof(AppModel.RecentTags) or nameof(AppModel.TagFilter):
                ShowFilters();
                break;
            case nameof(AppModel.Heatmap):
                ShowStats();
                break;
            case null or "":
                Show();
                break;
        }
    }

    private void Show()
    {
        Clock.Text = Model.Clock;
        AutomationProperties.SetName(Clock, Model.Spoken);
        Status.Text = Model.Status;
        ResetLink.Opacity = Model.IsActive ? 1 : 0;
        ResetLink.IsEnabled = ResetLink.IsTabStop = Model.IsActive;
        Hint.Visibility = Model.Tag.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSuggestions();
        ShowFilters();
        ShowStats();
        ShowUpdate();
    }

    private void ShowSuggestions()
    {
        Suggestions.Children.Clear();
        foreach (var tag in Model.Suggestions)
        {
            var link = new InkLink { Content = tag, FontSize = 12, Margin = new Thickness(0, 0, 14, 0) };
            link.Click += (_, _) => Model.Tag = tag;
            Suggestions.Children.Add(link);
        }
    }

    private void ShowFilters()
    {
        Filters.Children.Clear();
        void Add(string label, string? tag)
        {
            var link = new InkLink { Content = label, FontSize = 13, Margin = new Thickness(12, 0, 0, 0), IsSelected = Model.TagFilter == tag };
            link.Click += (_, _) => Model.TagFilter = tag;
            Filters.Children.Add(link);
        }
        Add("all", null);
        foreach (var tag in Model.RecentTags) Add(tag, tag);
    }

    private void ShowStats()
    {
        var h = Model.Heatmap;
        Today.Text = Copy.Amount(h.Today);
        Week.Text = Copy.Amount(h.ThisWeek);
        Streak.Text = Copy.Streak(h.Streak);
        AutomationProperties.SetName(Year, Copy.YearSummary(h.Today, h.ThisWeek, h.Streak));
    }

    private void ShowCaption()
    {
        if (Year.Hovered is { } day)
        {
            DayName.Text = Copy.Day(day.Date);
            DayAmount.Text = day.Seconds > 0 ? Copy.Amount(day.Seconds) : "nothing logged.";
            DayCaption.Visibility = Visibility.Visible;
            Stats.Visibility = Legend.Visibility = Visibility.Collapsed;
        }
        else
        {
            DayCaption.Visibility = Visibility.Collapsed;
            Stats.Visibility = Legend.Visibility = Visibility.Visible;
        }
    }

    /// <summary>Offered between blocks only: updating restarts the app.</summary>
    private void ShowUpdate()
    {
        var u = _shell.Updater;
        Updating.Visibility = u.State == UpdateState.Installing ? Visibility.Visible : Visibility.Collapsed;
        if (u.State == UpdateState.Available && u.Available is { } release && !Model.IsActive)
        {
            UpdateLink.Content = $"update to {release.Version}";
            UpdateLink.Visibility = Visibility.Visible;
        }
        else
        {
            UpdateLink.Visibility = Visibility.Collapsed;
        }
    }

    private void Recolor()
    {
        for (var level = 1; level < 5; level++)
            ((Rectangle)Swatches.Children[level]).Fill = AccentBrush(HeatGrid.Levels[level]);
    }

    /// <summary>The accent at a heatmap level, for the legend.</summary>
    private static System.Windows.Media.Brush AccentBrush(double alpha) =>
        Palette.Brush(Palette.WithAlpha(Palette.Current.Accent, alpha));

    private void OnToggle(object sender, RoutedEventArgs e) => Model.Toggle();
    private void OnSkip(object sender, RoutedEventArgs e) => Model.Skip();
    private void OnReset(object sender, RoutedEventArgs e) => Model.Reset();
    private async void OnUpdate(object sender, RoutedEventArgs e) => await _shell.Updater.Install();
    private void OnInspo(object sender, RoutedEventArgs e) => _shell.OpenInspo();
    private void OnSettings(object sender, RoutedEventArgs e) => _shell.OpenSettings();

    private void OnSync(object sender, RoutedEventArgs e)
    {
        if (_shell.Sync.IsSignedIn) _shell.Sync.SyncNow();
        else _shell.ShowAccount(this);
    }
}
