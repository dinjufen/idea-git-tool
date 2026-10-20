using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace GitDeck.Project;

/// 主菜单。IDEA New UI 在 Windows 上把主菜单收进标题栏左侧的汉堡按钮；
/// 结构与 mac 端 MainMenu 一致，快捷键按 IDEA 的 Windows 键位（Ctrl 替代 Cmd，工具窗口为 Alt+数字）。
/// 后续批次实现的功能（编辑器、Git 操作等）在对应批次中加入菜单。
public static class MainMenu
{
    public static MenuFlyout Build(ProjectWindow window, AppController app)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(FileMenu(window, app));
        menu.Items.Add(EditMenu(window));
        menu.Items.Add(ViewMenu(window));
        menu.Items.Add(GitMenu(window));
        menu.Items.Add(HelpMenu(window));
        return menu;
    }

    private static MenuFlyoutSubItem FileMenu(ProjectWindow window, AppController app)
    {
        var menu = new MenuFlyoutSubItem { Text = L10n.Tr("menu.file") };
        menu.Items.Add(Item(L10n.Tr("menu.file.new"), async () => await app.NewProject(window)));
        menu.Items.Add(Item(L10n.Tr("menu.file.open"), async () => await app.OpenProjectWithPicker(window)));
        menu.Items.Add(Item(L10n.Tr("menu.file.clone"), async () => await app.CloneProject(window)));
        menu.Items.Add(Item(L10n.Tr("menu.file.welcome"), () => app.ShowWelcome()));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("menu.file.save"), window.SaveActive, "Ctrl+S"));
        menu.Items.Add(Item(L10n.Tr("menu.file.closeTab"), window.CloseActiveTab, "Ctrl+F4"));
        menu.Items.Add(Item(L10n.Tr("menu.file.closeProject"), window.Close, "Ctrl+Shift+W"));
        menu.Items.Add(new MenuFlyoutSeparator());
        // IDEA Windows 键位：Ctrl+Alt+S 打开设置。
        menu.Items.Add(Item(L10n.Tr("menu.app.settings"), () => SettingsWindow.Show(), "Ctrl+Alt+S"));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("menu.file.exit"), app.ExitApplication));
        return menu;
    }

    private static MenuFlyoutSubItem EditMenu(ProjectWindow window)
    {
        var menu = new MenuFlyoutSubItem { Text = L10n.Tr("menu.edit") };
        var editor = window.ActiveEditor;
        void Add(string key, Action<Editor.CodeEditor> action, string shortcut)
        {
            var item = Item(L10n.Tr(key), () => { if (window.ActiveEditor is { } e) action(e); }, shortcut);
            item.IsEnabled = editor is not null;
            menu.Items.Add(item);
        }
        Add("menu.edit.undo", e => e.Undo(), "Ctrl+Z");
        Add("menu.edit.redo", e => e.Redo(), "Ctrl+Shift+Z");
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("menu.edit.cut", e => e.Cut(), "Ctrl+X");
        Add("menu.edit.copy", e => e.Copy(), "Ctrl+C");
        Add("menu.edit.paste", e => e.Paste(), "Ctrl+V");
        Add("menu.edit.selectAll", e => e.SelectAll(), "Ctrl+A");
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("menu.edit.find", e => e.ShowFindBar(), "Ctrl+F");
        Add("menu.edit.replace", e => e.ShowFindBar(replace: true), "Ctrl+R");
        Add("menu.edit.findNext", e => e.FindNext(), "F3");
        Add("menu.edit.findPrevious", e => e.FindPrevious(), "Shift+F3");
        return menu;
    }

    private static MenuFlyoutSubItem ViewMenu(ProjectWindow window)
    {
        var menu = new MenuFlyoutSubItem { Text = L10n.Tr("menu.view") };
        var toolWindows = new MenuFlyoutSubItem { Text = L10n.Tr("menu.view.toolWindows") };
        foreach (var id in Enum.GetValues<ToolWindowId>())
        {
            var item = new ToggleMenuFlyoutItem { Text = id.Title(), IsChecked = window.IsToolWindowVisible(id) };
            if (id.Shortcut() is { } shortcut) item.KeyboardAcceleratorTextOverride = shortcut;
            item.Click += (_, _) => window.ToggleToolWindow(id);
            toolWindows.Items.Add(item);
        }
        menu.Items.Add(toolWindows);

        var theme = new MenuFlyoutSubItem { Text = L10n.Tr("menu.view.theme") };
        foreach (var setting in Enum.GetValues<AppearanceSetting>())
        {
            var item = new RadioMenuFlyoutItem { Text = Appearance.Title(setting), GroupName = "theme", IsChecked = Appearance.Current == setting };
            item.Click += (_, _) => Appearance.Current = setting;
            theme.Items.Add(item);
        }
        menu.Items.Add(theme);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("menu.view.editorFont"), window.ShowEditorFontDialog));
        menu.Items.Add(Item(L10n.Tr("menu.view.fontIncrease"), () => Editor.EditorSettings.FontSize += 1, "Ctrl+="));
        menu.Items.Add(Item(L10n.Tr("menu.view.fontDecrease"), () => Editor.EditorSettings.FontSize -= 1, "Ctrl+-"));
        menu.Items.Add(Item(L10n.Tr("menu.view.fontReset"), Editor.EditorSettings.Reset, "Ctrl+0"));
        var spacing = new MenuFlyoutSubItem { Text = L10n.Tr("menu.view.lineSpacing") };
        foreach (var value in Editor.EditorSettings.LineSpacingOptions)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = value.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture),
                GroupName = "lineSpacing",
                IsChecked = Editor.EditorSettings.LineSpacing == value,
            };
            item.Click += (_, _) => Editor.EditorSettings.LineSpacing = value;
            spacing.Items.Add(item);
        }
        menu.Items.Add(spacing);
        return menu;
    }

    private static MenuFlyoutSubItem GitMenu(ProjectWindow window)
    {
        var menu = new MenuFlyoutSubItem { Text = L10n.Tr("menu.git") };
        var ops = window.Operations;
        menu.Items.Add(Item(L10n.Tr("git.action.commit"), window.ShowCommit, "Ctrl+K"));
        menu.Items.Add(Item(L10n.Tr("git.action.push"), window.PushAll, "Ctrl+Shift+K"));
        menu.Items.Add(Item(L10n.Tr("git.action.update"), window.UpdateAll, "Ctrl+T"));
        menu.Items.Add(Item(L10n.Tr("git.action.fetch"), window.FetchAll));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("git.action.branches"), window.ShowBranches, "Ctrl+Shift+`"));
        menu.Items.Add(Item(L10n.Tr("branches.action.new"), () => ops.NewBranch(), "Ctrl+Alt+N"));
        menu.Items.Add(Item(L10n.Tr("branches.action.checkoutRevision"), ops.CheckoutRevisionDialog));
        menu.Items.Add(Item(L10n.Tr("tag.new.menu"), window.NewTag));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("patch.menu.create"), window.CreatePatch));
        menu.Items.Add(Item(L10n.Tr("patch.menu.apply"), window.ApplyPatch));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("workspace.menu.add"), window.AddRepository));
        menu.Items.Add(Item(L10n.Tr("remotes.menu"), window.ManageRemotes));
        menu.Items.Add(Item(L10n.Tr("submodules.menu"), window.ManageSubmodules));
        menu.Items.Add(Item(L10n.Tr("worktree.menu.new"), window.NewWorktree));
        menu.Items.Add(Item(L10n.Tr("console.menu"), window.ShowGitConsole));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("commit.action.rollback"), window.RollbackChanges, "Ctrl+Alt+Z"));
        menu.Items.Add(Item(L10n.Tr("stash.menu.stash"), window.StashChanges));
        menu.Items.Add(Item(L10n.Tr("stash.menu.unstash"), window.UnstashChanges));
        menu.Items.Add(Item(L10n.Tr("shelf.menu.shelve"), window.ShelveChanges));
        menu.Items.Add(Item(L10n.Tr("shelf.menu.show"), window.ShowShelf));
        menu.Items.Add(new MenuFlyoutSeparator());
        var review = Item(L10n.Tr("ai.menu.reviewLocal"), window.ReviewLocalChanges);
        review.IsEnabled = !window.IsAiReviewRunning && window.Model.Status.Changes.Length > 0;
        menu.Items.Add(review);
        menu.Items.Add(new MenuFlyoutSeparator());
        var annotate = Item(L10n.Tr(window.IsActiveAnnotated ? "git.action.closeAnnotations" : "git.action.annotate"), window.ToggleAnnotations);
        annotate.IsEnabled = window.HasActiveFile;
        menu.Items.Add(annotate);
        var history = Item(L10n.Tr("git.action.showHistoryCurrent"), window.ShowHistoryForCurrentFile);
        history.IsEnabled = window.HasActiveFile;
        menu.Items.Add(history);
        var state = window.Model.Status.State;
        if (state != Core.RepositoryState.Normal || window.HasConflicts) menu.Items.Add(new MenuFlyoutSeparator());
        if (window.HasConflicts) menu.Items.Add(Item(L10n.Tr("git.action.resolveConflicts"), window.ResolveConflicts));
        switch (state)
        {
            case Core.RepositoryState.Rebasing:
                menu.Items.Add(Item(L10n.Tr("git.action.continueRebase"), ops.ContinueRebase));
                menu.Items.Add(Item(L10n.Tr("git.action.abortRebase"), ops.AbortRebase));
                break;
            case Core.RepositoryState.Merging:
                menu.Items.Add(Item(L10n.Tr("git.action.abortMerge"), ops.AbortMerge));
                break;
            case Core.RepositoryState.CherryPicking:
                menu.Items.Add(Item(L10n.Tr("git.action.continueCherryPick"), ops.ContinueCherryPick));
                menu.Items.Add(Item(L10n.Tr("git.action.abortCherryPick"), ops.AbortCherryPick));
                break;
            case Core.RepositoryState.Reverting:
                menu.Items.Add(Item(L10n.Tr("git.action.continueRevert"), ops.ContinueRevert));
                menu.Items.Add(Item(L10n.Tr("git.action.abortRevert"), ops.AbortRevert));
                break;
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("git.action.refresh"), window.RefreshStatus, "Ctrl+Alt+R"));
        return menu;
    }

    private static MenuFlyoutSubItem HelpMenu(ProjectWindow window)
    {
        var menu = new MenuFlyoutSubItem { Text = L10n.Tr("menu.help") };
        menu.Items.Add(Item(L10n.Tr("menu.app.about", AppInfo.ProductName), async () =>
        {
            var git = "-";
            try
            {
                git = CoreApi.GitInfo().Version;
            }
            catch (CoreException)
            {
                // 未找到 git 时显示 “-”。
            }
            await Dialogs.ShowMessage(window.Content.XamlRoot, AppInfo.ProductName,
                $"{L10n.Tr("welcome.version", AppInfo.Version)}\ncore {CoreApi.CoreVersion()}\ngit {git}");
        }));
        return menu;
    }

    private static MenuFlyoutItem Item(string text, Action action, string? shortcut = null)
    {
        var item = new MenuFlyoutItem { Text = text };
        if (shortcut is not null) item.KeyboardAcceleratorTextOverride = shortcut;
        item.Click += (_, _) => action();
        return item;
    }

    private static MenuFlyoutItem Item(string text, Func<Task> action, string? shortcut = null) =>
        Item(text, () => { _ = action(); }, shortcut);
}
