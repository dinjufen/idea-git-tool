using GitDeck.Common;
using GitDeck.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace GitDeck.Editor;

/// 编辑器顶部的查找栏（IDEA / VSCode 的 Ctrl+F）：输入即搜索，Enter 下一个，Shift+Enter 上一个，Esc 关闭。
/// 替换模式（Ctrl+R）多一行替换输入框与 “替换 / 全部替换” 按钮（与 mac 端 FindBar 一致）。
public sealed class FindBar : Grid
{
    private readonly TextBox _query = new() { PlaceholderText = L10n.Tr("find.placeholder"), Width = 260 };
    private readonly TextBox _replacement = new() { PlaceholderText = L10n.Tr("find.replace.placeholder"), Width = 260 };
    private readonly CheckBox _matchCase = new() { Content = L10n.Tr("find.matchCase"), MinWidth = 0, FontSize = 12 };
    private readonly TextBlock _count = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, MinWidth = 60 };
    private readonly StackPanel _replaceRow = new() { Orientation = Orientation.Horizontal, Spacing = 6, Visibility = Visibility.Collapsed, Margin = new Thickness(8, 0, 8, 6) };
    private bool _countIsError;

    public event Action? QueryChanged;

    public event Action? Next;

    public event Action? Previous;

    public event Action? Closed;

    public event Action<string>? Replace;

    public event Action<string>? ReplaceAll;

    public FindBar()
    {
        Themed.Background(this, "ToolWindowBackgroundBrush");
        Themed.Brush(_count, "SecondaryTextBrush", (t, b) => t.Foreground = _countIsError ? Icons.ThemeBrush(t, "ErrorTextBrush") : b);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var previous = new IconButton(Icon.ChevronUp, L10n.Tr("find.previous"), 24, 12);
        previous.Click += (_, _) => Previous?.Invoke();
        var next = new IconButton(Icon.ChevronDown, L10n.Tr("find.next"), 24, 12);
        next.Click += (_, _) => Next?.Invoke();
        var close = new IconButton(Icon.Close, L10n.Tr("find.close"), 24, 12) { HorizontalAlignment = HorizontalAlignment.Right };
        close.Click += (_, _) => Closed?.Invoke();
        _matchCase.Checked += (_, _) => QueryChanged?.Invoke();
        _matchCase.Unchecked += (_, _) => QueryChanged?.Invoke();

        var row = new Grid { Margin = new Thickness(8, 5, 8, 5) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _query, _count, previous, next, _matchCase } });
        SetColumn(close, 1);
        row.Children.Add(close);
        Children.Add(row);

        var replaceButton = new Button { Content = L10n.Tr("find.replace") };
        replaceButton.Click += (_, _) => Replace?.Invoke(_replacement.Text);
        var replaceAllButton = new Button { Content = L10n.Tr("find.replaceAll") };
        replaceAllButton.Click += (_, _) => ReplaceAll?.Invoke(_replacement.Text);
        _replaceRow.Children.Add(_replacement);
        _replaceRow.Children.Add(replaceButton);
        _replaceRow.Children.Add(replaceAllButton);
        SetRow(_replaceRow, 1);
        Children.Add(_replaceRow);

        var bottom = Themed.Background(new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom }, "SeparatorBrush");
        SetRowSpan(bottom, 2);
        Children.Add(bottom);

        _query.TextChanged += (_, _) => QueryChanged?.Invoke();
        _query.KeyDown += OnQueryKey;
        _replacement.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                Replace?.Invoke(_replacement.Text);
                e.Handled = true;
            }
            else if (e.Key == VirtualKey.Escape)
            {
                Closed?.Invoke();
                e.Handled = true;
            }
        };
    }

    public string Query => _query.Text;

    public bool MatchCase => _matchCase.IsChecked == true;

    /// 显示替换行。
    public bool IsReplaceMode
    {
        get => _replaceRow.Visibility == Visibility.Visible;
        set => _replaceRow.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    public void FocusQuery(string? initial)
    {
        if (!string.IsNullOrEmpty(initial)) _query.Text = initial;
        _query.Focus(FocusState.Programmatic);
        _query.SelectAll();
        QueryChanged?.Invoke();
    }

    public void SetResultText(string text)
    {
        _countIsError = false;
        _count.Text = text;
        _count.Foreground = Icons.ThemeBrush(_count, "SecondaryTextBrush");
    }

    public void SetResult(int? current, int total)
    {
        _countIsError = Query.Length > 0 && total == 0;
        _count.Text = Query.Length == 0 ? "" : total == 0 ? L10n.Tr("find.noMatches") : L10n.Tr("find.count", (current ?? 0) + 1, total);
        _count.Foreground = Icons.ThemeBrush(_count, _countIsError ? "ErrorTextBrush" : "SecondaryTextBrush");
    }

    private void OnQueryKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                    .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                (shift ? Previous : Next)?.Invoke();
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                Closed?.Invoke();
                e.Handled = true;
                break;
        }
    }
}
