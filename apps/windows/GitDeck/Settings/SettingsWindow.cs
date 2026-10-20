using System.Diagnostics;
using GitDeck.AI;

using GitDeck.Core;
using GitDeck.Editor;
using GitDeck.Vcs;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Common;

/// 设置窗口（Ctrl+Alt+S，与 IDEA Windows 键位一致）：左侧分类列表，右侧设置页——通用、编辑器、Git、AI 评审。
/// 与 mac 端 SettingsWindowController 一致，修改立即生效。
public sealed class SettingsWindow : Window
{
    public enum Page
    {
        General,
        Editor,
        Git,
        AI,
    }

    private const double TitleBarHeight = 32;
    private const double LabelWidth = 150;

    private static SettingsWindow? _shared;

    private readonly Grid _root = new();
    private readonly ListView _pages = new() { SelectionMode = ListViewSelectionMode.Single, Width = 180 };
    private readonly ScrollViewer _content = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly List<Func<FrameworkElement>> _builders = [];
    private Action? _commit;

    private SettingsWindow()
    {
        Title = L10n.Tr("settings.title");
        ExtendsContentIntoTitleBar = true;
        WindowHelper.SetIcon(this);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
        BuildLayout();
        Content = _root;
        Appearance.Register(this);
        WindowHelper.ResizeAndCenter(this, 860, 620);
        WindowHelper.SetMinimumSize(this, 700, 480);
        Closed += (_, _) =>
        {
            _commit?.Invoke();
            _shared = null;
        };
    }

    /// 显示设置窗口；`page` 为空时保留上次的页。
    public static SettingsWindow Show(Page? page = null)
    {
        _shared ??= new SettingsWindow();
        if (page is { } p) _shared._pages.SelectedIndex = (int)p;
        else if (_shared._pages.SelectedIndex < 0) _shared._pages.SelectedIndex = 0;
        _shared.Activate();
        return _shared;
    }

