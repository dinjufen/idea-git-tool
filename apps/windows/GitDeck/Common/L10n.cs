using System.Collections.Generic;
using System.Globalization;
using System.Linq;
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
        ApplyFormattingCulture();
    }

    /// 日期与数字格式跟随界面语言：区域格式的语言与界面语言相同时保留用户的区域设置，
    /// 否则改用界面语言的默认区域（例如区域为 zh-CN、界面为英文时，日期不再显示成“2026年10月23日”）。
    private static void ApplyFormattingCulture()
    {
        var prefix = Language == ChineseSimplified ? "zh" : "en";
        if (CultureInfo.CurrentCulture.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return;
        var culture = new CultureInfo(Language == ChineseSimplified ? "zh-CN" : "en-US");
        CultureInfo.CurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
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
        CoreException.CommandFailed e => CommandFailedMessage(e.stderr),
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
        CoreException.AiCliNotFound e => Tr("ai.error.cliNotFound", e.name),
        CoreException.AiCliFailed e => Tr("ai.error.cliFailed", e.message),
        CoreException.AiCancelled => Tr("ai.error.cancelled"),
        _ => error.Message,
    };

    /// 把 Git 命令失败转成面向用户的说明，与 mac 端 `commandFailedMessage` 保持一致。
    internal static string CommandFailedMessage(string stderr)
    {
        var detail = GitErrorDetail(stderr);
        if (UnknownRevision(detail) is { Length: > 0 } revision)
            return Tr("error.unknownRevision", revision);
        if (LooksLikeUnknownRevision(detail))
            return Tr("error.unknownRevisionGeneric");
        return string.IsNullOrEmpty(detail) ? Tr("error.commandFailedGeneric") : detail;
    }

    /// 去掉 Git 日志里的 fatal/error 等严重级别前缀，避免弹窗看起来像程序崩溃。
    internal static string GitErrorDetail(string stderr)
    {
        var lines = new List<string>();
        foreach (var raw in stderr.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = StripGitSeverityPrefix(raw);
            if (line.Length > 0) lines.Add(line);
        }
        return string.Join("\n", lines);
    }

    private static readonly string[] GitSeverityPrefixes =
    [
        "fatal:", "error:", "warning:", "hint:",
        "致命错误：", "错误：", "警告：", "提示：",
    ];

    private static string StripGitSeverityPrefix(string line)
    {
        line = line.Trim();
        var changed = true;
        while (changed)
        {
            changed = false;
            foreach (var prefix in GitSeverityPrefixes)
            {
                var matches = prefix.All(c => c <= 127)
                    ? line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                    : line.StartsWith(prefix, StringComparison.Ordinal);
                if (!matches) continue;
                line = line[prefix.Length..].Trim();
                changed = true;
                break;
            }
        }
        return line;
    }

    private static readonly Regex[] UnknownRevisionRegexes =
    [
        new(@"could not parse object '([^']+)'", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"invalid object name '([^']+)'", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"invalid object name ([0-9a-fA-F]+)", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"bad revision '([^']+)'", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"bad object '([^']+)'", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"ambiguous argument '([^']+)'", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"无法解析对象\s*['「『“]([^'」』”]+)['」』”]", RegexOptions.Compiled),
    ];

    private static string? UnknownRevision(string detail)
    {
        foreach (var regex in UnknownRevisionRegexes)
        {
            var match = regex.Match(detail);
            if (match.Success && match.Groups.Count > 1)
            {
                var revision = match.Groups[1].Value.Trim();
                if (revision.Length > 0) return revision;
            }
        }
        return null;
    }

    private static readonly Regex UnknownRevisionGenericRegex =
        new(@"needed a single revision|unknown revision", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static bool LooksLikeUnknownRevision(string detail) =>
        UnknownRevisionGenericRegex.IsMatch(detail);
}
