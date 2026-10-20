using Microsoft.Win32;

namespace GitDeck.Common;

/// 已安装的字体族（读取系统与当前用户的字体注册表项），用于字体设置中的候选列表与回退判断。
public static class FontCatalog
{
    /// 常见的等宽编程字体，已安装的排在字体候选列表前面。
    private static readonly string[] Monospace =
    [
        "JetBrains Mono", "Cascadia Mono", "Cascadia Code", "Consolas", "Fira Code", "Fira Mono", "Source Code Pro",
        "Hack", "Iosevka", "Ubuntu Mono", "DejaVu Sans Mono", "Roboto Mono", "Sarasa Mono SC", "Sarasa Term SC",
        "Lucida Console", "Courier New",
    ];

    private static HashSet<string>? _families;

    public static IReadOnlyCollection<string> Families => _families ??= Load();

    public static bool IsInstalled(string family) => Families.Contains(family);

    /// 编辑器字体候选：已安装的等宽字体在前，其余字体按名称排序在后。
    public static IReadOnlyList<string> EditorCandidates()
    {
        var mono = Monospace.Where(IsInstalled).ToList();
        return [.. mono, .. Families.Except(mono).Order(StringComparer.CurrentCultureIgnoreCase)];
    }

    /// 界面字体候选：全部字体按名称排序。
    public static IReadOnlyList<string> UiCandidates() => [.. Families.Order(StringComparer.CurrentCultureIgnoreCase)];

    private static HashSet<string> Load()
    {
        var families = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        const string key = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts";
        foreach (var root in new[] { Registry.LocalMachine, Registry.CurrentUser })
        {
            using var fonts = root.OpenSubKey(key);
            if (fonts is null) continue;
            foreach (var name in fonts.GetValueNames())
            {
                // 注册表值名形如 “Cascadia Mono Bold (TrueType)” 或 “Sarasa Mono SC & Sarasa Term SC (TrueType)”。
                var display = name;
                var paren = display.LastIndexOf(" (", StringComparison.Ordinal);
                if (paren > 0) display = display[..paren];
                foreach (var part in display.Split(" & "))
                {
                    families.Add(StripStyle(part.Trim()));
                }
            }
        }
        return families;
    }

    private static readonly string[] StyleWords =
    [
        "Regular", "Bold", "Italic", "Oblique", "Light", "ExtraLight", "Extra Light", "SemiLight", "Semilight", "Semibold",
        "SemiBold", "Demibold", "Medium", "Black", "Heavy", "Thin", "ExtraBold", "Extra Bold", "Condensed", "Narrow",
    ];

    private static string StripStyle(string name)
    {
        var changed = true;
        while (changed)
        {
            changed = false;
            foreach (var word in StyleWords)
            {
                if (name.EndsWith(" " + word, StringComparison.OrdinalIgnoreCase))
                {
                    name = name[..^(word.Length + 1)];
                    changed = true;
                }
            }
        }
        return name;
    }
}
