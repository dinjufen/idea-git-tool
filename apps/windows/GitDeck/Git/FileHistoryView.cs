using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Diff;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Git;

/// 文件历史（IDEA 的 “Show History”，与 mac 端 FileHistoryView 一致）：
/// 左侧为该文件的修订列表（跟踪重命名），右侧为所选修订相对父提交的 Diff。
public sealed class FileHistoryView : Grid
{
    private const double RowHeight = 24;

    private readonly ProjectModel _model;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly Grid _preview = new();
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center };
    private FileRevision[] _revisions = [];
    private int _previewToken;

    public FileHistoryView(ProjectModel model, string path)
    {
        _model = model;
        Path = path;
        BuildLayout();
        Load();
    }

    /// 在编辑器中打开某个修订的完整 Diff：提交哈希、第一个父提交、文件。
    public event Action<string, string?, ChangedFile>? OpenDiff;

    public string Path { get; }

    private void BuildLayout()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(560), MinWidth = 480 });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 300 });

        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(10, 6, 10, 6) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = Path,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(0, 0, 8, 0),
        }, "PrimaryTextBrush"));
        _status.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        SetColumn(_status, 1);
        header.Children.Add(_status);
        left.Children.Add(header);

        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, RowHeight));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, RowHeight));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = style;
        _list.ContainerContentChanging += (_, args) =>
        {
            if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not FileRevision revision) return;
            if (root.Children.Count == 0) root.Children.Add(new RevisionRow());
            ((RevisionRow)root.Children[0]).Bind(revision);
            args.Handled = true;
        };
        _list.SelectionChanged += (_, _) => ShowPreview();
        _list.DoubleTapped += (_, _) =>
        {
            if (_list.SelectedItem is FileRevision revision)
            {
                OpenDiff?.Invoke(revision.Hash, revision.Parents.FirstOrDefault(), new ChangedFile(revision.Path, revision.OrigPath, revision.Kind));
            }
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_list, L10n.Tr("history.accessibility", Path));
        Themed.Background(_list, "EditorBackgroundBrush");
        SetRow(_list, 1);
        left.Children.Add(_list);
        Children.Add(left);

        var splitter = new Splitter(vertical: true);
        splitter.Dragged += delta =>
        {
            var column = ColumnDefinitions[0];
            column.Width = new GridLength(Math.Clamp(column.ActualWidth + delta, 480, Math.Max(480, ActualWidth - 300)));
        };
        SetColumn(splitter, 1);
        Children.Add(splitter);
        SetColumn(_preview, 2);
        Children.Add(_preview);
    }

    public void Load()
    {
        _status.Text = L10n.Tr("log.loading");
        var repository = _model.Repository;
        var path = Path;
        Task.Run(() => repository.FileHistory(path, 0)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (task.Exception?.InnerException is { } error)
            {
                _status.Text = L10n.Message(error);
                return;
            }
            _revisions = task.Result;
            _list.ItemsSource = _revisions;
            _status.Text = _revisions.Length == 1 ? L10n.Tr("history.count.one") : L10n.Tr("history.count", _revisions.Length);
            if (_revisions.Length > 0) _list.SelectedIndex = 0;
        }), TaskScheduler.Default);
    }

    /// 在右侧显示所选修订相对第一个父提交的 Diff。
    private void ShowPreview()
    {
        var token = ++_previewToken;
        _preview.Children.Clear();
        if (_list.SelectedItem is not FileRevision revision) return;
        var repository = _model.Repository;
        var basePath = revision.OrigPath ?? revision.Path;
        var parent = revision.Parents.FirstOrDefault();
        Task.Run(() =>
        {
            var baseText = revision.Kind == ChangeKind.Added || parent is null ? null : TryRead(() => repository.FileAtRevision(parent, basePath));
            var text = revision.Kind == ChangeKind.Deleted ? null : TryRead(() => repository.FileAtRevision(revision.Hash, revision.Path));
            return (baseText, text);
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _previewToken) return;
            var (baseText, text) = task.Result;
            _preview.Children.Add(new DiffView(
                new DiffSide(parent is null ? L10n.Tr("diff.title.empty") : parent[..Math.Min(8, parent.Length)], baseText),
                new DiffSide(revision.Hash[..Math.Min(8, revision.Hash.Length)], text),
                revision.Path));
        }), TaskScheduler.Default);
    }

    private static string? TryRead(Func<string?> read)
    {
        try
        {
            return read();
        }
        catch (CoreException)
        {
            return null;
        }
    }

    /// 一行：修订、日期、作者、提交信息（列顺序与 IDEA 文件历史一致）。
    private sealed class RevisionRow : Grid
    {
        private readonly TextBlock _hash = Cell();
        private readonly TextBlock _date = Cell();
        private readonly TextBlock _author = Cell();
        private readonly TextBlock _subject = Cell();

        public RevisionRow()
        {
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _hash.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            foreach (var cell in new[] { _hash, _date, _author }) Themed.Foreground(cell, "SecondaryTextBrush");
            Themed.Foreground(_subject, "PrimaryTextBrush");
            var column = 0;
            foreach (var cell in new[] { _hash, _date, _author, _subject })
            {
                SetColumn(cell, column++);
                Children.Add(cell);
            }
        }

        private static TextBlock Cell() => new()
        {
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(6, 0, 6, 0),
        };

        public void Bind(FileRevision revision)
        {
            _hash.Text = revision.Hash[..Math.Min(8, revision.Hash.Length)];
            _date.Text = LogDates.Short(revision.AuthorTime);
            ToolTipService.SetToolTip(_date, LogDates.Detailed(revision.AuthorTime));
            _author.Text = revision.AuthorName;
            ToolTipService.SetToolTip(_author, $"{revision.AuthorName} <{revision.AuthorEmail}>");
            _subject.Text = revision.Subject;
            ToolTipService.SetToolTip(_subject, revision.Kind == ChangeKind.Renamed && revision.OrigPath is { } orig ? L10n.Tr("commit.renamedFrom", orig) : null);
        }
    }
}
