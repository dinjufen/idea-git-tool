using System.Diagnostics;

namespace GitDeck.Common;

public static class Shell
{
    /// 在资源管理器中显示（选中）文件或文件夹。
    public static void RevealInExplorer(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return;
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }
}
