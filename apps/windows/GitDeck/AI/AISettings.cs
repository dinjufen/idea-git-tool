using System.Text.Json;
using GitDeck.Common;
using GitDeck.Core;

namespace GitDeck.AI;

/// AI 评审设置（设置 > AI 评审，与 mac 端 AISettings 一致）。API Key 存在 Windows 凭据管理器，其余保存在设置文件中。
public static class AISettings
{
    public enum Provider
    {
        Anthropic,
        OpenAICompatible,
    }

    /// 评审结果使用的语言。
    public enum Language
    {
        Auto,
        English,
        Chinese,
    }

    public static readonly string[] Efforts = ["low", "medium", "high", "xhigh", "max"];

    public static event Action? Changed;

    public static string Id(this Provider provider) => provider == Provider.Anthropic ? "anthropic" : "openAICompatible";

    public static AiProviderKind Kind(this Provider provider) => provider == Provider.Anthropic ? AiProviderKind.Anthropic : AiProviderKind.OpenAiCompatible;

    public static string Title(this Provider provider) =>
        provider == Provider.Anthropic ? L10n.Tr("ai.provider.anthropic") : L10n.Tr("ai.provider.openai");

    /// 模型输入框的候选项。
    public static string[] SuggestedModels(this Provider provider) =>
        provider == Provider.Anthropic ? ["claude-opus-5-5", "claude-sonnet-5-5"] : [];

    private static string DefaultModel(this Provider provider) => provider == Provider.Anthropic ? "claude-opus-5-5" : "";

    /// Claude 的思考内容也计入输出上限，需要留足空间。
    private static int DefaultMaxTokens(this Provider provider) => provider == Provider.Anthropic ? 32_000 : 8_192;

    public static string Title(this Language language) => language switch
    {
        Language.English => "English",
        Language.Chinese => "简体中文",
        _ => L10n.Tr("ai.language.auto"),
    };

    /// 传给模型的语言名称。
    public static string PromptName(this Language language) => language switch
    {
        Language.English => "English",
        Language.Chinese => "Simplified Chinese",
        _ => L10n.Language == L10n.ChineseSimplified ? "Simplified Chinese" : "English",
    };

    private static string Key(Provider provider, string name) => $"ai.{provider.Id()}.{name}";

    public static Provider CurrentProvider
    {
        get => Settings.GetString("ai.provider") == "openAICompatible" ? Provider.OpenAICompatible : Provider.Anthropic;
        set
        {
            Settings.Set("ai.provider", value.Id());
            Changed?.Invoke();
        }
    }

    public static string BaseUrl(Provider provider) =>
        Settings.GetString(Key(provider, "baseURL")) is { Length: > 0 } value ? value : CoreApi.DefaultAiBaseUrl(provider.Kind());

    public static void SetBaseUrl(Provider provider, string value)
    {
        Settings.Set(Key(provider, "baseURL"), value.Trim());
        Changed?.Invoke();
    }

    public static string Model(Provider provider) => Settings.GetString(Key(provider, "model")) ?? provider.DefaultModel();

    public static void SetModel(Provider provider, string value)
    {
        Settings.Set(Key(provider, "model"), value.Trim());
        Changed?.Invoke();
    }

    public static int MaxTokens(Provider provider)
    {
        var value = (int)Settings.GetDouble(Key(provider, "maxTokens"));
        return value > 0 ? value : provider.DefaultMaxTokens();
    }

    public static void SetMaxTokens(Provider provider, int value)
    {
        Settings.Set(Key(provider, "maxTokens"), value);
        Changed?.Invoke();
    }

    /// 评审时的思考强度（Claude）；评审显式使用 high。
    public static string Effort
    {
        get => Settings.GetString("ai.anthropic.effort") is { } value && Efforts.Contains(value) ? value : "high";
        set
        {
            Settings.Set("ai.anthropic.effort", value);
            Changed?.Invoke();
        }
    }

