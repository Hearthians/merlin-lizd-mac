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
        if let denialReason = classification.denialReason {
            return TerminalPermissionEvaluation(
                deterministicRisk: .high,
                effectiveRisk: .high,
                decision: .deny(reason: denialReason)
            )
        }
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

    private struct Classification {
        let risk: TerminalRisk
        let reason: String?
        let denialReason: String?

        static let routine = Classification(
            risk: .routine,
            reason: nil,
            denialReason: nil
        )
    }

    private struct EditableCommand {
        var characters: [Character]
        var cursor: Int
    }

    private struct LexedCommand {
        var segments: [[String]] = [[]]
        var hasOverwriteRedirection = false
        var isAmbiguous = false
    }

    private enum Quote {
        case single
        case double
    }

    private enum SubcommandResolution {
        case resolved(String?)
        case ambiguous
    }

    private func classify(
        batch: TerminalInputBatch,
        screen: TerminalScreenSnapshot
    ) -> Classification {
        let prompt = promptClassification(
            events: batch.events,
            screenText: screen.text
        )
        if let prompt, prompt.risk == .high {
            return prompt
        }
        guard var editable = editableCommand(from: screen) else {
            if let prompt {
                return prompt
            }
            if batch.events.allSatisfy(isNonMutatingNavigation) {
                return .routine
            }
            return Classification(
                risk: .high,
                reason: nil,
                denialReason: "The visible editable command could not be reconstructed safely"
            )
        }

        var result = classify(command: String(editable.characters))
        for event in batch.events {
            switch event {
            case let .text(text):
                if text.unicodeScalars.contains(where: { scalar in
                    (scalar.value < 0x20
                        && scalar.value != 0x0A
                        && scalar.value != 0x0D)
                        || scalar.value == 0x7F
                }) {
                    return Classification(
                        risk: .high,
                        reason: nil,
                        denialReason: "Text input contains terminal control bytes that cannot be reconstructed safely"
                    )
                }
                for character in text {
                    if character == "\n" || character == "\r" {
                        result = maxClassification(
                            result,
                            classify(command: String(editable.characters))
                        )
                        editable = EditableCommand(characters: [], cursor: 0)
                    } else {
                        editable.characters.insert(character, at: editable.cursor)
                        editable.cursor += 1
                    }
                }
            case let .key(.character(value), modifiers) where modifiers.isEmpty:
                for character in value {
                    editable.characters.insert(character, at: editable.cursor)
                    editable.cursor += 1
                }
            case .key(.backspace, modifiers: []):
                if editable.cursor > 0 {
                    editable.cursor -= 1
                    editable.characters.remove(at: editable.cursor)
                }
            case .key(.delete, modifiers: []):
                if editable.cursor < editable.characters.count {
                    editable.characters.remove(at: editable.cursor)
                }
            case .key(.left, modifiers: []):
                editable.cursor = max(0, editable.cursor - 1)
            case .key(.right, modifiers: []):
                editable.cursor = min(editable.characters.count, editable.cursor + 1)
            case .key(.home, modifiers: []):
                editable.cursor = 0
            case .key(.end, modifiers: []):
                editable.cursor = editable.characters.count
            case .key(.enter, modifiers: []):
                result = maxClassification(
                    result,
                    classify(command: String(editable.characters))
                )
                editable = EditableCommand(characters: [], cursor: 0)
            case .key(.escape, modifiers: []):
                continue
            default:
                return Classification(
                    risk: .high,
                    reason: nil,
                    denialReason: "The input can change command state in a way that cannot be reconstructed safely"
                )
            }
            result = maxClassification(
                result,
                classify(command: String(editable.characters))
            )
        }
        return result
    }

    private func editableCommand(
        from screen: TerminalScreenSnapshot
    ) -> EditableCommand? {
        guard screen.cursor.isVisible, screen.cursor.row >= 0,
            screen.cursor.column >= 0
        else { return nil }
        let rows = screen.text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard screen.cursor.row < rows.count else { return nil }
        var characters = Array(rows[screen.cursor.row])
        guard characters.allSatisfy({ character in
            character.unicodeScalars.count == 1
                && character.unicodeScalars.first?.isASCII == true
        }) else { return nil }
        while characters.count < screen.cursor.column {
            characters.append(" ")
        }
        let markers: [[Character]] = [Array("$ "), Array("% "), Array("# ")]
        var promptEnd: Int?
        for start in 0..<max(0, characters.count - 1) {
            for marker in markers where start + marker.count <= characters.count {
                if Array(characters[start..<(start + marker.count)]) == marker {
                    promptEnd = start + marker.count
                    break
                }
            }
            if promptEnd != nil { break }
        }
        guard let promptEnd, promptEnd <= screen.cursor.column else { return nil }
        return EditableCommand(
            characters: Array(characters.dropFirst(promptEnd)),
            cursor: screen.cursor.column - promptEnd
        )
    }

    private func isNonMutatingNavigation(_ event: TerminalInputEvent) -> Bool {
        switch event {
        case .key(.left, modifiers: []), .key(.right, modifiers: []),
            .key(.home, modifiers: []), .key(.end, modifiers: []),
            .key(.escape, modifiers: []), .key(.pageUp, modifiers: []),
            .key(.pageDown, modifiers: []):
            return true
        default:
            return false
        }
    }

    private func promptClassification(
        events: [TerminalInputEvent],
        screenText: String
    ) -> Classification? {
        let response = promptResponse(events)
        guard response != nil else { return nil }
        let prompt = screenText.lowercased()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(4)
            .joined(separator: " ")
        let passiveMarkers = [
            "press enter to continue", "hit enter to continue",
            "press return to continue",
        ]
        let destructiveMarkers = [
            "delete", "overwrite", "remove", "terminate", "erase",
            "destroy", "permanent", "all data", "kill", "revoke",
        ]
        let confirmationMarkers = [
            "[y/n]", "[y/n]?", "[y/n", "(y/n)", "yes/no",
            "are you sure", "confirm", "proceed?", "continue?",
            "[ok]", "ok/cancel", "[cancel]", "apply ",
        ]
        let isDestructive = destructiveMarkers.contains { prompt.contains($0) }
        let isConfirmation = isDestructive
            || confirmationMarkers.contains { prompt.contains($0) }
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        let isPassive = passiveMarkers.contains { prompt.contains($0) }

        if response == false, isConfirmation {
            return .routine
        }
        if response == true, isConfirmation {
            return Classification(
                risk: .high,
                reason: "The input accepts a confirmation prompt whose effect may be destructive",
                denialReason: nil
            )
        }
        if response == true, isPassive, !isDestructive {
            return .routine
        }
        return nil
    }

    private func promptResponse(_ events: [TerminalInputEvent]) -> Bool? {
        guard !events.isEmpty else { return nil }
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
            case .key(.escape, modifiers: []):
                return false
            default:
                return nil
            }
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["n", "no", "cancel"].contains(answer) { return false }
        if ["y", "yes", "ok"].contains(answer) { return true }
        return answer.isEmpty && hasEnter ? true : nil
    }

    private func classify(command: String) -> Classification {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .routine
        }
        let lexed = lex(command)
        if lexed.isAmbiguous {
            return Classification(
                risk: .high,
                reason: "The shell expression cannot be analyzed safely",
                denialReason: nil
            )
        }
        if lexed.hasOverwriteRedirection {
            return Classification(
                risk: .high,
                reason: "The command can overwrite file contents",
                denialReason: nil
            )
        }
        for segment in lexed.segments {
            let classification = classify(segment: segment)
            if classification.risk == .high { return classification }
        }
        return .routine
    }

    private func lex(_ command: String) -> LexedCommand {
        let characters = Array(command)
        var result = LexedCommand()
        var word = ""
        var quote: Quote?
        var index = 0

        func appendWord() {
            guard !word.isEmpty else { return }
            result.segments[result.segments.count - 1].append(word.lowercased())
            word = ""
        }
        func appendSeparator() {
            appendWord()
            if !result.segments[result.segments.count - 1].isEmpty {
                result.segments.append([])
            }
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if quote == .single {
                if character == "'" { quote = nil } else { word.append(character) }
                index += 1
                continue
            }
            if quote == .double {
                if character == "\"" {
                    quote = nil
                } else if character == "`"
                    || (character == "$" && ["(", "{"].contains(next))
                {
                    result.isAmbiguous = true
                    word.append(character)
                } else if character == "\\", let next {
                    word.append(next)
                    index += 1
                } else {
                    word.append(character)
                }
                index += 1
                continue
            }

            if character == "'" {
                quote = .single
            } else if character == "\"" {
                quote = .double
            } else if character == "`"
                || (character == "$" && ["(", "{"].contains(next))
                || ((character == "<" || character == ">") && next == "(")
            {
                result.isAmbiguous = true
                word.append(character)
            } else if character == "\\", let next {
                word.append(next)
                index += 1
            } else if character.isWhitespace {
                appendWord()
            } else if character == ";" || character == "|" || character == "&" {
                appendSeparator()
                if next == character { index += 1 }
            } else if character == ">" {
                if next == ">" {
                    appendWord()
                    index += 1
                } else if next == "&" {
                    if word.allSatisfy(\.isNumber) { word = "" }
                    appendWord()
                    index += 1
                    while index + 1 < characters.count,
                        characters[index + 1].isNumber
                    {
                        index += 1
                    }
                } else {
                    if word.allSatisfy(\.isNumber) { word = "" }
                    appendWord()
                    result.hasOverwriteRedirection = true
                }
            } else {
                word.append(character)
            }
            index += 1
        }
        appendWord()
        if quote != nil { result.isAmbiguous = true }
        if result.segments.last?.isEmpty == true { result.segments.removeLast() }
        return result
    }

    private func classify(segment originalWords: [String]) -> Classification {
        guard !originalWords.isEmpty else { return .routine }
        let resolved = resolveExecutable(originalWords)
        if resolved.isAmbiguous {
            return Classification(
                risk: .high,
                reason: "The command wrapper cannot be analyzed safely",
                denialReason: nil
            )
        }
        guard let executable = resolved.words.first else { return .routine }
        let arguments = Array(resolved.words.dropFirst())
        let name = executable.split(separator: "/").last.map(String.init) ?? executable

        if [
            "if", "then", "else", "elif", "fi", "for", "while", "until",
            "do", "done", "case", "esac", "function", "eval", "source", ".",
        ].contains(name) {
            return high("The shell expression cannot be analyzed safely")
        }
        if ["bash", "sh", "zsh", "fish", "dash", "ksh"].contains(name),
            arguments.contains(where: { argument in
                argument == "-c"
                    || (argument.hasPrefix("-")
                        && !argument.hasPrefix("--")
                        && argument.dropFirst().contains("c"))
            })
        {
            return high("The command invokes a shell expression")
        }
        if ["rm", "rmdir", "unlink", "truncate"].contains(name)
            || (name == "find" && arguments.contains("-delete"))
        {
            return high("The command can destructively delete data")
        }
        if name == "git" {
            switch gitSubcommand(arguments) {
            case .ambiguous:
                return high("The git invocation cannot be analyzed safely")
            case .resolved("push"):
                return high("git push changes a remote repository")
            case .resolved("clean"), .resolved("credential"):
                return high("The git command can destructively change state")
            case .resolved:
                break
            }
        }
        if ["dd", "fdisk", "gpt"].contains(name) || name.hasPrefix("mkfs") {
            return high("The command can modify or erase disk state")
        }
        if name == "diskutil" {
            let lowered = arguments.map { $0.lowercased() }
            if lowered.contains(where: { $0.hasPrefix("erase") || $0.hasPrefix("partition") })
                || lowered.containsSequence(["apfs", "delete"])
            {
                return high("The command can modify or erase disk state")
            }
        }
        if [
            "kill", "pkill", "killall", "shutdown", "reboot", "poweroff", "halt",
        ].contains(name) {
            return high("The command can terminate a process or terminal session")
        }
        if name == "tmux" {
            switch tmuxSubcommand(arguments) {
            case .ambiguous:
                return high("The tmux invocation cannot be analyzed safely")
            case let .resolved(subcommand?) where
                ["kill-session", "kill-server", "kill-pane"].contains(subcommand):
                return high("The command can terminate a terminal session")
            case .resolved:
                break
            }
        }
        if ["passwd", "chpasswd", "ssh-keygen", "security"].contains(name)
            || matches(arguments, after: name, pairs: [
                ("aws", "configure"), ("gcloud", "auth"), ("gh", "auth"),
                ("npm", "login"), ("docker", "login"),
            ])
        {
            return high("The command can change credentials or authentication state")
        }
        let benignForceConsumers = ["tail", "grep", "fgrep", "egrep"]
        if !benignForceConsumers.contains(name), arguments.contains(where: {
            $0 == "-f" || $0 == "--force" || $0.hasPrefix("--force=")
        }) {
            return high("The command contains a force flag")
        }
        return .routine
    }

    private func resolveExecutable(
        _ originalWords: [String]
    ) -> (words: [String], isAmbiguous: Bool) {
        var words = originalWords
        while let first = words.first {
            if first.contains("=") {
                words.removeFirst()
                continue
            }
            let wrapper = first.split(separator: "/").last.map(String.init) ?? first
            switch wrapper {
            case "sudo":
                words.removeFirst()
                guard consumeOptions(
                    in: &words,
                    flags: ["-A", "-b", "-E", "-H", "-K", "-k", "-n", "-S", "-V"],
                    valueOptions: [
                        "-C", "-D", "-g", "-h", "-p", "-R", "-r", "-T", "-t", "-U", "-u",
                        "--chdir", "--close-from", "--command-timeout", "--group", "--host",
                        "--prompt", "--role", "--type", "--user",
                    ]
                ) else { return (words, true) }
            case "command", "builtin":
                words.removeFirst()
                guard consumeOptions(
                    in: &words,
                    flags: ["-p", "-v", "-V"],
                    valueOptions: []
                ) else { return (words, true) }
            case "env":
                words.removeFirst()
                guard consumeOptions(
                    in: &words,
                    flags: ["-i", "--ignore-environment", "-0", "--null"],
                    valueOptions: ["-C", "--chdir", "-u", "--unset"]
                ) else { return (words, true) }
                while words.first?.contains("=") == true { words.removeFirst() }
            case "nohup":
                words.removeFirst()
            case "xargs":
                return (words, true)
            default:
                return (words, false)
            }
        }
        return (words, false)
    }

    private func consumeOptions(
        in words: inout [String],
        flags: Set<String>,
        valueOptions: Set<String>
    ) -> Bool {
        while let option = words.first, option.hasPrefix("-") {
            if option == "--" {
                words.removeFirst()
                return true
            }
            if flags.contains(option) {
                words.removeFirst()
                continue
            }
            if valueOptions.contains(option) {
                guard words.count >= 2 else { return false }
                words.removeFirst(2)
                continue
            }
            if valueOptions.contains(where: { option.hasPrefix($0 + "=") })
                || valueOptions.contains(where: {
                    $0.count == 2 && option.hasPrefix($0) && option.count > 2
                })
            {
                words.removeFirst()
                continue
            }
            return false
        }
        return true
    }

    private func gitSubcommand(
        _ arguments: [String]
    ) -> SubcommandResolution {
        var arguments = arguments
        let valueOptions: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]
        guard consumeOptions(
            in: &arguments,
            flags: ["--bare", "--no-pager", "--paginate", "--literal-pathspecs"],
            valueOptions: valueOptions
        ) else { return .ambiguous }
        return .resolved(arguments.first)
    }

    private func tmuxSubcommand(
        _ arguments: [String]
    ) -> SubcommandResolution {
        var arguments = arguments
        guard consumeOptions(
            in: &arguments,
            flags: ["-2", "-c", "-cc", "-d", "-u", "-v"],
            valueOptions: ["-f", "-l", "-s", "-t"]
        ) else { return .ambiguous }
        return .resolved(arguments.first)
    }

    private func matches(
        _ arguments: [String],
        after name: String,
        pairs: [(String, String)]
    ) -> Bool {
        pairs.contains { pair in
            name == pair.0 && arguments.first == pair.1
        }
    }

    private func maxClassification(
        _ lhs: Classification,
        _ rhs: Classification
    ) -> Classification {
        lhs.risk >= rhs.risk ? lhs : rhs
    }

    private func high(_ reason: String) -> Classification {
        Classification(risk: .high, reason: reason, denialReason: nil)
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard count >= sequence.count else { return false }
        for start in 0...(count - sequence.count) {
            if Array(self[start..<(start + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }
}
