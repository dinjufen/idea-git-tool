using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Merge;

/// IDEA 的 Conflicts 对话框（与 mac 端 ConflictsDialog 一致）：列出冲突文件，可整体接受一方或打开三栏合并工具。
/// 冲突全部解决后自动关闭。
public sealed class ConflictsDialog
{
    private readonly ProjectModel _model;
    private readonly Action<FileChange> _onMerge;
    private readonly ContentDialog _dialog;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Extended, Height = 260 };
    private readonly Button _acceptOurs = new();
    private readonly Button _acceptTheirs = new();
    private readonly TextBlock _oursHeader = new();
    private readonly TextBlock _theirsHeader = new();
    private List<FileChange> _conflicts = [];
    private ConflictLabels _labels = new("", "");
    private bool _busy;
    private bool _closed;

    public ConflictsDialog(ProjectModel model, XamlRoot root, Action<FileChange> onMerge)
    {
        _model = model;
        _onMerge = onMerge;
        _dialog = Dialogs.Create(root, L10n.Tr("conflicts.title"));
        _dialog.PrimaryButtonText = L10n.Tr("conflicts.merge");
        _dialog.CloseButtonText = L10n.Tr("conflicts.close");
        _dialog.Resources["ContentDialogMaxWidth"] = 760.0;
        _dialog.PrimaryButtonClick += (_, args) =>
        {
            // 打开合并工具时对话框保持打开（与 IDEA 一致）。
            args.Cancel = true;
            MergeSelected();
        };
        _dialog.Content = BuildContent();
        _list.SelectionChanged += (_, _) => UpdateButtons();
        _list.DoubleTapped += (_, _) => MergeSelected();
        _acceptOurs.Click += (_, _) => Accept(ConflictSide.Ours);
        _acceptTheirs.Click += (_, _) => Accept(ConflictSide.Theirs);
    }

    public async Task ShowAsync()
    {
        _model.Changed += Reload;
        Reload();
        var repository = _model.Repository;
        _ = Task.Run(repository.ConflictLabels).ContinueWith(task => _dialog.DispatcherQueue.TryEnqueue(() =>
        {
            if (task.IsFaulted) return;
            _labels = task.Result;
            _acceptOurs.Content = L10n.Tr("conflicts.acceptOurs", _labels.Ours);
            _acceptTheirs.Content = L10n.Tr("conflicts.acceptTheirs", _labels.Theirs);
            _oursHeader.Text = _labels.Ours;
            _theirsHeader.Text = _labels.Theirs;
        }), TaskScheduler.Default);
        try
        {
            await _dialog.ShowAsync();
        }
        finally
        {
            _closed = true;
            _model.Changed -= Reload;
        }
    }

    public void Close()
    {
        if (!_closed) _dialog.Hide();
    }

    private FrameworkElement BuildContent()
    {
        var message = new TextBlock { Text = L10n.Tr("conflicts.message"), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] };
        var header = Columns(new TextBlock { Text = L10n.Tr("conflicts.column.file") }, _oursHeader, _theirsHeader);
        foreach (var block in header.Children.OfType<TextBlock>())
        {
            block.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        }
        header.Margin = new Thickness(12, 0, 12, 0);
        var listBorder = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Child = _list };
        Themed.Brush(listBorder, "SeparatorBrush", (b, brush) => b.BorderBrush = brush);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _acceptOurs, _acceptTheirs } };
        _acceptOurs.Content = L10n.Tr("conflicts.acceptOurs", "");
        _acceptTheirs.Content = L10n.Tr("conflicts.acceptTheirs", "");
        return new StackPanel { Spacing = 10, Width = 640, Children = { message, header, listBorder, buttons } };
    }

    private static Grid Columns(FrameworkElement file, FrameworkElement ours, FrameworkElement theirs)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        Grid.SetColumn(ours, 1);
        Grid.SetColumn(theirs, 2);
        grid.Children.Add(file);
        grid.Children.Add(ours);
        grid.Children.Add(theirs);
        return grid;
    }

    private void Reload()
    {
        if (_model.IsRefreshing || _closed) return;
        var selected = Selected.Select(c => c.Path).ToHashSet();
        _conflicts = [.. _model.Status.Changes.Where(c => c.Conflict is not null).OrderBy(c => c.Path, StringComparer.OrdinalIgnoreCase)];
        if (_conflicts.Count == 0)
        {
            Close();
            return;
        }
        _list.Items.Clear();
        foreach (var change in _conflicts) _list.Items.Add(Row(change));
        for (var i = 0; i < _conflicts.Count; i++)
        {
            if (selected.Contains(_conflicts[i].Path)) _list.SelectRange(new Microsoft.UI.Xaml.Data.ItemIndexRange(i, 1));
        }
        if (_list.SelectedItems.Count == 0) _list.SelectedIndex = 0;
        UpdateButtons();
    }

    private static Grid Row(FileChange change)
    {
        var kind = change.Conflict ?? ConflictKind.BothModified;
        var file = new TextBlock { Text = change.Path, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Themed.Foreground(file, "StatusConflictBrush");
        TextBlock Side(bool ours) => new()
        {
            Text = SideStatus(kind, ours),
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            VerticalAlignment = VerticalAlignment.Center,
        };
        return Columns(file, Side(ours: true), Side(ours: false));
    }

    private List<FileChange> Selected =>
        [.. _list.SelectedItems.Select(item => _list.Items.IndexOf(item)).Where(i => i >= 0 && i < _conflicts.Count).Select(i => _conflicts[i])];

    private void UpdateButtons()
    {
        var selected = Selected;
        _acceptOurs.IsEnabled = selected.Count > 0 && !_busy;
        _acceptTheirs.IsEnabled = selected.Count > 0 && !_busy;
        // 三栏合并只适用于双方都有内容的单个文件。
        _dialog.IsPrimaryButtonEnabled = selected.Count == 1 && selected[0].Conflict is { } kind && BothSidesExist(kind) && !_busy;
    }

    public static bool BothSidesExist(ConflictKind kind) => kind is ConflictKind.BothModified or ConflictKind.BothAdded;

    private void MergeSelected()
    {
        if (!_dialog.IsPrimaryButtonEnabled || Selected.FirstOrDefault() is not { } change) return;
        _onMerge(change);
    }

    private void Accept(ConflictSide side)
    {
        var paths = Selected.Select(c => c.Path).ToList();
        if (paths.Count == 0) return;
        _busy = true;
        UpdateButtons();
        var repository = _model.Repository;
        Task.Run(() =>
        {
            foreach (var path in paths) repository.AcceptConflictSide(path, side);
        }).ContinueWith(task => _dialog.DispatcherQueue.TryEnqueue(() =>
        {
            _busy = false;
            UpdateButtons();
            // 对话框打开时不能再弹出另一个对话框，失败信息显示在状态栏。
            if (task.Exception?.InnerException is { } error) _model.Post(L10n.Tr("conflicts.failed") + ": " + L10n.Message(error), isError: true);
            _model.Refresh();
        }), TaskScheduler.Default);
    }

    /// 某一方对该文件做了什么：修改、新增或删除。
    private static string SideStatus(ConflictKind kind, bool ours) => (kind, ours) switch
    {
        (ConflictKind.BothModified, _) => L10n.Tr("conflicts.status.modified"),
        (ConflictKind.BothAdded, _) => L10n.Tr("conflicts.status.added"),
        (ConflictKind.BothDeleted, _) => L10n.Tr("conflicts.status.deleted"),
        (ConflictKind.AddedByUs, true) or (ConflictKind.AddedByThem, false) => L10n.Tr("conflicts.status.added"),
        (ConflictKind.AddedByUs, false) or (ConflictKind.AddedByThem, true) => "—",
        (ConflictKind.DeletedByUs, true) or (ConflictKind.DeletedByThem, false) => L10n.Tr("conflicts.status.deleted"),
        _ => L10n.Tr("conflicts.status.modified"),
    };
}
