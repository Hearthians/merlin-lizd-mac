import CryptoKit
import Foundation

public enum TerminalPermissionDecision: Equatable, Sendable {
    case allow
    case requireApproval(TerminalApprovalRequest)
    case deny(reason: String)
}

public struct TerminalApprovalScope: Codable, Hashable, Sendable {
    public let payloadDigest: String
    public let endpointID: TerminalEndpointID
    public let screenRevision: UInt64

    public init(
        payloadDigest: String,
        endpointID: TerminalEndpointID,
        screenRevision: UInt64
    ) {
        self.payloadDigest = payloadDigest
        self.endpointID = endpointID
        self.screenRevision = screenRevision
    }

    public init(
        batch: TerminalInputBatch,
        endpointID: TerminalEndpointID,
        screenRevision: UInt64
    ) throws {
        let bytes = try Self.canonicalPayloadBytes(for: batch)
        self.init(
            payloadDigest: Self.sha256Hex(bytes),
            endpointID: endpointID,
            screenRevision: screenRevision
        )
    }

    public static func canonicalPayloadBytes(
        for batch: TerminalInputBatch
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(batch)
        } catch {
            throw TerminalApprovalCanonicalizationError.encodingFailed
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum TerminalApprovalCanonicalizationError: Error, Equatable, Sendable {
    case encodingFailed
}

public struct TerminalApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scope: TerminalApprovalScope
    public let batch: TerminalInputBatch
    public let reason: String

    public init(
        id: UUID = UUID(),
        scope: TerminalApprovalScope,
        batch: TerminalInputBatch,
        reason: String
    ) {
        self.id = id
        self.scope = scope
        self.batch = batch
        self.reason = reason
    }
}

public struct TerminalPermissionEvaluation: Equatable, Sendable {
    public let deterministicRisk: TerminalRisk
    public let effectiveRisk: TerminalRisk
    public let decision: TerminalPermissionDecision

    public init(
        deterministicRisk: TerminalRisk,
        effectiveRisk: TerminalRisk,
        decision: TerminalPermissionDecision
    ) {
        self.deterministicRisk = deterministicRisk
        self.effectiveRisk = effectiveRisk
        self.decision = decision
    }
}

public struct TerminalPermissionPolicy: Sendable {
    public static let maximumEventCount = 256
    public static let maximumEncodedByteCount = 32 * 1024
    public static let maximumPurposeScalarCount = 500

    public init() {}

    public func evaluate(
        batch: TerminalInputBatch,
        endpointID: TerminalEndpointID,
        screen: TerminalScreenSnapshot
    ) throws -> TerminalPermissionEvaluation {
        if let denialReason = validate(batch: batch, screen: screen) {
            return TerminalPermissionEvaluation(
                deterministicRisk: .high,
                effectiveRisk: .high,
                decision: .deny(reason: denialReason)
            )
        }

        let classification = classify(batch: batch, screen: screen)
        let effectiveRisk = max(batch.declaredRisk, classification.risk)
        let decision: TerminalPermissionDecision
        if effectiveRisk == .high {
            let scope = try TerminalApprovalScope(
                batch: batch,
                endpointID: endpointID,
                screenRevision: screen.revision
            )
            decision = .requireApproval(
                TerminalApprovalRequest(
                    scope: scope,
                    batch: batch,
                    reason: classification.reason
                        ?? "The agent declared this terminal mutation high risk"
                )
            )
        } else {
            decision = .allow
        }
        return TerminalPermissionEvaluation(
            deterministicRisk: classification.risk,
            effectiveRisk: effectiveRisk,
            decision: decision
        )
    }

