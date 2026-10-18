import Foundation
import GitDeckCore

/// AI 评审设置（Settings > AI Review）。API Key 存在系统钥匙串，其余持久化在 UserDefaults。
@MainActor
enum AISettings {
    static let didChange = Notification.Name("AISettingsDidChange")

    enum Provider: String, CaseIterable {
        case anthropic
        case openAICompatible

        var kind: AiProviderKind {
            switch self {
            case .anthropic: .anthropic
            case .openAICompatible: .openAiCompatible
            }
        }

        var title: String {
            switch self {
            case .anthropic: tr("ai.provider.anthropic")
            case .openAICompatible: tr("ai.provider.openai")
            }
        }

        /// 模型输入框的候选项。
        var suggestedModels: [String] {
            switch self {
            case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5"]
            case .openAICompatible: []
            }
        }

        var defaultModel: String {
            switch self {
            case .anthropic: "claude-opus-5-5"
            case .openAICompatible: ""
            }
        }

        /// Claude 的思考内容也计入输出上限，需要留足空间。
        var defaultMaxTokens: Int {
            switch self {
            case .anthropic: 32_000
            case .openAICompatible: 8_192
            }
        }
    }

    /// 评审结果使用的语言。
    enum Language: String, CaseIterable {
        case auto
        case english
        case chinese

        var title: String {
            switch self {
            case .auto: tr("ai.language.auto")
            case .english: "English"
            case .chinese: "简体中文"
            }
        }

        /// 传给模型的语言名称。
        var promptName: String {
            switch self {
            case .english: "English"
            case .chinese: "Simplified Chinese"
            case .auto:
                Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "Simplified Chinese" : "English"
            }
        }
    }

    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    private static let defaults = UserDefaults.standard

    private static func key(_ provider: Provider, _ name: String) -> String { "ai.\(provider.rawValue).\(name)" }

    static var provider: Provider {
        get { defaults.string(forKey: "ai.provider").flatMap(Provider.init) ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: "ai.provider"); post() }
    }

    static func baseURL(_ provider: Provider) -> String {
        let value = defaults.string(forKey: key(provider, "baseURL")) ?? ""
        return value.isEmpty ? defaultAiBaseUrl(kind: provider.kind) : value
    }

    static func setBaseURL(_ provider: Provider, _ value: String) {
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(provider, "baseURL"))
        post()
    }

    static func model(_ provider: Provider) -> String {
        defaults.string(forKey: key(provider, "model")) ?? provider.defaultModel
    }

    static func setModel(_ provider: Provider, _ value: String) {
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(provider, "model"))
        post()
    }

    static func maxTokens(_ provider: Provider) -> Int {
        let value = defaults.integer(forKey: key(provider, "maxTokens"))
        return value > 0 ? value : provider.defaultMaxTokens
    }

    static func setMaxTokens(_ provider: Provider, _ value: Int) {
        defaults.set(value, forKey: key(provider, "maxTokens"))
        post()
    }

    /// 评审时的思考强度（Claude）。Opus 5.5 的服务端默认是 medium，评审显式使用 high。
    static var effort: String {
        get { defaults.string(forKey: "ai.anthropic.effort").flatMap { efforts.contains($0) ? $0 : nil } ?? "high" }
        set { defaults.set(newValue, forKey: "ai.anthropic.effort"); post() }
    }

    /// OpenAI 兼容模型是否支持工具调用；不支持时退化为单次调用。
    static var supportsTools: Bool {
        get { defaults.object(forKey: "ai.openAICompatible.tools") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ai.openAICompatible.tools"); post() }
    }

    static var language: Language {
        get { defaults.string(forKey: "ai.language").flatMap(Language.init) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "ai.language"); post() }
    }

    static var sensitivePatterns: [String] {
        get { defaults.stringArray(forKey: "ai.sensitivePatterns") ?? defaultSensitivePatterns() }
        set { defaults.set(newValue, forKey: "ai.sensitivePatterns"); post() }
    }

    /// 提交前运行 AI 评审（提交选项中的检查项）。
    static var reviewBeforeCommit: Bool {
        get { defaults.bool(forKey: "ai.reviewBeforeCommit") }
        set { defaults.set(newValue, forKey: "ai.reviewBeforeCommit") }
    }

    static func apiKey(_ provider: Provider) -> String? { Keychain.read(provider.rawValue) }

    @discardableResult
    static func setAPIKey(_ provider: Provider, _ value: String?) -> Bool {
        let ok = Keychain.write(provider.rawValue, value?.trimmingCharacters(in: .whitespacesAndNewlines))
        post()
        return ok
    }

    static func config(_ provider: Provider, effort: String? = nil) -> AiProviderConfig {
        AiProviderConfig(
            kind: provider.kind,
            baseUrl: baseURL(provider),
            model: model(provider),
            maxTokens: UInt32(clamping: maxTokens(provider)),
            supportsTools: provider == .anthropic || supportsTools,
            effort: provider == .anthropic ? (effort ?? self.effort) : nil
        )
    }

    /// 当前服务商的配置与 API Key；未配置完整时为 `nil`（本地模型不需要 Key）。
    static func current() -> (config: AiProviderConfig, apiKey: String)? {
        let provider = self.provider
        let config = config(provider)
        let apiKey = apiKey(provider) ?? ""
        guard !config.model.isEmpty, !apiKey.isEmpty || isLocal(config.baseUrl) else { return nil }
        return (config, apiKey)
    }

    /// 服务运行在本机（Ollama、LM Studio 等）：代码不会离开本机，无需逐项目确认。
    static func isLocal(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func host(_ baseURL: String) -> String {
        URL(string: baseURL)?.host() ?? baseURL
    }

    // MARK: - 项目授权

    /// 每个项目首次把代码发给某个服务前需要用户确认；记录“项目 → 已授权的服务”。
    private static let consentKey = "ai.consent"

    private static func consentIdentity(_ config: AiProviderConfig) -> String {
        "\(config.kind == .anthropic ? "anthropic" : "openai")@\(host(config.baseUrl))"
    }

    static func hasConsent(project: String, config: AiProviderConfig) -> Bool {
        if isLocal(config.baseUrl) { return true }
        let map = defaults.dictionary(forKey: consentKey) as? [String: [String]] ?? [:]
        return map[project]?.contains(consentIdentity(config)) == true
    }

    static func grantConsent(project: String, config: AiProviderConfig) {
        var map = defaults.dictionary(forKey: consentKey) as? [String: [String]] ?? [:]
        var list = map[project] ?? []
        let identity = consentIdentity(config)
        if !list.contains(identity) { list.append(identity) }
        map[project] = list
        defaults.set(map, forKey: consentKey)
    }

    private static func post() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
