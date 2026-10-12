using System.Windows;
using System.Windows.Input;
using TmuxHub.Windows.Services;

namespace TmuxHub.Windows.Views;

public partial class PromptDialog : Window
{
    public PromptDialog(
        Window owner,
        string title,
        string prompt,
        string initialValue = "",
        string help = "")
    {
        InitializeComponent();
        SourceInitialized += (_, _) => DwmTitleBar.Apply(this);
        Owner = owner;
        Title = title;
        PromptText.Text = prompt;
        HelpText.Text = help;
        ValueBox.Text = initialValue;
        Loaded += (_, _) =>
        {
            ValueBox.Focus();
            ValueBox.SelectAll();
        };
    }

    public string Value => ValueBox.Text.Trim();

    private void ConfirmButton_OnClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void ValueBox_OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter)
        {
            return;
        }

        DialogResult = true;
        e.Handled = true;
    }
}
