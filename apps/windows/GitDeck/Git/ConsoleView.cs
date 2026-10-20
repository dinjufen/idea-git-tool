using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Git;

/// Git 工具窗口的 Console 标签（与 mac 端 ConsoleView 一致）：显示本项目执行过的 git 命令、退出码、耗时与错误输出。
public sealed class ConsoleView : Grid
{
    private const int MaxEntries = 2000;

    private readonly string _root;
    private readonly RichTextBlock _text = new()
    {
        IsTextSelectionEnabled = true,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        FontSize = 12,
        Margin = new Thickness(8, 6, 8, 6),
    };
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly CheckBox _showBackground = new() { Content = L10n.Tr("console.showBackground"), MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
    // 编辑器组件加载后 DispatcherQueueTimer 会停止触发（WinUIEdit 的问题），这里用 XAML 的 DispatcherTimer。
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    /// 已拉取的记录（含隐藏的后台命令），切换显示选项时据此重绘。
    private readonly List<ConsoleEntry> _entries = [];
    private ulong _lastId;

    public ConsoleView(string root)
    {
        _root = root;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var clear = new IconButton(Icon.Trash, L10n.Tr("console.clear"), 26, 13);
        clear.Click += (_, _) =>
        {
            _entries.Clear();
            _text.Blocks.Clear();
        };
        _showBackground.Click += (_, _) => Render();
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(6, 2, 8, 2), Children = { clear, _showBackground } });
        _scroll.Content = _text;
        Themed.Background(_scroll, "EditorBackgroundBrush");
        SetRow(_scroll, 1);
        Children.Add(_scroll);

        _timer.Tick += (_, _) => Poll();
        // 标签可见时每秒拉取一次新记录，隐藏时停止。
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => UpdatePolling());
        Loaded += (_, _) => UpdatePolling();
        Unloaded += (_, _) => _timer.Stop();
        ActualThemeChanged += (_, _) => Render();
    }

    /// 仅调试：显示后台命令。
    public void ShowBackgroundCommands()
    {
        _showBackground.IsChecked = true;
        Render();
    }

    private void UpdatePolling()
    {
        if (Visibility == Visibility.Visible)
        {
            Poll();
            _timer.Start();
        }
        else
        {
            _timer.Stop();
        }
    }

    private void Poll()
    {
        var entries = CoreApi.ConsoleEntries(_lastId);
        if (entries.Length == 0) return;
        _lastId = entries[^1].Id;
        // 进程内所有仓库共用一个记录，只显示本项目的。
        var mine = entries.Where(e => SamePath(e.Cwd, _root)).ToList();
        if (mine.Count == 0) return;
        _entries.AddRange(mine);
        if (_entries.Count > MaxEntries) _entries.RemoveRange(0, _entries.Count - MaxEntries);
        Append(mine);
    }

    private static bool SamePath(string a, string b) =>
        string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)), StringComparison.OrdinalIgnoreCase);

    private void Render()
    {
        _text.Blocks.Clear();
        Append(_entries);
    }

    private void Append(IEnumerable<ConsoleEntry> list)
    {
        var includeBackground = _showBackground.IsChecked == true;
        var secondary = Icons.ThemeBrush(this, "SecondaryTextBrush");
        var primary = Icons.ThemeBrush(this, "PrimaryTextBrush");
        var error = Icons.ThemeBrush(this, "StatusConflictBrush");
        var atBottom = _scroll.VerticalOffset >= _scroll.ScrollableHeight - 4;
        var added = false;
        foreach (var entry in list)
        {
            if (!includeBackground && entry.Background && entry.ExitCode == 0) continue;
            var failed = entry.ExitCode != 0;
            var paragraph = new Paragraph();
            var time = DateTimeOffset.FromUnixTimeMilliseconds(entry.TimeMs).LocalDateTime.ToString("HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
            paragraph.Inlines.Add(new Run { Text = time + "  ", Foreground = secondary });
            paragraph.Inlines.Add(new Run { Text = entry.Command, Foreground = failed ? error : entry.Background ? secondary : primary });
            paragraph.Inlines.Add(new Run { Text = failed ? $"  (exit {entry.ExitCode}, {entry.DurationMs} ms)" : $"  ({entry.DurationMs} ms)", Foreground = secondary });
            if (entry.Output.Length > 0)
            {
                var indented = string.Join("\n", entry.Output.TrimEnd('\n').Split('\n').Select(line => "          " + line.TrimEnd('\r')));
                paragraph.Inlines.Add(new LineBreak());
                paragraph.Inlines.Add(new Run { Text = indented, Foreground = secondary });
            }
            _text.Blocks.Add(paragraph);
            added = true;
        }
        if (added && atBottom) DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _scroll.ChangeView(null, _scroll.ScrollableHeight, null, true));
    }
}
