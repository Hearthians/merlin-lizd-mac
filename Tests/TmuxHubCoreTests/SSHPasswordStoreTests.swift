import Foundation
import Security
import Testing
@testable import TmuxHubCore

@Suite("SSH password authorization")
struct SSHPasswordStoreTests {
    @Test("host status queries metadata without requesting a secret or permission")
    func metadataOnly() throws {
        let backend = PasswordKeychainFixture(passwords: ["tiger8": "test-password"])
        let store = SSHPasswordStore(service: "test-service", keychain: backend)
        #expect(try store.containsPassword(for: "tiger8"))
        #expect(try !store.containsPassword(for: "missing"))
        #expect(backend.reads.count == 2)
        #expect(backend.reads.allSatisfy { !$0.requestsSecret && !$0.allowsInteraction })
        #expect(backend.reads.allSatisfy { $0.service == "test-service" })
    }

    @Test("background reads cannot request authorization, even after repeated failures")
    func backgroundNeverPrompts() throws {
        let backend = PasswordKeychainFixture(passwords: ["tiger8": "test-password"])
        let store = SSHPasswordStore(service: "test-service", keychain: backend)
        for _ in 0..<4 {
            #expect(throws: SSHPasswordStoreError.authorizationRequired) {
                try store.password(for: "tiger8")
            }
        }
        #expect(backend.reads.count == 4)
        #expect(backend.reads.allSatisfy { !$0.allowsInteraction })
        #expect(backend.mutationCount == 0)
        #expect(try store.containsPassword(for: "tiger8"))
    }

    @Test("explicit authorization is reused across reconnects for this process only")
    func authorizesOnce() throws {
        let backend = PasswordKeychainFixture(passwords: ["tiger8": "test-password"])
        let store = SSHPasswordStore(service: "test-service", keychain: backend)
        try store.authorizePassword(for: "tiger8")
        for _ in 0..<4 { #expect(try store.password(for: "tiger8") == "test-password") }
        #expect(backend.reads.count == 1)
        #expect(backend.reads.first?.allowsInteraction == true)

        let nextRun = SSHPasswordStore(service: "test-service", keychain: backend)
        #expect(throws: SSHPasswordStoreError.authorizationRequired) {
            try nextRun.password(for: "tiger8")
        }
        #expect(backend.reads.last?.allowsInteraction == false)
    }

    @Test("cancelling authorization preserves the saved entry and never retries with UI")
    func cancelledAuthorization() throws {
        let backend = PasswordKeychainFixture(passwords: ["tiger8": "test-password"], cancelAuthorization: true)
        let store = SSHPasswordStore(service: "test-service", keychain: backend)
        #expect(throws: SSHPasswordStoreError.keychain(errSecUserCanceled)) {
            try store.authorizePassword(for: "tiger8")
        }
        #expect(throws: SSHPasswordStoreError.authorizationRequired) { try store.password(for: "tiger8") }
        #expect(try store.containsPassword(for: "tiger8"))
        #expect(backend.reads.map(\.allowsInteraction) == [true, false, false])
        #expect(backend.mutationCount == 0)
    }

    @Test("saving and removing update the per-host cache without affecting other hosts")
    func cacheFollowsMutations() throws {
        let backend = PasswordKeychainFixture(passwords: ["tiger8": "old", "tiger9": "other"])
        let store = SSHPasswordStore(service: "test-service", keychain: backend)
        try store.authorizePassword(for: "tiger8")
        try store.authorizePassword(for: "tiger9")
        try store.setPassword("new", for: "tiger8")
        #expect(try store.password(for: "tiger8") == "new")
        try store.removePassword(for: "tiger8")
        #expect(try store.password(for: "tiger8") == nil)
        #expect(try !store.containsPassword(for: "tiger8"))
        #expect(try store.password(for: "tiger9") == "other")
        try store.setPassword("created", for: "new-host")
        #expect(try store.password(for: "new-host") == "created")
    }

    @Test("missing entries are reported without inventing authorization success")
    func absentPassword() throws {
        let backend = PasswordKeychainFixture(passwords: [:])
        let store = SSHPasswordStore(service: "test-service", keychain: backend)
        #expect(throws: SSHPasswordStoreError.passwordNotFound) { try store.authorizePassword(for: "missing") }
        #expect(try store.password(for: "missing") == nil)
    }

    @Test("legacy interaction is suppressed for silent operations and restored on success or failure")
    func restoresInteractionPolicy() throws {
        // Only inspects the policy in this test process; no Keychain entries
        // are read, written, or deleted, and no authentication is attempted.
        enum SimulatedFailure: Error { case failed }
        var original: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess)
        try SSHKeychainInteraction.perform(allowInteraction: false) {
            var current: DarwinBoolean = true
            #expect(SecKeychainGetUserInteractionAllowed(&current) == errSecSuccess)
            #expect(!current.boolValue)
        }
        var restored: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == original.boolValue)
        #expect(throws: SimulatedFailure.self) {
            try SSHKeychainInteraction.perform(allowInteraction: !original.boolValue) {
                throw SimulatedFailure.failed
            }
        }
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == original.boolValue)
    }
}

private final class PasswordKeychainFixture: SSHKeychainAccessing, @unchecked Sendable {
    struct Read {
        let service: String?
        let requestsSecret: Bool
        let allowsInteraction: Bool
    }

    private let lock = NSLock()
    private var passwords: [String: String]
    private var recordedReads: [Read] = []
    private var mutations = 0
    private let cancelAuthorization: Bool

    init(passwords: [String: String], cancelAuthorization: Bool = false) {
        self.passwords = passwords
        self.cancelAuthorization = cancelAuthorization
    }

    var reads: [Read] { lock.withLock { recordedReads } }
    var mutationCount: Int { lock.withLock { mutations } }

    func copyMatching(_ query: [String: Any], allowInteraction: Bool) throws -> (OSStatus, CFTypeRef?) {
        lock.withLock {
            let requestsSecret = query[kSecReturnData as String] as? Bool == true
            recordedReads.append(Read(service: query[kSecAttrService as String] as? String,
                                      requestsSecret: requestsSecret, allowsInteraction: allowInteraction))
            guard let account = query[kSecAttrAccount as String] as? String,
                let password = passwords[account]
            else { return (errSecItemNotFound, nil) }
            if !requestsSecret { return (errSecSuccess, [kSecAttrAccount as String: account] as CFDictionary) }
            if !allowInteraction { return (errSecInteractionNotAllowed, nil) }
            if cancelAuthorization { return (errSecUserCanceled, nil) }
            return (errSecSuccess, Data(password.utf8) as CFData)
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) throws -> OSStatus {
        lock.withLock {
            mutations += 1
            guard let account = query[kSecAttrAccount as String] as? String, passwords[account] != nil,
                let data = attributes[kSecValueData as String] as? Data
            else { return errSecItemNotFound }
            passwords[account] = String(data: data, encoding: .utf8)
            return errSecSuccess
        }
    }

    func add(_ attributes: [String: Any]) throws -> OSStatus {
        lock.withLock {
            mutations += 1
            guard let account = attributes[kSecAttrAccount as String] as? String,
                let data = attributes[kSecValueData as String] as? Data
            else { return errSecParam }
            passwords[account] = String(data: data, encoding: .utf8)
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) throws -> OSStatus {
        lock.withLock {
            mutations += 1
            if let account = query[kSecAttrAccount as String] as? String { passwords.removeValue(forKey: account) }
            return errSecSuccess
        }
    }
}
