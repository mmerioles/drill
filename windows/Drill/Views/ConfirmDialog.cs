using System.Windows;
using System.Windows.Controls;
using Drill.Ink;

namespace Drill.Views;

/// <summary>A question with one way forward and a cancel. Closing it any other way counts as cancel.</summary>
public sealed class ConfirmDialog : UserControl
{
    public ConfirmDialog(string question, string action, Action<bool> answered)
    {
        var text = new TextBlock { Text = question, FontSize = 15, TextWrapping = TextWrapping.Wrap };
        text.SetResourceReference(StyleProperty, "Base");

        var go = new Capsule { Content = action, FontSize = 15, Height = 40, Padding = new Thickness(32, 0, 32, 0), IsDefault = true };
        go.Click += (_, _) => answered(true);
        var cancel = new InkLink { Content = "cancel", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0), IsCancel = true };
        cancel.Click += (_, _) => answered(false);
        DockPanel.SetDock(go, Dock.Right);
        DockPanel.SetDock(cancel, Dock.Right);
        var buttons = new DockPanel { Margin = new Thickness(0, 24, 0, 0) };
        buttons.Children.Add(go);
        buttons.Children.Add(cancel);
        buttons.Children.Add(new Border());

        var stack = new StackPanel();
        stack.Children.Add(text);
        stack.Children.Add(buttons);
        Content = stack;
        Unloaded += (_, _) => answered(false);
        Loaded += (_, _) => go.Focus();
    }
}
