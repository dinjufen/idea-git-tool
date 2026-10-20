using System.Reflection;

namespace GitDeck.Common;

/// 产品名与数据目录。调试构建使用独立的目录，避免影响同时安装的正式版（见 docs/WINDOWS-HANDOFF.md 第 2 节）。
public static class AppInfo
{
    /// 产品名（与 product.env 中的 PRODUCT_NAME 一致）。
    public const string ProductName = "GitDeck";

#if DEBUG
    public const bool IsDebugBuild = true;
    private const string DataFolderName = ProductName + ".debug";
#else
    public const bool IsDebugBuild = false;
    private const string DataFolderName = ProductName;
#endif

    /// `%LOCALAPPDATA%\GitDeck`（调试版为 `GitDeck.debug`）。
    public static string DataDirectory { get; } = CreateDataDirectory();

    public static string Version =>
        Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";

    public static string AppDirectory => AppContext.BaseDirectory;

    private static string CreateDataDirectory()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), DataFolderName);
        Directory.CreateDirectory(path);
        return path;
    }
}
