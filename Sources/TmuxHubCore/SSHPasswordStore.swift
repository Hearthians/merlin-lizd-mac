import Foundation
import LocalAuthentication
import Security

public enum SSHPasswordStoreError: LocalizedError, Equatable, Sendable {
    case invalidDestination
    case invalidPassword
    case authorizationRequired
    case passwordNotFound
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "SSH 目标无效。"
        case .invalidPassword:
            "密码不能为空，也不能包含换行或空字符。"
        case .authorizationRequired:
            "已存密码需要授权，请点击「授权使用已存密码」。后台不会自动弹出钥匙串窗口。"
        case .passwordNotFound:
            "未找到此主机的已存密码，请先保存 SSH 密码。"
        case let .keychain(status):
            if status == errSecUserCanceled {
                "已取消钥匙串授权，可稍后再次点击授权。"
            } else if let message = SecCopyErrorMessageString(status, nil) as String? {
                "无法访问 macOS 钥匙串：\(message)"
            } else {
                "无法访问 macOS 钥匙串（\(status)）。"
            }
        }
    }
}

/// Persists optional per-destination SSH passwords as generic-password items.
/// Private keys and SSH configuration remain owned by OpenSSH.
public final class SSHPasswordStore: @unchecked Sendable {
    public static let defaultService = "fun.gfyh.tmuxhub.ssh-password"

    private let service: String
    private let lock = NSLock()
    private let keychain: any SSHKeychainAccessing
    // Successful reads are reused only in this process, never persisted outside
    // Keychain. This also makes a one-time Allow useful for the current run.
    private var cachedPasswords: [String: String] = [:]

    public init(service: String = SSHPasswordStore.defaultService) {
        self.service = service
        keychain = SystemSSHKeychain()
    }

    init(service: String, keychain: any SSHKeychainAccessing) {
        self.service = service
        self.keychain = keychain
    }

    /// Background preparation may use an already accessible password, but it
    /// must never cause a system authorization dialog.
    public func password(for destination: String) throws -> String? {
        try readPassword(for: destination, allowInteraction: false)
    }

    /// Call only in response to the user's explicit authorization action.
    public func authorizePassword(for destination: String) throws {
        guard try readPassword(for: destination, allowInteraction: true) != nil else {
            throw SSHPasswordStoreError.passwordNotFound
        }
    }

    private func readPassword(for destination: String, allowInteraction: Bool) throws -> String? {
        try validate(destination: destination)
        return try lock.withLock {
            if let cached = cachedPasswords[destination] { return cached }
            var query = baseQuery(destination: destination)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = try keychain.copyMatching(query, allowInteraction: allowInteraction)
            if status == errSecItemNotFound { return nil }
            if !allowInteraction && (status == errSecInteractionNotAllowed || status == errSecAuthFailed) {
                throw SSHPasswordStoreError.authorizationRequired
            }
            guard status == errSecSuccess else {
                throw SSHPasswordStoreError.keychain(status)
            }
            guard let data = result as? Data,
                let password = String(data: data, encoding: .utf8)
            else {
                throw SSHPasswordStoreError.keychain(errSecDecode)
            }
            cachedPasswords[destination] = password
            return password
        }
    }

    public func containsPassword(for destination: String) throws -> Bool {
        try validate(destination: destination)
        return try lock.withLock {
            var query = baseQuery(destination: destination)
            // The host page needs metadata, not the protected password data.
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, _) = try keychain.copyMatching(query, allowInteraction: false)
            if status == errSecItemNotFound { return false }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                throw SSHPasswordStoreError.authorizationRequired
            }
            guard status == errSecSuccess else { throw SSHPasswordStoreError.keychain(status) }
            return true
        }
    }

    public func setPassword(
        _ password: String,
        for destination: String
    ) throws {
        try validate(destination: destination)
        guard !password.isEmpty,
            !password.contains("\0"),
            !password.contains(where: \.isNewline)
        else {
            throw SSHPasswordStoreError.invalidPassword
        }
        let data = Data(password.utf8)
        try lock.withLock {
            let query = baseQuery(destination: destination)
            let update = [kSecValueData as String: data]
            let updateStatus = try keychain.update(query, attributes: update)
            if updateStatus == errSecSuccess {
                cachedPasswords[destination] = password
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw SSHPasswordStoreError.keychain(updateStatus)
            }

            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = try keychain.add(item)
            guard addStatus == errSecSuccess else {
                throw SSHPasswordStoreError.keychain(addStatus)
            }
            cachedPasswords[destination] = password
        }
    }

    public func removePassword(for destination: String) throws {
        try validate(destination: destination)
        try lock.withLock {
            let status = try keychain.delete(baseQuery(destination: destination))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SSHPasswordStoreError.keychain(status)
            }
            cachedPasswords.removeValue(forKey: destination)
        }
    }

    private func baseQuery(destination: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: destination,
        ]
    }

    private func validate(destination: String) throws {
        guard IdentifierValidator.isSSHDestination(destination) else {
            throw SSHPasswordStoreError.invalidDestination
        }
    }
}

protocol SSHKeychainAccessing: Sendable {
    func copyMatching(_ query: [String: Any], allowInteraction: Bool) throws -> (OSStatus, CFTypeRef?)
    func update(_ query: [String: Any], attributes: [String: Any]) throws -> OSStatus
    func add(_ attributes: [String: Any]) throws -> OSStatus
    func delete(_ query: [String: Any]) throws -> OSStatus
}

private struct SystemSSHKeychain: SSHKeychainAccessing {
    func copyMatching(_ query: [String: Any], allowInteraction: Bool) throws -> (OSStatus, CFTypeRef?) {
        try SSHKeychainInteraction.perform(allowInteraction: allowInteraction) {
            var query = query
            if !allowInteraction {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) throws -> OSStatus {
        try SSHKeychainInteraction.perform(allowInteraction: true) {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    func add(_ attributes: [String: Any]) throws -> OSStatus {
        try SSHKeychainInteraction.perform(allowInteraction: true) {
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    func delete(_ query: [String: Any]) throws -> OSStatus {
        try SSHKeychainInteraction.perform(allowInteraction: true) {
            SecItemDelete(query as CFDictionary)
        }
    }
}

enum SSHKeychainInteraction {
    private static let lock = NSLock()

    /// These items live in the file-based login Keychain. Its legacy ACL
    /// prompts need the SecKeychain interaction policy, not just LAContext.
    /// Serialize *all* our Keychain calls because this policy is process-wide,
    /// and restore it even when the operation throws. Never change item ACLs.
    static func perform<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        try lock.withLock {
            var previous: DarwinBoolean = false
            let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
            guard readStatus == errSecSuccess else { throw SSHPasswordStoreError.keychain(readStatus) }
            let setStatus = SecKeychainSetUserInteractionAllowed(allowInteraction)
            guard setStatus == errSecSuccess else { throw SSHPasswordStoreError.keychain(setStatus) }
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return try operation()
        }
    }
}

public struct SSHPasswordAuthentication: Sendable {
    let password: String
    let askPassExecutable: String

    public init?(password: String, askPassExecutable: String) {
        guard !password.isEmpty,
            !password.contains("\0"),
            !password.contains(where: \.isNewline),
            askPassExecutable.hasPrefix("/"),
            !askPassExecutable.contains("\0")
        else { return nil }
        self.password = password
        self.askPassExecutable = askPassExecutable
    }
}

public typealias SSHPasswordProvider = @Sendable (String) ->
    SSHPasswordAuthentication?
