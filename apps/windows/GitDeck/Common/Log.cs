namespace GitDeck.Common;

/// 简单的诊断日志：写入数据目录下的 gitdeck.log（超过 1 MB 时清空重写）。
public static class Log
{
    private static readonly string FilePath = Path.Combine(AppInfo.DataDirectory, "gitdeck.log");
    private static readonly Lock Gate = new();

    public static void Info(string message) => Write("INFO", message);

    public static void Error(string message, Exception? error = null) =>
        Write("ERROR", error is null ? message : $"{message}: {error}");

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 1024 * 1024) File.Delete(FilePath);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {message}{Environment.NewLine}");
            }
        }
        catch (IOException)
        {
            // 日志写入失败不影响程序运行。
        }
    }
}