    private func validate(
        batch: TerminalInputBatch,
        screen: TerminalScreenSnapshot
    ) -> String? {
        guard batch.expectedRevision == screen.revision else {
            return "Screen revision changed"
        }
        guard batch.events.count <= Self.maximumEventCount else {
            return "Input batch exceeds 256 semantic events"
        }
        guard batch.purpose.unicodeScalars.count <= Self.maximumPurposeScalarCount else {
            return "Input purpose exceeds 500 Unicode scalars"
        }
        do {
            let encoded = try TerminalInputEncoder.encode(
                events: batch.events,
                keyboardMode: screen.mode.keyboardMode
            )
            guard encoded.count <= Self.maximumEncodedByteCount else {
                return "Encoded input exceeds 32 KiB"
            }
        } catch {
            return "Input contains an unsupported semantic key combination"
        }
        return nil
    }

    private func classify(
        batch: TerminalInputBatch,
        screen: TerminalScreenSnapshot
    ) -> (risk: TerminalRisk, reason: String?) {
        if isAffirmativeInput(batch.events), isConfirmationPrompt(screen.text) {
            return (
                .high,
                "The input accepts a confirmation prompt whose effect may be destructive"
            )
        }

        let command = normalizedCommandText(batch.events)
        guard !command.isEmpty else { return (.routine, nil) }

        if isDestructiveDeletion(command) {
            return (.high, "The command can destructively delete data")
        }
        if containsOverwriteRedirection(command) {
            return (.high, "The command can overwrite file contents")
        }
        if isDiskMutation(command) {
            return (.high, "The command can modify or erase disk state")
        }
        if isProcessOrSessionTermination(command) {
            return (.high, "The command can terminate a process or terminal session")
        }
        if containsForceFlag(command) {
            return (.high, "The command contains a force flag")
        }
        if commandSegments(command).contains(where: {
            containsSequence(["git", "push"], in: executableWords($0))
        }) {
            return (.high, "git push changes a remote repository")
        }
        if changesCredentialsOrAuthentication(command) {
            return (.high, "The command can change credentials or authentication state")
        }
        return (.routine, nil)
    }

