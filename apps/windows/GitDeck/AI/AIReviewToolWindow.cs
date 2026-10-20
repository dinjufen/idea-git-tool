using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Editor;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace GitDeck.AI;

/// 右侧的 AI Review 工具窗口（与 mac 端 AIReviewToolWindow 一致）：评审进度（可取消）、总结、按文件分组的发现
/// （严重程度、位置），选中发现查看说明，双击跳转到源码，可预览并应用修改建议。
public sealed class AIReviewToolWindow : Grid
{
    private readonly AIReviewController _controller;
    private readonly SimpleTree _tree = new(ListViewSelectionMode.Single, "");
    private readonly RichTextBlock _detail = new() { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 8, 10, 8) };
    private readonly ScrollViewer _detailScroll = new();
    private readonly TextBlock _status = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _spinner = new() { Width = 14, Height = 14, IsActive = false, Visibility = Visibility.Collapsed };
    private readonly Grid _results = new();
    private readonly StackPanel _empty = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _open = new() { Content = L10n.Tr("ai.finding.open") };
    private readonly Button _apply = new() { Content = L10n.Tr("ai.finding.apply") };
    private readonly IconButton _rerun = new(Icon.Refresh, L10n.Tr("ai.action.rerun"), 26, 13);
    private readonly IconButton _stop = new(Icon.Stop, L10n.Tr("ai.action.stop"), 26, 13);
    private readonly IconButton _clear = new(Icon.Trash, L10n.Tr("ai.action.clear"), 26, 13);
    private ReviewResult? _shownResult;
    private int _shownApplied;

    public AIReviewToolWindow(AIReviewController controller)
    {
        _controller = controller;
        BuildLayout();
        _controller.Changed += Update;
        ActualThemeChanged += (_, _) => Update();
        Update();
    }

    /// 双击发现：跳转到位置（参数为发现下标）。
    public event Action<int>? OpenFinding;

    /// 应用修改建议（参数为发现下标）。
    public event Action<int>? ApplySuggestion;

    /// 评审本地改动（工具栏与空状态中的按钮）。
    public event Action? ReviewLocalChanges;

    private void BuildLayout()
    {
        Themed.Background(this, "ToolWindowBackgroundBrush");
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var review = new IconButton(Icon.Sparkles, L10n.Tr("ai.action.reviewLocal"), 26, 13);
        review.Click += (_, _) => ReviewLocalChanges?.Invoke();
        _rerun.Click += (_, _) => _ = _controller.Rerun();
        _stop.Click += (_, _) => _controller.Cancel();
        _clear.Click += (_, _) => _controller.Clear();
        var settings = new IconButton(Icon.Gear, L10n.Tr("ai.action.settings"), 26, 13);
        settings.Click += (_, _) => SettingsWindow.Show(SettingsWindow.Page.AI);
        var header = new Grid { Margin = new Thickness(12, 0, 6, 0) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = L10n.Tr("toolwindow.aiReview"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        }, "PrimaryTextBrush"));
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { review, _rerun, _stop, _clear, settings } };
        SetColumn(toolbar, 1);
        header.Children.Add(toolbar);
        Children.Add(header);

        _status.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 0, 10, 4), Children = { _spinner, _status } };
        SetRow(status, 1);
        Children.Add(status);

        // 发现列表与说明：上下分栏，说明区可拖动调整高度。
        _results.RowDefinitions.Add(new RowDefinition { Height = new GridLength(55, GridUnitType.Star), MinHeight = 80 });
        _results.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _results.RowDefinitions.Add(new RowDefinition { Height = new GridLength(45, GridUnitType.Star), MinHeight = 80 });
        _results.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _tree.SelectionChanged += UpdateDetail;
        _tree.Invoked += node =>
        {
            if (node.Tag is int index) OpenFinding?.Invoke(index);
        };
        _results.Children.Add(_tree);
        var splitter = new Splitter(vertical: false);
        splitter.Dragged += delta =>
        {
            var top = _results.RowDefinitions[0];
            var bottom = _results.RowDefinitions[2];
            var total = top.ActualHeight + bottom.ActualHeight;
            var newTop = Math.Clamp(top.ActualHeight + delta, 80, Math.Max(80, total - 80));
            top.Height = new GridLength(newTop, GridUnitType.Star);
            bottom.Height = new GridLength(total - newTop, GridUnitType.Star);
        };
        SetRow(splitter, 1);
        _results.Children.Add(splitter);
        _detailScroll.Content = _detail;
        Themed.Background(_detailScroll, "EditorBackgroundBrush");
        SetRow(_detailScroll, 2);
        _results.Children.Add(_detailScroll);
        _open.Click += (_, _) =>
        {
            if (SelectedIndex is { } index) OpenFinding?.Invoke(index);
        };
        _apply.Click += (_, _) =>
        {
            if (SelectedIndex is { } index) ApplySuggestion?.Invoke(index);
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(10, 6, 10, 8), Children = { _open, _apply } };
        SetRow(buttons, 3);
        _results.Children.Add(buttons);
        SetRow(_results, 2);
        Children.Add(_results);

        var emptyText = new TextBlock
        {
            Text = L10n.Tr("ai.empty"),
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            MaxWidth = 260,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
        };
        var emptyButton = new Button { Content = L10n.Tr("ai.action.reviewLocal"), HorizontalAlignment = HorizontalAlignment.Center };
        emptyButton.Click += (_, _) => ReviewLocalChanges?.Invoke();
        _empty.Children.Add(emptyText);
        _empty.Children.Add(emptyButton);
        SetRow(_empty, 2);
        Children.Add(_empty);
    }

    private int? SelectedIndex => _tree.SelectedNodes.FirstOrDefault()?.Tag as int?;

    // MARK: - 状态

    private void Update()
    {
        var phase = _controller.State;
        var running = phase == AIReviewController.Phase.Running;
        _empty.Visibility = phase == AIReviewController.Phase.Idle ? Visibility.Visible : Visibility.Collapsed;
        _results.Visibility = phase == AIReviewController.Phase.Idle ? Visibility.Collapsed : Visibility.Visible;
        _spinner.IsActive = running;
        _spinner.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        _rerun.IsEnabled = _controller.CanRerun;
        _stop.IsEnabled = running;
        _clear.IsEnabled = !running && phase != AIReviewController.Phase.Idle;
        _status.Text = StatusText();
        ToolTipService.SetToolTip(_status, _status.Text);
        Themed.Foreground(_status, phase == AIReviewController.Phase.Failed ? "StatusConflictBrush" : "SecondaryTextBrush");
        // 结果变化或应用了建议（已应用的发现显示为灰色）时重建列表。
        if (!ReferenceEquals(_controller.Result, _shownResult) || _controller.Applied.Count != _shownApplied)
        {
            var selected = SelectedIndex;
            _shownResult = _controller.Result;
            _shownApplied = _controller.Applied.Count;
            RebuildTree();
            if (selected is { } index) Select(index);
        }
        UpdateDetail();
    }

    private string StatusText()
    {
        var tokens = _controller.Usage.Input + _controller.Usage.Output;
        var usage = tokens > 0 ? " · " + L10n.Tr("ai.status.tokens", tokens >= 1000 ? $"{tokens / 1000.0:0.0}k" : tokens.ToString(System.Globalization.CultureInfo.InvariantCulture)) : "";
        return _controller.State switch
        {
            AIReviewController.Phase.Running => L10n.Tr("ai.status.running", _controller.Title)
                                                + (_controller.Turn > 0 ? " · " + L10n.Tr("ai.status.turn", _controller.Turn) : "") + usage,
            AIReviewController.Phase.Finished => _controller.Title + " · "
                                                 + (_controller.Result?.Findings.Length is > 0 and var count ? L10n.Tr("ai.done.some", count) : L10n.Tr("ai.done.none")) + usage,
            AIReviewController.Phase.Failed => L10n.Tr("ai.failed") + ": " + (_controller.ErrorText ?? ""),
            AIReviewController.Phase.Cancelled => _controller.Title + " · " + L10n.Tr("ai.status.cancelled"),
            _ => "",
        };
    }

    private void RebuildTree()
    {
        var dark = ActualTheme == ElementTheme.Dark;
        var roots = new List<SimpleTree.Node>();
        var findings = _controller.Result?.Findings ?? [];
        foreach (var group in findings.Select((f, i) => (Finding: f, Index: i)).GroupBy(x => x.Finding.File))
        {
            var directory = Path.GetDirectoryName(group.Key)?.Replace('\\', '/') ?? "";
            var count = group.Count().ToString(System.Globalization.CultureInfo.InvariantCulture);
            var file = new SimpleTree.Node(group.Key, Icon.File, Path.GetFileName(group.Key), directory.Length == 0 ? count : $"{directory}  {count}")
            {
                CanExpand = true,
                IsExpanded = true,
                Tooltip = group.Key,
            };
            file.SetChildren(group.Select(x => new SimpleTree.Node(x.Index, SeverityIcon(x.Finding.Severity), x.Finding.Title, $":{x.Finding.Line}")
            {
                IconColor = SeverityColor(x.Finding.Severity, dark),
                NameBrushKey = _controller.Applied.Contains(x.Index) ? "SecondaryTextBrush" : "PrimaryTextBrush",
                Tooltip = x.Finding.Title,
            }));
            roots.Add(file);
        }
        _tree.SetRoots(roots, node => node.Tag.ToString() ?? "");
    }

    /// 选中某个发现（例如点击编辑器中的标记）。
    public void Select(int findingIndex)
    {
        foreach (var root in _tree.Roots)
        {
            if (root.Children?.FirstOrDefault(c => c.Tag is int i && i == findingIndex) is not { } node) continue;
            if (!root.IsExpanded) _tree.Toggle(root);
            _tree.SelectNode(node);
            return;
        }
    }

    private void UpdateDetail()
    {
        _detail.Blocks.Clear();
        var primary = Icons.ThemeBrush(this, "PrimaryTextBrush");
        var secondary = Icons.ThemeBrush(this, "SecondaryTextBrush");
        Paragraph Add(string text, Brush brush, bool bold = false, bool mono = false, double? size = null)
        {
            var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 8) };
            var run = new Run { Text = text, Foreground = brush };
            if (bold) run.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            if (mono) run.FontFamily = new FontFamily(EditorSettings.EffectiveFamily);
            if (size is { } s) run.FontSize = s;
            paragraph.Inlines.Add(run);
            _detail.Blocks.Add(paragraph);
            return paragraph;
        }
        if (SelectedIndex is { } index && _controller.Result is { } result && index < result.Findings.Length)
        {
            var f = result.Findings[index];
            Add(f.Title, primary, bold: true);
            var location = f.EndLine > f.Line ? $"{f.File}:{f.Line}-{f.EndLine}" : $"{f.File}:{f.Line}";
            Add(SeverityTitle(f.Severity) + " · " + location, secondary, size: 12);
            Add(f.Explanation, primary);
            if (f.Suggestion is { } suggestion)
            {
                Add(L10n.Tr("ai.finding.suggestion"), secondary, size: 12);
                Add(suggestion.Replacement, primary, mono: true);
            }
            var applied = _controller.Applied.Contains(index);
            _open.IsEnabled = true;
            _apply.IsEnabled = f.Suggestion is not null && !applied && _controller.IsWorkingTreeResult(f.File);
            _apply.Content = applied ? L10n.Tr("ai.finding.applied") : L10n.Tr("ai.finding.apply");
            return;
        }
        if (_controller.Result is { } finished)
        {
            if (finished.Summary.Length > 0) Add(finished.Summary, primary);
            else if (finished.Findings.Length == 0 && _controller.Files.Length == 0) Add(L10n.Tr("ai.nothingToReview"), primary);
            if (finished.Incomplete) Add(L10n.Tr("ai.incomplete"), secondary, size: 12);
        }
        foreach (var activity in _controller.Activities) Add("•  " + activity, secondary, size: 12);
        var narration = _controller.Narration.Trim();
        if (narration.Length > 0) Add(narration, primary);
        if (_controller.State == AIReviewController.Phase.Finished && _controller.ModelName.Length > 0)
        {
            Add(L10n.Tr("ai.reviewedBy", _controller.ModelName), secondary, size: 12);
        }
        _open.IsEnabled = false;
        _apply.IsEnabled = false;
        _apply.Content = L10n.Tr("ai.finding.apply");
        if (_controller.IsRunning) DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _detailScroll.ChangeView(null, _detailScroll.ScrollableHeight, null, true));
    }

    public static string SeverityTitle(ReviewSeverity severity) => severity switch
    {
        ReviewSeverity.Error => L10n.Tr("ai.severity.error"),
        ReviewSeverity.Warning => L10n.Tr("ai.severity.warning"),
        _ => L10n.Tr("ai.severity.suggestion"),
    };

    public static Icon SeverityIcon(ReviewSeverity severity) => severity switch
    {
        ReviewSeverity.Error => Icon.SeverityError,
        ReviewSeverity.Warning => Icon.SeverityWarning,
        _ => Icon.SeveritySuggestion,
    };

    /// 评审发现的严重程度颜色（对应 IDEA 的 Error / Warning / Weak Warning）。
    public static Color SeverityColor(ReviewSeverity severity, bool dark) => SyntaxTheme.Rgb(severity switch
    {
        ReviewSeverity.Error => dark ? 0xE55765u : 0xDB3B4Bu,
        ReviewSeverity.Warning => dark ? 0xF2C55Cu : 0xE08855u,
        _ => dark ? 0x548AF7u : 0x3574F0u,
    });
}
