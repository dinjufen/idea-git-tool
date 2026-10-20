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
        menu.Items.Add(Item(L10n.Tr("menu.file.closeProject"), window.Close, "Ctrl+Shift+W"));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("menu.file.exit"), app.ExitApplication));
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
        return menu;
    }

    private static MenuFlyoutSubItem GitMenu(ProjectWindow window)
    {
        var menu = new MenuFlyoutSubItem { Text = L10n.Tr("menu.git") };
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
