namespace GitDeck.Common;

/// 最近打开的项目，最新的在前。
public static class RecentProjects
{
    private const string Key = "recentProjects";
    private const int Limit = 30;

    public static IReadOnlyList<string> Paths => Settings.GetStringList(Key);

    public static void Add(string path)
    {
        var list = Settings.GetStringList(Key).Where(p => !SamePath(p, path)).ToList();
        list.Insert(0, path);
        Settings.Set(Key, list.Take(Limit));
    }

    public static void Remove(string path) =>
        Settings.Set(Key, Settings.GetStringList(Key).Where(p => !SamePath(p, path)));

    /// Windows 路径不区分大小写，并忽略结尾的分隔符。
    public static bool SamePath(string a, string b) =>
        string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    private static string Normalize(string path)
    {
        try
        {
            return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return path;
        }
    }
}
