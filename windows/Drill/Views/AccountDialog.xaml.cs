using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using Drill.Ink;
using Drill.Services;

namespace Drill.Views;

/// <summary>
/// Sign in, or make an account, as AccountSheet.swift: an email and a
/// password, then a click on the link in the confirmation email, which the
/// dialog notices by itself. The server is ours unless settings name a
/// self-hosted one.
/// </summary>
public partial class AccountDialog : UserControl
{
    private readonly Sync _sync;
    private readonly Action _dismiss;
    private bool _creating;
    private bool _working;
    private string? _note;

    public AccountDialog(Sync sync, Action dismiss)
    {
        _sync = sync;
        _dismiss = dismiss;
        InitializeComponent();
        WaitHeading.SetResourceReference(TextElement.FontFamilyProperty, "Display");
        WaitHeading.SetValue(TextElement.FontWeightProperty, FontWeights.Bold);

        Email.TextChanged += (_, _) => { EmailHint.Visibility = Email.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; ShowReady(); };
        Password.PasswordChanged += (_, _) => { PasswordHint.Visibility = Password.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed; ShowReady(); };
        Underline(Email, EmailLine, "CardLine");
        Underline(Password, PasswordLine, null);
        sync.PropertyChanged += OnSync;
        Unloaded += (_, _) => sync.PropertyChanged -= OnSync;
        Loaded += (_, _) =>
        {
            if (sync.WaitingFor is { } waiting) Email.Text = waiting.Email;
            else Keyboard.Focus(Email);
        };
        Show();
    }

    /// <summary>The field you're typing in gets a 2px ink underline; otherwise a hairline (or none).</summary>
    private static void Underline(Control field, System.Windows.Shapes.Rectangle line, string? rest)
    {
        void Rest()
        {
            line.Height = 1;
            if (rest is null) line.Fill = System.Windows.Media.Brushes.Transparent; else line.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, rest);
        }
        field.GotKeyboardFocus += (_, _) => { line.Height = 2; line.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Ink"); };
        field.LostKeyboardFocus += (_, _) => Rest();
        Rest();
    }

    private void OnSync(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(Sync.WaitingFor)) return;
        Show();
        // Once the link is clicked: a beat on the check mark, then out.
        if (_sync.WaitingFor?.Confirmed == true) _ = DismissSoon();
    }

    private async Task DismissSoon()
    {
        await Task.Delay(1400);
        _dismiss();
    }

    private void Show()
    {
        var waiting = _sync.WaitingFor;
        Details.Visibility = waiting is null ? Visibility.Visible : Visibility.Collapsed;
        WaitingPanel.Visibility = waiting is null ? Visibility.Collapsed : Visibility.Visible;

        Heading.Text = _creating ? "make an account" : "sign in";
        SwitchMode.Content = _creating ? "have an account?" : "new here?";
        Primary.Content = _creating ? "create" : "sign in";
        if (Problem.Tag is not string) Problem.Text = _creating ? "password needs 8+ characters." : "";
        Problem.Visibility = Problem.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        ShowReady();

        if (waiting is not null)
        {
            WaitHeading.Text = waiting.Confirmed ? "you're in" : "check your inbox";
            WaitNote.Text = waiting.Confirmed ? "syncing now." : _note ?? $"click the link we sent to {waiting.Email}.";
            Mark.Status = waiting.Confirmed ? StatusMark.Kind.Done : StatusMark.Kind.Pending;
            Animate.To(WaitActions, OpacityProperty, waiting.Confirmed ? 0 : 1, 250, BezierEase.InOut);
            WaitActions.IsHitTestVisible = !waiting.Confirmed;
        }
    }

    private bool Ready => Email.Text.Contains('@') && Password.Password.Length >= 8;

    private void ShowReady() => Primary.IsEnabled = Ready && !_working;

    private string TrimmedEmail => Email.Text.Trim();

    private void SetProblem(string? text)
    {
        Problem.Tag = text;
        WaitProblem.Text = text ?? "";
        Problem.Text = text ?? (_creating ? "password needs 8+ characters." : "");
        Problem.Visibility = Problem.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        WaitProblem.Visibility = WaitProblem.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Runs one call at a time, and shows what went wrong.</summary>
    private async Task Run(Func<Task> work)
    {
        if (_working) return;
        _working = true;
        SetProblem(null);
        ShowReady();
        Resend.IsEnabled = false;
        try
        {
            await work();
        }
        catch (Sync.Problem p)
        {
            SetProblem(p.Message);
        }
        catch (Exception)
        {
            SetProblem("something went wrong. try again.");
        }
        _working = false;
        Resend.IsEnabled = true;
        ShowReady();
    }

    private async void OnSubmit(object sender, RoutedEventArgs e)
    {
        if (!Ready) return;
        await Run(async () =>
        {
            _note = null;
            if (_creating) await _sync.CreateAccount(TrimmedEmail, Password.Password);
            else await _sync.SignIn(TrimmedEmail, Password.Password);
            if (_sync.WaitingFor is null) _dismiss();
        });
    }

    private void OnSwitch(object sender, RoutedEventArgs e)
    {
        _creating = !_creating;
        SetProblem(null);
        Show();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => _dismiss(); // closing keeps waiting; settings shows how it's going

    private void OnWrongEmail(object sender, RoutedEventArgs e)
    {
        _sync.StopWaiting();
        SetProblem(null);
        Show();
        Keyboard.Focus(Email);
    }

    private async void OnResend(object sender, RoutedEventArgs e) =>
        await Run(async () =>
        {
            await _sync.ResendLink();
            _note = "sent another one.";
            Show();
        });
}
