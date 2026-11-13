import Foundation
import ScoutCore
import Security

nonisolated enum LinearCredential: Sendable {
    case apiKey(String)
    case oauth(accessToken: String)

    var authorization: String {
        switch self {
        case .apiKey(let key): key
        case .oauth(let token): "Bearer \(token)"
        }
    }
}

nonisolated struct LinearKeyHint: Codable, Hashable, Sendable {
    enum Store: String, Codable, Sendable {
        case dataProtection, login, memory
    }

    var prefix: String
    var suffix: String
    var store: Store

    init(key: String, store: Store) {
        prefix = key.hasPrefix("lin_api_") ? "lin_api_" : ""
        suffix = key.count >= 16 ? String(key.suffix(4)) : ""
        self.store = store
    }

    var masked: String { "\(prefix)••••••••\(suffix)" }
}

final class LinearCredentials {
    enum Storage {
        case keychain
        case memory
    }

    static let service = ScoutDataRoot.current.isRelease ? "com.trmdy.scout.linear" : "\(Bundle.main.bundleIdentifier ?? "unbundled").linear"
    static let account = "personal-api-key"
    private static let hintKey = "linear.keyHint"

    private let storage: Storage
    private let defaults: UserDefaults
    private var memoryKey: String?
    private(set) var hint: LinearKeyHint?

    init(storage: Storage, defaults: UserDefaults) {
        self.storage = storage
        self.defaults = defaults
        if storage == .keychain {
            hint = defaults.data(forKey: Self.hintKey).flatMap { try? JSONDecoder().decode(LinearKeyHint.self, from: $0) }
        }
    }

    func current() throws(LinearError) -> LinearCredential? {
        guard let hint else { return nil }
        switch hint.store {
        case .memory:
            return memoryKey.map(LinearCredential.apiKey)
        case .dataProtection, .login:
            var query = Self.query(dataProtection: hint.store == .dataProtection)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw .keychain(status)
            }
            return .apiKey(key)
        }
    }

    @discardableResult
    func save(_ key: String) throws(LinearError) -> LinearKeyHint {
        let store: LinearKeyHint.Store
        switch storage {
        case .memory:
            memoryKey = key
            store = .memory
        case .keychain:
            deleteKeychainItems()
            let status = Self.add(key, dataProtection: true)
            if status == errSecSuccess {
                store = .dataProtection
            } else if status == errSecMissingEntitlement {
                let fallback = Self.add(key, dataProtection: false)
                guard fallback == errSecSuccess else { throw .keychain(fallback) }
                store = .login
            } else {
                throw .keychain(status)
            }
        }
        let hint = LinearKeyHint(key: key, store: store)
        self.hint = hint
        if storage == .keychain { defaults.set(try? JSONEncoder().encode(hint), forKey: Self.hintKey) }
        return hint
    }

    func remove() {
        memoryKey = nil
        if storage == .keychain { deleteKeychainItems() }
        hint = nil
        defaults.removeObject(forKey: Self.hintKey)
    }

    private func deleteKeychainItems() {
        SecItemDelete(Self.query(dataProtection: true) as CFDictionary)
        SecItemDelete(Self.query(dataProtection: false) as CFDictionary)
    }

    private static func add(_ key: String, dataProtection: Bool) -> OSStatus {
        var attributes = query(dataProtection: dataProtection)
        attributes[kSecValueData] = Data(key.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel] = "Scout · Linear API key"
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func query(dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }
}
