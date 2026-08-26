import Foundation
import Security

public enum SSHPasswordStoreError: LocalizedError, Sendable {
    case invalidDestination
    case invalidPassword
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "SSH 目标无效。"
        case .invalidPassword:
            "密码不能为空，也不能包含换行或空字符。"
        case let .keychain(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
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

    public init(service: String = SSHPasswordStore.defaultService) {
        self.service = service
    }

    public func password(for destination: String) throws -> String? {
        try validate(destination: destination)
        return try lock.withLock {
            var result: CFTypeRef?
            var query = baseQuery(destination: destination)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw SSHPasswordStoreError.keychain(status)
            }
            guard let data = result as? Data,
                let password = String(data: data, encoding: .utf8)
            else {
                throw SSHPasswordStoreError.keychain(errSecDecode)
            }
            return password
        }
    }

    public func containsPassword(for destination: String) throws -> Bool {
        try password(for: destination) != nil
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
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                update as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else {
                throw SSHPasswordStoreError.keychain(updateStatus)
            }

            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SSHPasswordStoreError.keychain(addStatus)
            }
        }
    }

    public func removePassword(for destination: String) throws {
        try validate(destination: destination)
        try lock.withLock {
            let status = SecItemDelete(
                baseQuery(destination: destination) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SSHPasswordStoreError.keychain(status)
            }
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