    private func normalizedCommandText(_ events: [TerminalInputEvent]) -> String {
        var text = ""
        for event in events {
            switch event {
            case let .text(value):
                text += value
            case let .key(.character(value), modifiers) where modifiers.isEmpty:
                text += value
            case .key(.enter, modifiers: []):
                text += "\n"
            default:
                continue
            }
        }
        return text.lowercased()
            .replacingOccurrences(of: "\n", with: " ; ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func isAffirmativeInput(_ events: [TerminalInputEvent]) -> Bool {
        guard !events.isEmpty else { return false }
        var text = ""
        var hasEnter = false
        for event in events {
            switch event {
            case let .text(value):
                text += value
            case let .key(.character(value), modifiers) where modifiers.isEmpty:
                text += value
            case .key(.enter, modifiers: []):
                hasEnter = true
            default:
                return false
            }
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return (answer.isEmpty && hasEnter)
            || answer == "y"
            || answer == "yes"
    }

    private func isConfirmationPrompt(_ text: String) -> Bool {
        let prompt = text.lowercased()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(4)
            .joined(separator: " ")
        if prompt.contains("press enter to continue")
            || prompt.contains("hit enter to continue")
            || prompt.contains("press return to continue")
        {
            return false
        }
        let markers = [
            "[y/n]", "[y/n]?", "(y/n)", "yes/no", "are you sure",
            "confirm", "proceed?", "continue?", "apply ", "delete ",
            "overwrite ", "remove ", "terminate ",
        ]
        return markers.contains { prompt.contains($0) }
    }

    private func isDestructiveDeletion(_ command: String) -> Bool {
        commandSegments(command).contains { segment in
            let words = executableWords(segment)
            return containsExecutable(
                in: words,
                names: ["rm", "rmdir", "unlink", "truncate"]
            )
                || containsSequence(["git", "clean"], in: words)
                || (containsExecutable(in: words, names: ["find"])
                    && words.contains("-delete"))
        }
    }

    private func isDiskMutation(_ command: String) -> Bool {
        commandSegments(command).contains { segment in
            let words = executableWords(segment)
            return containsExecutable(
                in: words,
                names: ["dd", "fdisk", "gpt"]
            )
                || words.contains(where: { $0.hasPrefix("mkfs") })
                || containsPrefixedPair(
                    first: "diskutil",
                    secondPrefixes: ["erase", "partition"],
                    in: words
                )
                || containsSequence(["diskutil", "apfs", "delete"], in: words)
        }
    }

    private func isProcessOrSessionTermination(_ command: String) -> Bool {
        commandSegments(command).contains { segment in
            let words = executableWords(segment)
            return containsExecutable(
                in: words,
                names: [
                    "kill", "pkill", "killall", "shutdown", "reboot",
                    "poweroff", "halt",
                ]
            )
                || containsSequence(["tmux", "kill-session"], in: words)
                || containsSequence(["tmux", "kill-server"], in: words)
                || containsSequence(["tmux", "kill-pane"], in: words)
                || containsSequence(["screen", "-x", "-s"], in: words)
        }
    }

    private func containsForceFlag(_ command: String) -> Bool {
        command.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" })
            .contains { token in
                token == "-f" || token == "--force"
                    || token.hasPrefix("--force=")
            }
    }

    private func changesCredentialsOrAuthentication(_ command: String) -> Bool {
        commandSegments(command).contains { segment in
            let words = executableWords(segment)
            return containsExecutable(
                in: words,
                names: ["passwd", "chpasswd", "ssh-keygen", "security"]
            )
                || containsSequence(["aws", "configure"], in: words)
                || containsSequence(["gcloud", "auth"], in: words)
                || containsSequence(["gh", "auth"], in: words)
                || containsSequence(["npm", "login"], in: words)
                || containsSequence(["docker", "login"], in: words)
                || containsSequence(["git", "credential"], in: words)
        }
    }

    private func containsOverwriteRedirection(_ command: String) -> Bool {
        let characters = Array(command)
        for index in characters.indices where characters[index] == ">" {
            let previous = index > characters.startIndex
                ? characters[characters.index(before: index)]
                : nil
            let nextIndex = characters.index(after: index)
            let next = nextIndex < characters.endIndex ? characters[nextIndex] : nil
            if previous != ">" && previous != "\\" && previous != "="
                && next != ">" && next != "="
            {
                return true
            }
        }
        return false
    }

    private func commandSegments(_ command: String) -> [String] {
        command
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .replacingOccurrences(of: "|", with: ";")
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func executableWords(_ segment: String) -> [String] {
        segment.split(whereSeparator: { $0.isWhitespace }).map { word in
            let value = String(word)
            return value.split(separator: "/").last.map(String.init) ?? value
        }
    }

    private func containsExecutable(
        in words: [String],
        names: Set<String>
    ) -> Bool {
        guard let first = words.first else { return false }
        if names.contains(first) { return true }
        return words.contains { names.contains($0) }
            && isCommandWrapper(first)
    }

    private func containsSequence(
        _ sequence: [String],
        in words: [String]
    ) -> Bool {
        guard !sequence.isEmpty, words.count >= sequence.count else {
            return false
        }
        if Array(words.prefix(sequence.count)) == sequence {
            return true
        }
        guard words.first.map(isCommandWrapper) == true else { return false }
        let lastStart = words.count - sequence.count
        guard lastStart >= 1 else { return false }
        for start in 1...lastStart {
            if Array(words[start..<(start + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }

    private func containsPrefixedPair(
        first: String,
        secondPrefixes: [String],
        in words: [String]
    ) -> Bool {
        guard words.count >= 2 else { return false }
        let starts = words[0] == first
            ? 0
            : (words.first.map(isCommandWrapper) == true ? 1 : words.count)
        guard starts < words.count else { return false }
        for index in starts..<(words.count - 1) where words[index] == first {
            if secondPrefixes.contains(where: { words[index + 1].hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    private func isCommandWrapper(_ word: String) -> Bool {
        ["sudo", "command", "builtin", "env", "nohup", "xargs"]
            .contains(word)
    }
}
