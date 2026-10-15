using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Drill.Ink;

namespace Drill.Views;

/// <summary>
/// First launch, and just after signing out: drill, a line, the account form
/// (making one by default), and a way to go on without one. The main window
/// shows it in place of the timer.
/// </summary>
public sealed class WelcomeView : UserControl
{
    public WelcomeView(Shell shell)
    {
        var title = new TextBlock { Text = "drill", FontSize = 34, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
        title.SetResourceReference(StyleProperty, "Base");
        title.SetResourceReference(TextBlock.FontFamilyProperty, "Display");
        TextOptions.SetTextFormattingMode(title, TextFormattingMode.Ideal);
        var line = new TextBlock { Text = "a quiet pomodoro timer", FontSize = 15, Opacity = InkLink.Rest, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 16) };
        line.SetResourceReference(StyleProperty, "Base");

        var form = new AccountForm(shell.Sync, done: () => shell.Model.Welcoming = false, cancel: null, creating: true, heading: false);

        var offline = new InkLink { Content = "continue offline", FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 28, 0, 0) };
        offline.Click += (_, _) =>
        {
            shell.Model.Welcomed = true;
            shell.Model.Welcoming = false;
        };

        var stack = new StackPanel { Width = 392, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(title);
        stack.Children.Add(line);
        stack.Children.Add(form);
        stack.Children.Add(offline);
        Content = stack;
    }
}
