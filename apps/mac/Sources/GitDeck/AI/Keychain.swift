import Foundation
import Security

/// 系统钥匙串中的通用密码项（API Key 等），不写入 UserDefaults 或任何配置文件。
///
/// debug 包是 ad-hoc 签名，每次重编 CDHash 都变，系统会把本次访问当成新客户端。
/// `SecItemCopyMatching` 弹出的授权框会跑嵌套 run loop；若此时设置页再次
/// `viewWillAppear` 并同步读取，就会叠出多个「输入 login 钥匙串密码」对话框，
/// 且点 Allow（一次性授权）后立刻又被下一次读取弹出。因此：
/// - 普通探测（设置页加载）禁止弹出 UI
/// - 进程内缓存成功读到的值
/// - 嵌套读取直接返回，不再二次弹窗
enum Keychain {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.example.gitdeck") + ".ai"
    }

    private final class State: @unchecked Sendable {
        var cache: [String: String] = [:]
        var knownPresent: Set<String> = []
        var knownAbsent: Set<String> = []
        var reading = false
    }

    private static let state = State()
    private static let lock = NSLock()

    @discardableResult
    private static func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func baseQuery(_ account: String, dataProtection: Bool) -> [String: Any] {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            item[kSecUseDataProtectionKeychain as String] = true
        }
        return item
    }

    /// 已缓存的存在性（不访问钥匙串，可在主线程调用）。未知时为 `nil`。
    static func cachedContains(_ account: String) -> Bool? {
        synced {
            if state.cache[account] != nil || state.knownPresent.contains(account) { return true }
            if state.knownAbsent.contains(account) { return false }
            return nil
        }
    }

    /// 同步探测钥匙串（可能耗时数秒），不弹授权框。仅在后台调用。
    static func probeContains(_ account: String) -> Bool {
        if let cached = cachedContains(account) { return cached }
        let present = probe(account, dataProtection: true) || probe(account, dataProtection: false)
        synced {
            if present {
                state.knownPresent.insert(account)
                state.knownAbsent.remove(account)
            } else {
                state.knownAbsent.insert(account)
                state.knownPresent.remove(account)
            }
        }
        return present
    }

    /// 是否已保存该账号。有缓存时立即返回；否则会同步探测钥匙串（可能阻塞）。
    static func contains(_ account: String) -> Bool {
        cachedContains(account) ?? probeContains(account)
    }

    /// - Parameter allowPrompt: `false` 时若系统需要授权则放弃读取（设置页加载用）。
    static func read(_ account: String, allowPrompt: Bool = true) -> String? {
        if let cached = synced({ state.cache[account] }) { return cached }
        if synced({ state.knownAbsent.contains(account) }) { return nil }
        // 授权对话框的嵌套 run loop 里不要再发起一次 CopyMatching。
        if !synced({
            if state.reading { return false }
            state.reading = true
            return true
        }) { return nil }
        defer { synced { state.reading = false } }

        let modern = copyMatching(account, dataProtection: true, allowPrompt: allowPrompt)
        if let value = modern.value {
            remember(account, value)
            return value
        }
        let legacy = copyMatching(account, dataProtection: false, allowPrompt: allowPrompt)
        if let value = legacy.value {
            remember(account, value)
            // 迁到 Data Protection 钥匙串，减轻 ad-hoc debug 包反复授权。
            if allowPrompt {
                _ = add(account, value, dataProtection: true)
            }
            return value
        }
        // 只有确认不存在时才记 miss；用户点 Deny 或需要授权时不记，以便稍后重试。
        if modern.notFound && legacy.notFound {
            synced { state.knownAbsent.insert(account) }
        }
        return nil
    }

    /// 保存；`value` 为空时删除。
    @discardableResult
    static func write(_ account: String, _ value: String?) -> Bool {
        synced {
            state.knownAbsent.remove(account)
            state.knownPresent.remove(account)
            state.cache.removeValue(forKey: account)
        }
        let bases = [baseQuery(account, dataProtection: true), baseQuery(account, dataProtection: false)]
        guard let value, !value.isEmpty else {
            var ok = false
            for base in bases {
                let status = SecItemDelete(base as CFDictionary)
                if status == errSecSuccess || status == errSecItemNotFound { ok = true }
            }
            if ok { synced { state.knownAbsent.insert(account) } }
            return ok
        }
        if add(account, value, dataProtection: true) {
            remember(account, value)
            // 清理旧的 login 钥匙串条目，避免下次又走 ACL 授权框。
            _ = SecItemDelete(baseQuery(account, dataProtection: false) as CFDictionary)
            return true
        }
        return false
    }

    // MARK: - Private

    private static func remember(_ account: String, _ value: String) {
        synced {
            state.cache[account] = value
            state.knownPresent.insert(account)
            state.knownAbsent.remove(account)
        }
    }

    private static func probe(_ account: String, dataProtection: Bool) -> Bool {
        var item = baseQuery(account, dataProtection: dataProtection)
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        case errSecItemNotFound:
            return false
        default:
            return false
        }
    }

    private struct CopyResult {
        var value: String?
        var notFound = false
    }

    private static func copyMatching(_ account: String, dataProtection: Bool, allowPrompt: Bool) -> CopyResult {
        var item = baseQuery(account, dataProtection: dataProtection)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowPrompt {
            item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return CopyResult(value: value)
        }
        return CopyResult(notFound: status == errSecItemNotFound)
    }

    @discardableResult
    private static func add(_ account: String, _ value: String, dataProtection: Bool) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(account, dataProtection: dataProtection)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
