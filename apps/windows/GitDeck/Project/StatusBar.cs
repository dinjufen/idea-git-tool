using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Project;

/// 底部状态栏：左侧为消息与进度，右侧为编辑器信息（行列、换行符、编码）。
public sealed class StatusBar : Grid
{
    public const double BarHeight = 26;

    private readonly TextBlock _message = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _editorInfo = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _spinner = new() { Width = 12, Height = 12, IsActive = false, Visibility = Visibility.Collapsed };
    private bool _isError;

    public StatusBar()
    {
        Height = BarHeight;
        Themed.Background(this, "ToolWindowBackgroundBrush");
        var top = Themed.Background(new Border { Height = 1, VerticalAlignment = VerticalAlignment.Top }, "SeparatorBrush");
        _message.FontSize = 12;
        _editorInfo.FontSize = 12;
        Themed.Brush(_message, "SecondaryTextBrush", (t, b) => t.Foreground = _isError ? Icons.ThemeBrush(t, "ErrorTextBrush") : b);
        Themed.Foreground(_editorInfo, "SecondaryTextBrush");

        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 0, 12, 0), Children = { _message, _spinner } };
        _editorInfo.Margin = new Thickness(12, 0, 12, 0);
        SetColumn(_editorInfo, 1);
        SetColumnSpan(top, 2);
        Children.Add(top);
        Children.Add(left);
        Children.Add(_editorInfo);
    }

    public void SetMessage(string text, bool isError = false)
    {
        _isError = isError;
        _message.Text = text;
        _message.Foreground = Icons.ThemeBrush(_message, isError ? "ErrorTextBrush" : "SecondaryTextBrush");
        ToolTipService.SetToolTip(_message, string.IsNullOrEmpty(text) ? null : text);
    }

    public void SetBusy(bool busy)
    {
        _spinner.IsActive = busy;
        _spinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }

    public void SetEditorInfo(string text) => _editorInfo.Text = text;
}
