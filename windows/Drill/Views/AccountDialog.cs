using System.Windows.Controls;
using Drill.Services;

namespace Drill.Views;

/// <summary>The account form as a dialog over a window: signs in from "sign in", starting on that form.</summary>
public sealed class AccountDialog : UserControl
{
    private readonly AccountForm _form;

    public AccountDialog(Sync sync, Action dismiss)
    {
        _form = new AccountForm(sync, done: dismiss, cancel: dismiss);
        Content = _form;
    }

    /// <summary>For --render: the create form with a name already checked, without asking a server.</summary>
    internal void Pretend(string username, bool available) => _form.Pretend(username, available);
}