    private void BuildLayout()
    {
        Themed.Background(_root, "ToolWindowBackgroundBrush");
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBarHeight) });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var titleBar = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        titleBar.Children.Add(Themed.Foreground(new TextBlock { Text = Title, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 0, 60, 0) }, "PrimaryTextBrush"));
        Grid.SetColumnSpan(titleBar, 3);
        _root.Children.Add(titleBar);
        SetTitleBar(titleBar);

        foreach (var (key, builder) in new (string, Func<FrameworkElement>)[]
                 {
                     ("settings.general", BuildGeneral),
                     ("settings.editor", BuildEditor),
                     ("settings.git", BuildGit),
                     ("ai.settings.title", BuildAI),
                 })
        {
            _pages.Items.Add(new TextBlock { Text = L10n.Tr(key), Margin = new Thickness(4, 0, 0, 0) });
            _builders.Add(builder);
        }
        _pages.Margin = new Thickness(8, 4, 8, 8);
        _pages.SelectionChanged += (_, _) => ShowPage();
        Grid.SetRow(_pages, 1);
        _root.Children.Add(_pages);

        var divider = Themed.Background(new Border(), "SeparatorBrush");
        Grid.SetRow(divider, 1);
        Grid.SetRowSpan(divider, 2);
        Grid.SetColumn(divider, 1);
        _root.Children.Add(divider);

        Themed.Background(_content, "EditorBackgroundBrush");
        Grid.SetRow(_content, 1);
        Grid.SetColumn(_content, 2);
        _root.Children.Add(_content);

        var close = new Button { Content = L10n.Tr("conflicts.close"), MinWidth = 90, Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(16, 12, 16, 14) };
        close.Click += (_, _) => Close();
        Grid.SetRow(close, 2);
        Grid.SetColumn(close, 2);
        _root.Children.Add(close);
    }

    private void ShowPage()
    {
        // 切换页面前保存尚未结束编辑的输入。
        _commit?.Invoke();
        _commit = null;
        var index = _pages.SelectedIndex;
        _content.Content = index >= 0 && index < _builders.Count ? _builders[index]() : null;
    }

    // MARK: - 表单

    private sealed class Form : Grid
    {
        public Form()
        {
            Margin = new Thickness(24, 20, 24, 20);
            ColumnSpacing = 12;
            RowSpacing = 12;
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(LabelWidth) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        public void Add(string? labelKey, FrameworkElement control)
        {
            var row = RowDefinitions.Count;
            RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            if (labelKey is not null)
            {
                var label = Themed.Foreground(new TextBlock
                {
                    Text = L10n.Tr(labelKey),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextAlignment = TextAlignment.Right,
                    TextWrapping = TextWrapping.Wrap,
                }, "PrimaryTextBrush");
                SetRow(label, row);
                Children.Add(label);
            }
            control.HorizontalAlignment = HorizontalAlignment.Left;
            SetRow(control, row);
            SetColumn(control, 1);
            Children.Add(control);
        }

        public void Hint(string text) => Add(null, new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 480,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            Margin = new Thickness(0, -6, 0, 0),
        });
    }

    private static StackPanel Row(params FrameworkElement[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var child in children)
        {
            child.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(child);
        }
        return row;
    }

    // MARK: - 通用

    private FrameworkElement BuildGeneral()
    {
        var form = new Form();
        var languages = new (string Value, string Title)[]
        {
            ("system", L10n.Tr("settings.language.system")),
            (L10n.English, "English"),
            (L10n.ChineseSimplified, "简体中文"),
        };
        var language = new ComboBox { Width = 240, ItemsSource = languages.Select(l => l.Title).ToList() };
        language.SelectedIndex = Math.Max(0, Array.FindIndex(languages, l => l.Value == L10n.LanguageSetting));
        language.SelectionChanged += async (_, _) =>
        {
            var value = languages[Math.Max(0, language.SelectedIndex)].Value;
            if (value == L10n.LanguageSetting) return;
            L10n.LanguageSetting = value;
            await AskRestart();
        };
        form.Add("settings.language", language);
        form.Hint(L10n.Tr("settings.language.hint"));

        var themes = Enum.GetValues<AppearanceSetting>();
        var theme = new ComboBox { Width = 240, ItemsSource = themes.Select(Appearance.Title).ToList(), SelectedIndex = Array.IndexOf(themes, Appearance.Current) };
        theme.SelectionChanged += (_, _) => Appearance.Current = themes[Math.Max(0, theme.SelectedIndex)];
        form.Add("settings.theme", theme);

        // 界面字体（IDEA 的 外观 > 使用自定义字体）。
        var custom = new CheckBox { Content = L10n.Tr("settings.uiFont.custom"), IsChecked = UiFont.UseCustom };
        var families = FontCatalog.UiCandidates().ToList();
        var current = UiFont.Family ?? families.FirstOrDefault(f => f.StartsWith("Segoe UI", StringComparison.OrdinalIgnoreCase)) ?? "Segoe UI";
        // 设置的字体不在列表中（例如以本地化名称保存）时放在最前面，保证显示的是当前字体。
        if (!families.Contains(current, StringComparer.OrdinalIgnoreCase)) families.Insert(0, current);
        var family = new ComboBox { Width = 240, ItemsSource = families, IsEditable = false };
        family.SelectedItem = families.First(f => string.Equals(f, current, StringComparison.OrdinalIgnoreCase));
        var size = new NumberBox
        {
            Value = UiFont.Size,
            Minimum = UiFont.MinSize,
            Maximum = UiFont.MaxSize,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Width = 110,
        };
        void UpdateEnabled() => family.IsEnabled = size.IsEnabled = custom.IsChecked == true;
        UpdateEnabled();
        custom.Click += (_, _) =>
        {
            UiFont.UseCustom = custom.IsChecked == true;
            UpdateEnabled();
        };
        family.SelectionChanged += (_, _) =>
        {
            if (family.SelectedItem is string name && name != UiFont.Family) UiFont.Family = name;
        };
        size.ValueChanged += (_, args) =>
        {
            if (!double.IsNaN(args.NewValue) && args.NewValue != UiFont.Size) UiFont.Size = args.NewValue;
        };
        form.Add("settings.uiFont", custom);
        form.Add(null, Row(family, size));
        form.Hint(L10n.Tr("settings.uiFont.hint"));
        return form;
    }

    /// 语言在重启后生效：询问是否立即重启。
    private async Task AskRestart()
    {
        var dialog = Dialogs.Create(_root.XamlRoot, L10n.Tr("settings.language.restart.title"));
        dialog.Content = new TextBlock { Text = L10n.Tr("settings.language.restart.message"), TextWrapping = TextWrapping.Wrap };
        dialog.PrimaryButtonText = L10n.Tr("settings.language.restart.now");
        dialog.CloseButtonText = L10n.Tr("settings.language.restart.later");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (Environment.ProcessPath is { } exe) Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false });
        AppController.Shared.ExitApplication();
    }

    // MARK: - 编辑器

    private FrameworkElement BuildEditor()
    {
        var form = new Form();
        var families = new List<string> { L10n.Tr("settings.editor.systemFont") };
        families.AddRange(FontCatalog.EditorCandidates());
        var font = new ComboBox { Width = 280, ItemsSource = families };
        font.SelectedIndex = EditorSettings.FontFamily is { } name ? Math.Max(0, families.IndexOf(name)) : 0;
        font.SelectionChanged += (_, _) => EditorSettings.FontFamily = font.SelectedIndex <= 0 ? null : font.SelectedItem as string;
        form.Add("settings.editor.font", font);

        var size = new NumberBox
        {
            Value = EditorSettings.FontSize,
            Minimum = EditorSettings.MinSize,
            Maximum = EditorSettings.MaxSize,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Width = 110,
        };
        size.ValueChanged += (_, args) =>
        {
            if (!double.IsNaN(args.NewValue)) EditorSettings.FontSize = args.NewValue;
        };
        form.Add("settings.editor.size", size);

        var options = EditorSettings.LineSpacingOptions;
        var spacing = new ComboBox
        {
            Width = 110,
            ItemsSource = options.Select(o => o.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)).ToList(),
            SelectedIndex = Math.Max(0, Array.IndexOf(options, EditorSettings.LineSpacing)),
        };
        spacing.SelectionChanged += (_, _) => EditorSettings.LineSpacing = options[Math.Max(0, spacing.SelectedIndex)];
        form.Add("settings.editor.lineSpacing", spacing);

        var preview = Themed.Foreground(new TextBlock { Text = "fn main() { println!(\"GitDeck 0123456789\"); }" }, "PrimaryTextBrush");
        void UpdatePreview()
        {
            preview.FontFamily = new FontFamily(EditorSettings.EffectiveFamily);
            preview.FontSize = EditorSettings.FontSize;
        }
        UpdatePreview();
        EditorSettings.Changed += UpdatePreview;
        preview.Unloaded += (_, _) => EditorSettings.Changed -= UpdatePreview;
        form.Add("settings.editor.preview", preview);
        return form;
    }

    // MARK: - Git

    private FrameworkElement BuildGit()
    {
        var form = new Form();
        var path = new ComboBox { IsEditable = true, Width = 360, PlaceholderText = L10n.Tr("settings.git.autoDetect"), Text = GitSettings.ExecutablePath ?? "" };
        var browse = new Button { Content = L10n.Tr("clone.browse") };
        var test = new Button { Content = L10n.Tr("settings.git.test") };
        var result = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 420 };
        void Commit()
        {
            var value = (path.Text ?? "").Trim();
            if (value == (GitSettings.ExecutablePath ?? "")) return;
            GitSettings.ExecutablePath = value.Length == 0 ? null : value;
            RunTest();
        }
        // 检查当前设置（为空时为自动查找到的）git 的版本。
        void RunTest()
        {
            var value = (path.Text ?? "").Trim();
            result.Text = L10n.Tr("settings.git.testing");
            Themed.Foreground(result, "SecondaryTextBrush");
            Task.Run(() => value.Length == 0 ? CoreApi.GitInfo() : CoreApi.GitInfoAt(value)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
            {
                if (task.Exception?.InnerException is { } error)
                {
                    result.Text = L10n.Message(error);
                    Themed.Foreground(result, "StatusConflictBrush");
                }
                else
                {
                    result.Text = L10n.Tr("settings.git.found", task.Result.Version, task.Result.Path);
                    Themed.Foreground(result, "StatusAddedBrush");
                }
                ToolTipService.SetToolTip(result, result.Text);
            }), TaskScheduler.Default);
        }
        path.TextSubmitted += (_, _) => Commit();
        path.LostFocus += (_, _) => Commit();
        path.SelectionChanged += (_, _) =>
        {
            if (path.SelectedItem is string selected)
            {
                path.Text = selected;
                Commit();
            }
        };
        browse.Click += async (_, _) =>
        {
            var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(AppWindow.Id);
            picker.FileTypeFilter.Add(".exe");
            if (await picker.PickSingleFileAsync() is { } file)
            {
                path.Text = file.Path;
                Commit();
            }
        };
        test.Click += (_, _) => RunTest();
        _commit = Commit;
        // 本机常见位置上的 git 作为下拉候选。
        Task.Run(CoreApi.GitCandidates).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (!task.IsFaulted) path.ItemsSource = task.Result.Select(g => g.Path).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        }), TaskScheduler.Default);
        form.Add("settings.git.path", Row(path, browse));
        form.Add(null, Row(test, result));
        form.Hint(L10n.Tr("settings.git.path.hint"));

        var method = new ComboBox
        {
            Width = 240,
            ItemsSource = new List<string> { L10n.Tr("ops.update.merge.title"), L10n.Tr("ops.update.rebase.title") },
            SelectedIndex = GitSettings.UpdateMethod == UpdateMethod.Rebase ? 1 : 0,
        };
        method.SelectionChanged += (_, _) => GitSettings.UpdateMethod = method.SelectedIndex == 1 ? UpdateMethod.Rebase : UpdateMethod.Merge;
        form.Add("settings.git.updateMethod", method);
        var showDialog = new CheckBox { Content = L10n.Tr("settings.git.showUpdateDialog"), IsChecked = GitSettings.ShowUpdateDialog };
        showDialog.Click += (_, _) => GitSettings.ShowUpdateDialog = showDialog.IsChecked == true;
        form.Add(null, showDialog);
        RunTest();
        return form;
    }

    // MARK: - AI 评审

    private FrameworkElement BuildAI()
    {
        var form = new Form();
        var providers = Enum.GetValues<AISettings.Provider>();
        var provider = new ComboBox { Width = 300, ItemsSource = providers.Select(p => p.Title()).ToList(), SelectedIndex = Array.IndexOf(providers, AISettings.CurrentProvider) };
        var key = new PasswordBox { Width = 300 };
        var deleteKey = new Button { Content = L10n.Tr("ai.settings.deleteKey") };
        var baseUrl = new TextBox { Width = 360 };
        var model = new ComboBox { IsEditable = true, Width = 300 };
        var effort = new ComboBox { Width = 140, ItemsSource = AISettings.Efforts };
        var tools = new CheckBox { Content = L10n.Tr("ai.settings.tools") };
        var maxTokens = new NumberBox { Minimum = 1024, Maximum = 128_000, Width = 160, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden };
        var test = new Button { Content = L10n.Tr("ai.settings.test") };
        var status = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 380 };
        var languages = Enum.GetValues<AISettings.Language>();
        var language = new ComboBox { Width = 200, ItemsSource = languages.Select(l => l.Title()).ToList(), SelectedIndex = Array.IndexOf(languages, AISettings.ReviewLanguage) };
        var patterns = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            Height = 120,
            Width = 460,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            Text = string.Join("\r", AISettings.SensitivePatterns),
        };
        var resetPatterns = new Button { Content = L10n.Tr("ai.settings.patterns.reset") };
        AISettings.Provider Selected() => providers[Math.Max(0, provider.SelectedIndex)];
        var loading = false;

        var effortRow = 0;
        var toolsRow = 0;
        void LoadProvider()
        {
            loading = true;
            var p = Selected();
            key.Password = "";
            var hasKey = AISettings.ApiKey(p) is not null;
            key.PlaceholderText = L10n.Tr(hasKey ? "ai.settings.key.saved" : "ai.settings.key.placeholder");
            deleteKey.IsEnabled = hasKey;
            baseUrl.Text = AISettings.BaseUrl(p);
            baseUrl.PlaceholderText = CoreApi.DefaultAiBaseUrl(p.Kind());
            model.ItemsSource = p.SuggestedModels();
            model.Text = AISettings.Model(p);
            model.PlaceholderText = p == AISettings.Provider.Anthropic ? "claude-opus-5-5" : L10n.Tr("ai.settings.model.placeholder");
            effort.SelectedItem = AISettings.Effort;
            maxTokens.Value = AISettings.MaxTokens(p);
            tools.IsChecked = AISettings.SupportsTools;
            SetRowVisible(form, effortRow, p == AISettings.Provider.Anthropic);
            SetRowVisible(form, toolsRow, p == AISettings.Provider.OpenAICompatible);
            status.Text = "";
            loading = false;
        }

        // 输入框尚未结束编辑时（例如直接点击 “测试连接”）也写入设置。
        void Commit()
        {
            var p = Selected();
            var value = key.Password.Trim();
            if (value.Length > 0)
            {
                if (AISettings.SetApiKey(p, value))
                {
                    key.Password = "";
                    key.PlaceholderText = L10n.Tr("ai.settings.key.saved");
                    deleteKey.IsEnabled = true;
                }
                else
                {
                    ShowStatus(L10n.Tr("ai.settings.key.saveFailed"), ok: false);
                }
            }
            if (baseUrl.Text.Trim() != AISettings.BaseUrl(p)) AISettings.SetBaseUrl(p, baseUrl.Text);
            if ((model.Text ?? "").Trim() != AISettings.Model(p)) AISettings.SetModel(p, model.Text ?? "");
            if (!double.IsNaN(maxTokens.Value) && (int)maxTokens.Value != AISettings.MaxTokens(p)) AISettings.SetMaxTokens(p, (int)maxTokens.Value);
            SavePatterns();
        }

        void SavePatterns()
        {
            var list = patterns.Text.Split('\r', '\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            if (!list.SequenceEqual(AISettings.SensitivePatterns)) AISettings.SensitivePatterns = list;
        }

        void ShowStatus(string text, bool ok)
        {
            status.Text = text;
            ToolTipService.SetToolTip(status, text);
            Themed.Foreground(status, ok ? "StatusAddedBrush" : "StatusConflictBrush");
        }

        provider.SelectionChanged += (_, _) =>
        {
            if (loading) return;
            AISettings.CurrentProvider = Selected();
            LoadProvider();
        };
        deleteKey.Click += (_, _) =>
        {
            AISettings.SetApiKey(Selected(), null);
            LoadProvider();
        };
        key.LostFocus += (_, _) => Commit();
        baseUrl.LostFocus += (_, _) => Commit();
        model.LostFocus += (_, _) => Commit();
        model.SelectionChanged += (_, _) =>
        {
            if (loading || model.SelectedItem is not string selected) return;
            model.Text = selected;
            Commit();
        };
        maxTokens.LostFocus += (_, _) => Commit();
        effort.SelectionChanged += (_, _) =>
        {
            if (!loading && effort.SelectedItem is string value) AISettings.Effort = value;
        };
        tools.Click += (_, _) => AISettings.SupportsTools = tools.IsChecked == true;
        language.SelectionChanged += (_, _) => AISettings.ReviewLanguage = languages[Math.Max(0, language.SelectedIndex)];
        patterns.LostFocus += (_, _) => SavePatterns();
        resetPatterns.Click += (_, _) =>
        {
            patterns.Text = string.Join("\r", CoreApi.DefaultSensitivePatterns());
            SavePatterns();
        };
        test.Click += (_, _) =>
        {
            Commit();
            var p = Selected();
            var config = AISettings.Config(p, effort: "low");
            var apiKey = AISettings.ApiKey(p) ?? "";
            if (config.Model.Length == 0)
            {
                ShowStatus(L10n.Tr("ai.error.noModel"), ok: false);
                return;
            }
            test.IsEnabled = false;
            Themed.Foreground(status, "SecondaryTextBrush");
            status.Text = L10n.Tr("ai.settings.test.running");
            Task.Run(() => CoreApi.TestAiConnection(config, apiKey)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
            {
                test.IsEnabled = true;
                if (task.Exception?.InnerException is { } error) ShowStatus(L10n.Message(error), ok: false);
                else ShowStatus(L10n.Tr("ai.settings.test.ok", config.Model), ok: true);
            }), TaskScheduler.Default);
        };
        _commit = Commit;

        form.Add("ai.settings.provider", provider);
        form.Add("ai.settings.key", Row(key, deleteKey));
        form.Add("ai.settings.baseURL", baseUrl);
        form.Add("ai.settings.model", model);
        effortRow = form.RowDefinitions.Count;
        form.Add("ai.settings.effort", effort);
        toolsRow = form.RowDefinitions.Count;
        form.Add(null, tools);
        form.Add("ai.settings.maxTokens", maxTokens);
        form.Add(null, Row(test, status));
        form.Hint(L10n.Tr("ai.settings.privacy.hint"));
        form.Add("ai.settings.language", language);
        var patternsColumn = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                patterns,
                new TextBlock { Text = L10n.Tr("ai.settings.patterns.hint"), TextWrapping = TextWrapping.Wrap, MaxWidth = 460, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] },
                resetPatterns,
            },
        };
        form.Add("ai.settings.patterns", patternsColumn);
        form.Hint(L10n.Tr("ai.settings.rules.hint"));
        LoadProvider();
        return form;
    }

    private static void SetRowVisible(Grid grid, int row, bool visible)
    {
        foreach (var child in grid.Children.OfType<FrameworkElement>().Where(c => Grid.GetRow(c) == row))
        {
            child.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        }
    }
}
