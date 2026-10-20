namespace GitDeck.Common;

/// 调试启动参数，与 mac 端的 `-debug.*` 同名，仅调试构建生效，用于自动化界面验证：
///
/// - `-debug.open <路径>`：启动后直接打开该项目（不显示欢迎页）。
/// - `-debug.welcome`：启动时显示欢迎页（不重新打开上次的项目）。
/// - `-debug.action <名称>`：窗口就绪后执行的操作，例如 `clone`、`mainMenu`、`projectMenu`、`toolWindows`。
/// - `-debug.snapshot <PNG 路径>`：约 2 秒后（或 `-debug.snapshotDelay <秒>`）把窗口内容渲染为 PNG。
/// - `-debug.exit`：截图后退出。
/// - `-debug.confirm`：推送对话框直接按默认选项确认（用于验证推送流程）。
/// - `-debug.theme light|dark`、`-debug.lang en|zh-Hans`：临时覆盖主题与语言（不写入设置）。
public static class DebugOptions
{
    private static readonly Dictionary<string, string> Values = Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());

    public static string? Get(string name) =>
        AppInfo.IsDebugBuild && Values.TryGetValue(name, out var value) ? value : null;

    public static bool Has(string name) => Get(name) is not null;

    public static double Double(string name, double fallback) =>
        double.TryParse(Get(name), System.Globalization.CultureInfo.InvariantCulture, out var value) ? value : fallback;

    private static Dictionary<string, string> Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("-debug.", StringComparison.Ordinal)) continue;
            var name = args[i][1..];
            var hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("-debug.", StringComparison.Ordinal);
            values[name] = hasValue ? args[++i] : "YES";
        }
        return values;
    }
}
