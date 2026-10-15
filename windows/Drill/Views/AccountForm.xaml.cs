using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Drill.Core.Sync;
using Drill.Ink;
using Drill.Services;

namespace Drill.Views;

/// <summary>
/// Sign in, or make an account, as AccountSheet.swift: a username and a
/// password. On the create form each field gets a mark as you type (the name
/// checked 300ms after the last keystroke); the password is typed twice. In
/// the account dialog, and inline on the welcome.
/// </summary>
public partial class AccountForm : UserControl
{
    /// <summary>Where the username check stands.</summary>
    private enum Check { None, Rule, Checking, Available, Taken, Unknown }

    private readonly Sync _sync;
    private readonly Action _done;
    private readonly Action? _cancel;
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private readonly Action[] _rest;
    private CancellationTokenSource? _checking;
    private Check _check;
    private bool _creating;
    private bool _working;

    /// <param name="done">Signed in.</param>
    /// <param name="cancel">Null: no cancel link, as on the welcome.</param>
    /// <param name="heading">False: no heading, as on the welcome, which has its own.</param>
    public AccountForm(Sync sync, Action done, Action? cancel, bool creating = false, bool heading = true)
    {
        _sync = sync;
        _done = done;
        _cancel = cancel;
        _creating = creating;
        InitializeComponent();
        if (!heading) Heading.Visibility = Visibility.Collapsed;
        if (cancel is null)
        {
            Cancel.IsCancel = false;
            Cancel.Visibility = Visibility.Collapsed;
        }
        _rest =
        [
            Underline(Username, UsernameLine, () => "CardLine"),
            Underline(Password, PasswordLine, () => _creating ? "CardLine" : null),
            Underline(Confirm, ConfirmLine, () => null),
        ];
        Username.TextChanged += (_, _) => { SetProblem(null); OnUsername(); };
        Password.PasswordChanged += (_, _) => { SetProblem(null); PasswordHint.Visibility = HintFor(Password.Password); ShowPasswords(); };
        Confirm.PasswordChanged += (_, _) => { SetProblem(null); ConfirmHint.Visibility = HintFor(Confirm.Password); ShowPasswords(); };
        _debounce.Tick += (_, _) => _ = CheckUsername();
        Unloaded += (_, _) => _debounce.Stop();
        Loaded += (_, _) =>
        {
            if (_check == Check.Checking) _debounce.Start(); // Loaded can come twice
            Keyboard.Focus(Username);
        };
        Show();
    }

    /// <summary>The field you're typing in gets a 2px ink underline; otherwise a hairline (or none). Returns the way back to rest.</summary>
    private static Action Underline(Control field, System.Windows.Shapes.Rectangle line, Func<string?> rest)
    {
        void Rest()
        {
            if (field.IsKeyboardFocused) return;
            line.Height = 1;
            if (rest() is { } key) line.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, key);
            else line.Fill = System.Windows.Media.Brushes.Transparent;
        }
        field.GotKeyboardFocus += (_, _) => { line.Height = 2; line.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Ink"); };
        field.LostKeyboardFocus += (_, _) => Rest();
        Rest();
        return Rest;
    }

    private static Visibility HintFor(string text) => text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void Show()
    {
        Heading.Text = _creating ? "make an account" : "sign in";
        SwitchMode.Content = _creating ? "have an account?" : "new here?";
        Primary.Content = _creating ? "create account" : "sign in";
        ConfirmRow.Visibility = _creating ? Visibility.Visible : Visibility.Collapsed;
        foreach (var rest in _rest) rest();
        OnUsername();
        ShowPasswords();
    }

    // The username, lowercased as you type, and checked on the create form.

    private void OnUsername()
    {
        var tidy = SupabaseApi.TidyUsername(Username.Text);
        if (tidy != Username.Text)
        {
            Username.Text = tidy; // comes back through here
            Username.CaretIndex = tidy.Length;
            return;
        }
        UsernameHint.Visibility = HintFor(tidy);
        _checking?.Cancel();
        _debounce.Stop();
        if (!_creating || tidy.Length == 0) ShowCheck(Check.None);
        else if (!SupabaseApi.IsUsername(tidy)) ShowCheck(Check.Rule);
        else
        {
            ShowCheck(Check.Checking);
            _debounce.Start();
        }
    }

