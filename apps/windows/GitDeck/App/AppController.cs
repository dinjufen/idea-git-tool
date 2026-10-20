using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using GitDeck.Welcome;
using Microsoft.UI.Xaml;

namespace GitDeck;

/// 应用级流程（对应 mac 端的 AppDelegate）：欢迎页、打开 / 新建 / 克隆项目、项目窗口的生命周期。
public sealed class AppController
{
    public static AppController Shared { get; } = new();

    private readonly List<ProjectWindow> _projects = [];
    private WelcomeWindow? _welcome;

    /// 关闭最后一个项目窗口时回到欢迎页；退出应用时不回到欢迎页。
    private bool _exiting;

    public IReadOnlyList<ProjectWindow> Projects => _projects;

    public void Start()
    {
        // git / ssh 需要凭据时调用 askpass 程序弹出输入框（见 docs/DECISIONS.md 第 15 项）；语言随主程序。
        var askPass = Path.Combine(AppInfo.AppDirectory, "GitDeck.AskPass.exe");
        CoreApi.SetAskpassProgram(File.Exists(askPass) ? askPass : null);
        Environment.SetEnvironmentVariable("GITDECK_LANG", L10n.Language);
        Vcs.GitSettings.Apply();

        // 与 IDEA 一致：启动时重新打开上次的项目，否则显示欢迎页。
        var debugOpen = DebugOptions.Get("debug.open");
        var last = RecentProjects.Paths.FirstOrDefault();
        Window first;
        if (debugOpen is not null && OpenProject(debugOpen, owner: null) is { } debugProject)
        {
            first = debugProject;
        }
        else if (debugOpen is null && !DebugOptions.Has("debug.welcome") && last is not null && Directory.Exists(last)
                 && OpenProject(last, owner: null) is { } project)
        {
            first = project;
        }
        else
        {
            first = ShowWelcome();
        }
        CheckGitWhenReady(first);
    }

    public WelcomeWindow ShowWelcome()
    {
        if (_welcome is null)
        {
            _welcome = new WelcomeWindow(this);
            _welcome.Closed += (_, _) => _welcome = null;
        }
        _welcome.Reload();
        _welcome.Activate();
        return _welcome;
    }

    /// 打开项目；已打开时激活对应窗口。失败时在 `owner` 上提示错误。
    public ProjectWindow? OpenProject(string path, Window? owner)
    {
        if (_projects.FirstOrDefault(p => RecentProjects.SamePath(p.Model.RootPath, path)) is { } existing)
        {
            existing.Activate();
            return existing;
        }
        try
        {
            return Present(Repository.Open(path));
        }
        catch (CoreException error)
        {
            ShowError(owner, error);
            return null;
        }
    }

    public async Task OpenProjectWithPicker(Window owner)
    {
        if (await Dialogs.PickFolder(owner) is { } path) OpenProject(path, owner);
    }

    /// 新建项目：选择文件夹并初始化为 Git 仓库。
    public async Task NewProject(Window owner)
    {
        if (await Dialogs.PickFolder(owner) is not { } path) return;
        try
        {
            Present(Repository.Init(path));
        }
        catch (CoreException error)
        {
            ShowError(owner, error);
        }
    }

    /// 克隆仓库：克隆期间显示进度，完成后打开项目。
    public async Task CloneProject(Window owner)
    {
        var dialog = new CloneDialog(owner);
        if (await dialog.Run() is not { } request) return;
        var progress = CloneDialog.Progress(owner.Content.XamlRoot, request.Url);
        _ = progress.ShowAsync();
        try
        {
            var repository = await Task.Run(() => CoreApi.CloneRepository(request.Url, request.Directory));
            progress.Hide();
            Present(repository);
        }
        catch (CoreException error)
        {
            progress.Hide();
            await Dialogs.ShowError(owner.Content.XamlRoot, error);
        }
    }

    /// 退出应用（主菜单 “退出”，以及调试截图后的自动退出）。
    public void ExitApplication()
    {
        _exiting = true;
        foreach (var project in _projects.ToList()) project.Close();
        _welcome?.Close();
        // 等窗口（含编辑器组件）销毁完成后再退出进程。
        Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()
            .TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, Application.Current.Exit);
    }

    private ProjectWindow Present(Repository repository)
    {
        var window = new ProjectWindow(this, repository);
        window.Closed += (_, _) =>
        {
            _projects.Remove(window);
            if (_projects.Count == 0 && !_exiting) ShowWelcome();
        };
        _projects.Add(window);
        RecentProjects.Add(window.Model.RootPath);
        window.Activate();
        _welcome?.Close();
        return window;
    }

    private static void ShowError(Window? owner, Exception error)
    {
        if (owner?.Content?.XamlRoot is { } root) _ = Dialogs.ShowError(root, error);
        else PendingErrors.Add(error);
    }

    /// 启动时（还没有窗口）发生的错误，等第一个窗口就绪后再提示。
    private static readonly List<Exception> PendingErrors = [];

    /// 找不到可用的 git 时提示，并提供 Git for Windows 的下载链接（不内置 MinGit，见 docs/DECISIONS.md 第 16 项）。
    private static void CheckGitWhenReady(Window window)
    {
        if (window.Content is not FrameworkElement root) return;
        root.Loaded += async (_, _) =>
        {
            foreach (var error in PendingErrors.ToList())
            {
                PendingErrors.Remove(error);
                await Dialogs.ShowError(root.XamlRoot, error);
            }
            try
            {
                CoreApi.GitInfo();
            }
            catch (CoreException error)
            {
                var dialog = Dialogs.Create(root.XamlRoot, L10n.Tr("error.title"));
                dialog.Content = new Microsoft.UI.Xaml.Controls.TextBlock { Text = L10n.Message(error), TextWrapping = TextWrapping.Wrap };
                dialog.PrimaryButtonText = L10n.Tr("git.download");
                dialog.CloseButtonText = L10n.Tr("common.close");
                if (await dialog.ShowAsync() == Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary)
                {
                    await Windows.System.Launcher.LaunchUriAsync(new Uri("https://git-scm.com/download/win"));
                }
            }
        };
    }
}
