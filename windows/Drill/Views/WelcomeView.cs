using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Drill.Ink;

namespace Drill.Views;

/// <summary>
/// Whenever nobody's signed in: drill, a line, and the account form (signing
/// in by default). The main window shows it in place of the timer.
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

        var form = new AccountForm(shell.Sync, done: () => shell.Model.Welcoming = false, cancel: null, heading: false);

        var stack = new StackPanel { Width = 392, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(title);
        stack.Children.Add(line);
        stack.Children.Add(form);
        Content = stack;
    }
}
