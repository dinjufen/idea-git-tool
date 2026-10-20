using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using GitDeck.Core;

namespace GitDeck.Common;

/// 本地化。文案与 mac 端共用 `apps/mac/Sources/GitDeck/Resources/Localizable.xcstrings`（作为嵌入资源读取），
/// 只有一份来源；Windows 上说法不同的条目以 `<键名>.win` 加在同一文件中，查找时优先使用。
public static partial class L10n
{
    public const string English = "en";
    public const string ChineseSimplified = "zh-Hans";
    private const string LanguageKey = "language";

    private static Dictionary<string, string>? _strings;
    private static Dictionary<string, string>? _fallback;

    /// 设置中的语言：`system`（跟随系统）、`en` 或 `zh-Hans`。修改后重启生效，与 mac 端一致。
    public static string LanguageSetting
    {
        get => Settings.GetString(LanguageKey) ?? "system";
        set => Settings.Set(LanguageKey, value);
    }

    /// 本次运行使用的语言。
    public static string Language { get; private set; } = English;

    public static void Initialize(string? overrideLanguage = null)
    {
        var setting = overrideLanguage ?? LanguageSetting;
        Language = setting is English or ChineseSimplified ? setting : SystemLanguage();
        (_strings, _fallback) = Load(Language);
    }

    /// 查找文案；参数替换 `%1$@`、`%2$@` …（以及按顺序的 `%@`）。
    public static string Tr(string key, params object?[] args)
    {
        if (_strings is null) Initialize();
        var format = Lookup(key + ".win") ?? Lookup(key) ?? key;
        return args.Length == 0 ? format.Replace("%%", "%") : Format(format, args);
    }

    private static string? Lookup(string key) =>
        _strings!.TryGetValue(key, out var value) || _fallback!.TryGetValue(key, out value) ? value : null;

    private static string Format(string format, object?[] args)
    {
        var next = 0;
        return Specifier().Replace(format, match =>
        {
            if (match.Value == "%%") return "%";
            var index = match.Groups[1].Success ? int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) - 1 : next++;
            return index >= 0 && index < args.Length ? Convert.ToString(args[index], CultureInfo.CurrentCulture) ?? "" : "";
        });
    }

    [GeneratedRegex(@"%%|%(?:(\d+)\$)?@")]
    private static partial Regex Specifier();

    private static string SystemLanguage() =>
        CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? ChineseSimplified : English;

    private static (Dictionary<string, string>, Dictionary<string, string>) Load(string language)
    {
        var strings = new Dictionary<string, string>();
        var fallback = new Dictionary<string, string>();
        using var stream = typeof(L10n).Assembly.GetManifestResourceStream("Localizable.xcstrings")
            ?? throw new InvalidOperationException("missing Localizable.xcstrings");
        using var document = JsonDocument.Parse(stream);
        foreach (var entry in document.RootElement.GetProperty("strings").EnumerateObject())
        {
            if (!entry.Value.TryGetProperty("localizations", out var localizations)) continue;
            if (Value(localizations, language) is { } text) strings[entry.Name] = text;
            if (Value(localizations, English) is { } en) fallback[entry.Name] = en;
        }
        return (strings, fallback);
    }

    private static string? Value(JsonElement localizations, string language) =>
        localizations.TryGetProperty(language, out var localization)
        && localization.TryGetProperty("stringUnit", out var unit)
        && unit.TryGetProperty("value", out var value)
            ? value.GetString()
            : null;

    /// 面向用户的错误描述。核心只给出错误类型与参数，文案在这里映射（与 mac 端 L10n.swift 一致）。
    public static string Message(Exception error) => error switch
    {
        CoreException.GitNotFound => Tr("error.gitNotFound"),
        CoreException.GitTooOld e => Tr("error.gitTooOld", e.found, e.required),
        CoreException.NotARepository e => Tr("error.notARepository", e.path),
        CoreException.CommandFailed e => Tr("error.commandFailed", e.command, e.stderr),
        CoreException.Parse e => Tr("error.parse", e.detail),
        CoreException.Io e => Tr("error.io", e.detail),
        CoreException.EmptyCommitMessage => Tr("error.emptyCommitMessage"),
        CoreException.NothingToCommit => Tr("error.nothingToCommit"),
        CoreException.InvalidBranchName e => Tr("ops.error.invalidName", e.name),
        CoreException.LocalChangesWouldBeOverwritten e => Tr("ops.error.overwritten", string.Join("\n", e.files)),
        CoreException.BranchNotFullyMerged e => Tr("ops.delete.notMerged.title", e.name),
        CoreException.NoUpstream e => Tr("ops.error.noUpstream", e.branch),
        CoreException.DetachedHead => Tr("ops.error.detachedHead"),
        CoreException.PushRejected e => Tr("ops.error.pushRejected", e.reason),
        CoreException.AuthenticationFailed e => Tr("ops.error.auth", e.detail),
        CoreException.InvalidTagName e => Tr("ops.error.invalidTagName", e.name),
        CoreException.RebaseWithMerges => Tr("ops.error.rebaseWithMerges"),
        CoreException.InvalidRebasePlan e => Tr("ops.error.invalidRebasePlan", e.detail),
        CoreException.AiNetwork e => Tr("ai.error.network", e.detail),
        CoreException.AiAuthenticationFailed e => Tr("ai.error.auth", e.message),
        CoreException.AiRequestFailed { status: 429 } e => Tr("ai.error.rateLimited", e.message),
        CoreException.AiRequestFailed { status: 529 or 503 } e => Tr("ai.error.overloaded", e.message),
        CoreException.AiRequestFailed e => Tr("ai.error.request", e.status.ToString(CultureInfo.InvariantCulture), e.message),
        CoreException.AiRefused e => Tr("ai.error.refused", e.category ?? "-"),
        CoreException.AiInvalidResponse e => Tr("ai.error.invalidResponse", e.detail),
        CoreException.AiCancelled => Tr("ai.error.cancelled"),
        _ => error.Message,
    };
}