    /// OpenAI 兼容模型是否支持工具调用；不支持时退化为单次调用。
    public static bool SupportsTools
    {
        get => Settings.GetBool("ai.openAICompatible.tools", true);
        set
        {
            Settings.Set("ai.openAICompatible.tools", value);
            Changed?.Invoke();
        }
    }

    public static Language ReviewLanguage
    {
        get => Settings.GetString("ai.language") switch
        {
            "english" => Language.English,
            "chinese" => Language.Chinese,
            _ => Language.Auto,
        };
        set
        {
            Settings.Set("ai.language", value.ToString().ToLowerInvariant());
            Changed?.Invoke();
        }
    }

    public static List<string> SensitivePatterns
    {
        get => Settings.Contains("ai.sensitivePatterns") ? Settings.GetStringList("ai.sensitivePatterns") : [.. CoreApi.DefaultSensitivePatterns()];
        set
        {
            Settings.Set("ai.sensitivePatterns", value);
            Changed?.Invoke();
        }
    }

    /// 提交前运行 AI 评审（提交选项中的检查项）。
    public static bool ReviewBeforeCommit
    {
        get => Settings.GetBool("ai.reviewBeforeCommit");
        set => Settings.Set("ai.reviewBeforeCommit", value);
    }

    public static string? ApiKey(Provider provider) => CredentialStore.Read(provider.Id());

    public static bool SetApiKey(Provider provider, string? value)
    {
        var ok = CredentialStore.Write(provider.Id(), value?.Trim());
        Changed?.Invoke();
        return ok;
    }

    public static AiProviderConfig Config(Provider provider, string? effort = null) => new(
        provider.Kind(),
        BaseUrl(provider),
        Model(provider),
        (uint)Math.Clamp(MaxTokens(provider), 1, int.MaxValue),
        provider == Provider.Anthropic || SupportsTools,
        provider == Provider.Anthropic ? effort ?? Effort : null);

    /// 当前服务商的配置与 API Key；未配置完整时为 null（本地模型不需要 Key）。
    public static (AiProviderConfig Config, string ApiKey)? Current()
    {
        var provider = CurrentProvider;
        var config = Config(provider);
        var apiKey = ApiKey(provider) ?? "";
        if (config.Model.Length == 0 || (apiKey.Length == 0 && !IsLocal(config.BaseUrl))) return null;
        return (config, apiKey);
    }

    /// 服务运行在本机（Ollama、LM Studio 等）：代码不会离开本机，无需逐项目确认。
    public static bool IsLocal(string baseUrl) =>
        Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri) && uri.Host.ToLowerInvariant() is "localhost" or "127.0.0.1" or "::1" or "[::1]";

    public static string Host(string baseUrl) => Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri) ? uri.Host : baseUrl;

    // MARK: - 项目授权

    /// 每个项目首次把代码发给某个服务前需要用户确认；记录 “项目 → 已授权的服务”。
    private const string ConsentKey = "ai.consent";

    private static string ConsentIdentity(AiProviderConfig config) =>
        $"{(config.Kind == AiProviderKind.Anthropic ? "anthropic" : "openai")}@{Host(config.BaseUrl)}";

    private static Dictionary<string, List<string>> ConsentMap()
    {
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, List<string>>>(Settings.GetString(ConsentKey) ?? "{}") ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public static bool HasConsent(string project, AiProviderConfig config) =>
        IsLocal(config.BaseUrl) || (ConsentMap().TryGetValue(project.ToLowerInvariant(), out var list) && list.Contains(ConsentIdentity(config)));

    public static void GrantConsent(string project, AiProviderConfig config)
    {
        var map = ConsentMap();
        var key = project.ToLowerInvariant();
        if (!map.TryGetValue(key, out var list)) map[key] = list = [];
        var identity = ConsentIdentity(config);
        if (!list.Contains(identity)) list.Add(identity);
        Settings.Set(ConsentKey, JsonSerializer.Serialize(map));
    }
}