    /// <summary>300ms after the last keystroke: one call, dropped if the name changes meanwhile.</summary>
    private async Task CheckUsername()
    {
        _debounce.Stop();
        var cts = new CancellationTokenSource();
        _checking = cts;
        try
        {
            var free = await _sync.UsernameAvailable(Username.Text, cts.Token);
            if (cts.IsCancellationRequested) return;
            ShowCheck(free ? Check.Available : Check.Taken);
        }
        catch (Exception) when (!cts.IsCancellationRequested)
        {
            ShowCheck(Check.Unknown);
        }
        catch (Exception) { }
    }

    private void ShowCheck(Check check)
    {
        _check = check;
        UsernameMark.Status = check switch
        {
            Check.Checking => StatusMark.Kind.Working,
            Check.Available => StatusMark.Kind.Done,
            Check.Taken or Check.Rule => StatusMark.Kind.Failed,
            _ => StatusMark.Kind.None,
        };
        // The cross alone says it on screen; the words are for hover and screen readers.
        string? problem = check switch
        {
            Check.Rule => "3–20 letters, digits or _",
            Check.Taken => "taken",
            Check.Unknown => "can't check right now.",
            _ => null,
        };
        UsernameMark.ToolTip = problem;
        AutomationProperties.SetHelpText(Username, problem ?? "");
        ShowReady();
    }

    // The passwords, marked on the create form: empty is no mark.

    private void ShowPasswords()
    {
        var password = Password.Password;
        var confirm = Confirm.Password;
        Mark(Password, PasswordMark, _creating && password.Length > 0, SupabaseApi.IsPassword(password), "6+ characters");
        Mark(Confirm, ConfirmMark, _creating && confirm.Length > 0, SupabaseApi.IsConfirmed(password, confirm), "doesn't match");
        ShowReady();
    }

    /// <summary>A tick or a cross; the cross's words are for hover and screen readers.</summary>
    private static void Mark(Control field, StatusMark mark, bool shown, bool good, string problem)
    {
        mark.Status = !shown ? StatusMark.Kind.None : good ? StatusMark.Kind.Done : StatusMark.Kind.Failed;
        var text = shown && !good ? problem : null;
        mark.ToolTip = text;
        AutomationProperties.SetHelpText(field, text ?? "");
    }

    private static void Note(TextBlock note, string text)
    {
        note.Text = text;
        note.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private bool Ready => _creating
        ? _check == Check.Available && SupabaseApi.IsConfirmed(Password.Password, Confirm.Password)
        : Username.Text.Length > 0 && Password.Password.Length > 0;

    private void ShowReady() => Primary.IsEnabled = Ready && !_working;

    private void SetProblem(string? text) => Note(Problem, text ?? "");

    /// <summary>Runs one call at a time, and shows what went wrong.</summary>
    private async Task Run(Func<Task> work)
    {
        if (_working) return;
        _working = true;
        SetProblem(null);
        ShowReady();
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
        ShowReady();
    }

    private async void OnSubmit(object sender, RoutedEventArgs e)
    {
        if (!Ready) return;
        await Run(async () =>
        {
            if (_creating) await _sync.CreateAccount(Username.Text, Password.Password, Stay.IsOn);
            else await _sync.SignIn(Username.Text, Password.Password, Stay.IsOn);
            _done();
        });
    }

    private void OnSwitch(object sender, RoutedEventArgs e)
    {
        _creating = !_creating;
        SetProblem(null);
        Show();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => _cancel?.Invoke();

    /// <summary>For --render: the create form with a name already checked, without asking a server; available also shows a good password and a confirm that doesn't match.</summary>
    internal void Pretend(string username, bool available)
    {
        _creating = true;
        Username.Text = username;
        if (available)
        {
            Password.Password = "kasane-0401";
            Confirm.Password = "kasane-04";
        }
        Show();
        _debounce.Stop();
        _checking?.Cancel();
        ShowCheck(available ? Check.Available : Check.Taken);
    }
}
