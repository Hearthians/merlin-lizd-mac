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
    /// Immutable approval-time context. It is optional only so historical
    /// journal records written before context capture remain decodable.
    public let context: TerminalApprovalContext?

    public init(
        payloadDigest: String,
        endpointID: TerminalEndpointID,
        screenRevision: UInt64,
        context: TerminalApprovalContext? = nil
    ) {
        self.payloadDigest = payloadDigest
        self.endpointID = endpointID
        self.screenRevision = screenRevision
        self.context = context
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

    public init(
        batch: TerminalInputBatch,
        endpointID: TerminalEndpointID,
        screen: TerminalScreenSnapshot,
        surface: TmuxSurface
    ) throws {
        let bytes = try Self.canonicalPayloadBytes(for: batch)
        self.init(
            payloadDigest: Self.sha256Hex(bytes),
            endpointID: endpointID,
            screenRevision: screen.revision,
            context: try TerminalApprovalContext(
                surface: surface,
                screen: TerminalApprovalScreenContext(snapshot: screen)
            )
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

public struct TerminalApprovalContext: Codable, Equatable, Hashable, Sendable {
    public let surface: TerminalApprovalSurfaceContext
    public let screen: TerminalApprovalScreenContext

    public init(
        surface: TerminalApprovalSurfaceContext,
        screen: TerminalApprovalScreenContext
    ) {
        self.surface = surface
        self.screen = screen
    }

    public init(
        surface: TmuxSurface,
        screen: TerminalApprovalScreenContext
    ) throws {
        self.init(
            surface: try TerminalApprovalSurfaceContext(surface: surface),
            screen: screen
        )
    }
}

public struct TerminalApprovalSurfaceContext:
    Codable, Equatable, Hashable, Sendable
{
    public static let maximumIdentifierByteCount = 64
    public static let maximumCurrentCommandByteCount = 512

    public let sessionIdentity: TmuxSessionIdentity
    public let windowID: String
    public let paneID: String
    public let currentCommand: String
    public let isCurrentCommandTruncated: Bool

    public init(surface: TmuxSurface) throws {
        guard Self.hasValidLocation(
            sessionIdentity: surface.sessionIdentity,
            windowID: surface.windowID,
            paneID: surface.paneID
        ) else {
            throw TerminalApprovalCanonicalizationError.invalidContext
        }
        let bounded = TerminalApprovalUTF8.bounded(
            surface.currentCommand,
            maximumByteCount: Self.maximumCurrentCommandByteCount
        )
        sessionIdentity = surface.sessionIdentity
        windowID = surface.windowID
        paneID = surface.paneID
        currentCommand = bounded.text
        isCurrentCommandTruncated = bounded.truncated
    }

    public func matchesLocation(of surface: TmuxSurface) -> Bool {
        sessionIdentity == surface.sessionIdentity
            && windowID == surface.windowID
            && paneID == surface.paneID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionIdentity
        case windowID
        case paneID
        case currentCommand
        case isCurrentCommandTruncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionIdentity = try container.decode(
            TmuxSessionIdentity.self,
            forKey: .sessionIdentity
        )
        let windowID = try container.decode(String.self, forKey: .windowID)
        let paneID = try container.decode(String.self, forKey: .paneID)
        let currentCommand = try container.decode(
            String.self,
            forKey: .currentCommand
        )
        let isTruncated = try container.decodeIfPresent(
            Bool.self,
            forKey: .isCurrentCommandTruncated
        ) ?? false
        guard Self.hasValidLocation(
            sessionIdentity: sessionIdentity,
            windowID: windowID,
            paneID: paneID
        ), currentCommand.utf8.count <= Self.maximumCurrentCommandByteCount
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid terminal approval surface context"
                )
            )
        }
        self.sessionIdentity = sessionIdentity
        self.windowID = windowID
        self.paneID = paneID
        self.currentCommand = currentCommand
        isCurrentCommandTruncated = isTruncated
    }

    private static func hasValidLocation(
        sessionIdentity: TmuxSessionIdentity,
        windowID: String,
        paneID: String
    ) -> Bool {
        isValidPersistedIdentifier(
            sessionIdentity.serverSessionID,
            prefix: 0x24
        )
            && isValidPersistedIdentifier(windowID, prefix: 0x40)
            && isValidPersistedIdentifier(paneID, prefix: 0x25)
    }

    /// Surface IDs are already obtained through the stricter tmux parser in
    /// production. The approval projection additionally enforces a bounded,
    /// display-safe opaque representation without narrowing the domain type to
    /// today's numeric tmux spelling.
    private static func isValidPersistedIdentifier(
        _ value: String,
        prefix: UInt8
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard (2...maximumIdentifierByteCount).contains(bytes.count),
            bytes[0] == prefix
        else { return false }
        return bytes.dropFirst().allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x5F
        }
    }
}

public struct TerminalApprovalScreenContext:
    Codable, Equatable, Hashable, Sendable
{
    public static let maximumTextByteCount = 8 * 1024

    public let revision: UInt64
    public let columns: Int
    public let rows: Int
    public let cursor: TerminalCursor
    public let mode: TerminalScreenMode
    public let text: String
    public let isTextTruncated: Bool

    public init(snapshot: TerminalScreenSnapshot) {
        revision = snapshot.revision
        columns = snapshot.columns
        rows = snapshot.rows
        cursor = snapshot.cursor
        mode = snapshot.mode
        let bounded = TerminalApprovalUTF8.bounded(
            snapshot.text,
            maximumByteCount: Self.maximumTextByteCount
        )
        text = bounded.text
        isTextTruncated = bounded.truncated
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case columns
        case rows
        case cursor
        case mode
        case text
        case isTextTruncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        columns = try container.decode(Int.self, forKey: .columns)
        rows = try container.decode(Int.self, forKey: .rows)
        cursor = try container.decode(TerminalCursor.self, forKey: .cursor)
        mode = try container.decode(TerminalScreenMode.self, forKey: .mode)
        text = try container.decode(String.self, forKey: .text)
        isTextTruncated = try container.decode(
            Bool.self,
            forKey: .isTextTruncated
        )
        guard text.utf8.count <= Self.maximumTextByteCount else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Terminal approval screen text exceeds its byte limit"
                )
            )
        }
    }
}

public enum TerminalApprovalCanonicalizationError: Error, Equatable, Sendable {
    case encodingFailed
    case invalidContext
}

private enum TerminalApprovalUTF8 {
    static func bounded(
        _ value: String,
        maximumByteCount: Int
    ) -> (text: String, truncated: Bool) {
        let data = Data(value.utf8)
        guard data.count > maximumByteCount else { return (value, false) }
        var end = maximumByteCount
        while end > 0 {
            if let text = String(data: data.prefix(end), encoding: .utf8) {
                return (text, true)
            }
            end -= 1
        }
        return ("", true)
    }
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
        screen: TerminalScreenSnapshot,
        surface: TmuxSurface? = nil
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
            if let surface {
                let scope = try TerminalApprovalScope(
                    batch: batch,
                    endpointID: endpointID,
                    screen: screen,
                    surface: surface
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
                decision = .deny(reason: "Verified tmux surface unavailable")
            }
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
        for event in batch.events {
            if let reason = validateRawEvent(event) {
                return reason
            }
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

    private func validateRawEvent(_ event: TerminalInputEvent) -> String? {
        switch event {
        case let .text(value):
            if !value.allSatisfy(isPrintableTextGrapheme) {
                return "Text input must contain only printable grapheme clusters or submission boundaries"
            }
        case let .key(.character(value), _):
            guard value.count == 1,
                value.unicodeScalars.count == 1,
                let grapheme = value.first,
                let scalar = value.unicodeScalars.first,
                !isSubmissionBoundaryScalar(scalar),
                isPrintableTextGrapheme(grapheme)
            else {
                return "Character input must contain exactly one printable Unicode scalar"
            }
        case .key:
            break
        }
        return nil
    }

    private func isPrintableTextGrapheme(_ grapheme: Character) -> Bool {
        let scalars = Array(grapheme.unicodeScalars)
        if scalars.allSatisfy(isSubmissionBoundaryScalar) {
            return true
        }
        if scalars.contains(where: isEmojiSequenceSyntax) {
            return isPrintableEmojiSequence(scalars)
        }

        var hasVisibleBase = false
        var hasSpace = false
        var hasMark = false

        for scalar in scalars {
            if scalar.properties.isDefaultIgnorableCodePoint {
                return false
            }
            if isVisibleTextBaseScalar(scalar) {
                hasVisibleBase = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .spaceSeparator:
                hasSpace = true
            case .nonspacingMark, .spacingMark, .enclosingMark:
                hasMark = true
            default:
                return false
            }
        }

        return hasVisibleBase || (hasSpace && !hasMark)
    }

    private enum EmojiSequenceState {
        case component
        case separatorOrEnd
    }

    private func isPrintableEmojiSequence(
        _ scalars: [Unicode.Scalar]
    ) -> Bool {
        if scalars.contains(where: isRegionalIndicator) {
            return scalars.count == 2
                && scalars.allSatisfy(isRegionalIndicator)
        }
        if isKeycapSequence(scalars) { return true }

        var index = 0
        var state = EmojiSequenceState.component
        while index < scalars.count {
            switch state {
            case .component:
                guard let nextIndex = nextIndexAfterEmojiComponent(
                    at: index,
                    in: scalars
                ) else { return false }
                index = nextIndex
                state = .separatorOrEnd
            case .separatorOrEnd:
                guard scalars[index].value == 0x200D else { return false }
                index += 1
                state = .component
            }
        }
        return switch state {
        case .component: false
        case .separatorOrEnd: true
        }
    }

    private func nextIndexAfterEmojiComponent(
        at index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Int? {
        guard index < scalars.count,
            isEmojiSequenceBase(scalars[index])
        else { return nil }
        let base = scalars[index]
        var nextIndex = index + 1
        var hasVariationSelector = false
        if nextIndex < scalars.count,
            isEmojiVariationSelector(scalars[nextIndex])
        {
            hasVariationSelector = true
            nextIndex += 1
        }
        if nextIndex < scalars.count,
            scalars[nextIndex].properties.isEmojiModifier
        {
            guard !hasVariationSelector,
                base.properties.isEmojiModifierBase
            else { return nil }
            nextIndex += 1
        }
        return nextIndex
    }

    private func isEmojiSequenceSyntax(_ scalar: Unicode.Scalar) -> Bool {
        isEmojiVariationSelector(scalar)
            || scalar.value == 0x200D
            || scalar.value == 0x20E3
            || scalar.properties.isEmojiModifier
            || isRegionalIndicator(scalar)
    }

    private func isEmojiSequenceBase(_ scalar: Unicode.Scalar) -> Bool {
        isVisibleTextBaseScalar(scalar)
            && scalar.properties.isEmoji
            && !scalar.properties.isEmojiModifier
            && !isRegionalIndicator(scalar)
    }

    private func isKeycapSequence(_ scalars: [Unicode.Scalar]) -> Bool {
        guard let base = scalars.first, isKeycapBase(base) else { return false }
        if scalars.count == 2 {
            return scalars[1].value == 0x20E3
        }
        return scalars.count == 3
            && scalars[1].value == 0xFE0F
            && scalars[2].value == 0x20E3
    }

    private func isKeycapBase(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x23 || scalar.value == 0x2A
            || (0x30...0x39).contains(scalar.value)
    }

    private func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    private func isSubmissionBoundaryScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x0A || scalar.value == 0x0D
    }

    private func isEmojiVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0xFE0E || scalar.value == 0xFE0F
    }

    private func isVisibleTextBaseScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
            .modifierLetter, .otherLetter, .decimalNumber, .letterNumber,
            .otherNumber, .connectorPunctuation, .dashPunctuation,
            .openPunctuation, .closePunctuation, .initialPunctuation,
            .finalPunctuation, .otherPunctuation, .mathSymbol,
            .currencySymbol, .modifierSymbol, .otherSymbol:
            true
        default:
            false
        }
    }

    private struct Classification {
        let risk: TerminalRisk
        let reason: String?
    }

    private func classify(
        batch: TerminalInputBatch,
        screen: TerminalScreenSnapshot
    ) -> Classification {
        guard !batch.events.isEmpty else {
            return Classification(risk: .observation, reason: nil)
        }

        for event in batch.events {
            if isUnmodifiedNavigation(event) {
                continue
            }
            if screen.mode.isAlternateScreen {
                return Classification(
                    risk: .high,
                    reason: "Alternate-screen actions require explicit approval"
                )
            }
            if isRoutineNormalScreenEvent(event) {
                continue
            }
            return Classification(
                risk: .high,
                reason: "The input contains an execution or action boundary"
            )
        }

        return Classification(risk: .routine, reason: nil)
    }

    private func isUnmodifiedNavigation(_ event: TerminalInputEvent) -> Bool {
        switch event {
        case .key(.up, modifiers: []), .key(.down, modifiers: []),
            .key(.left, modifiers: []), .key(.right, modifiers: []),
            .key(.home, modifiers: []), .key(.end, modifiers: []),
            .key(.pageUp, modifiers: []), .key(.pageDown, modifiers: []):
            true
        default:
            false
        }
    }

    private func isRoutineNormalScreenEvent(_ event: TerminalInputEvent) -> Bool {
        switch event {
        case let .text(value):
            !value.unicodeScalars.contains { scalar in
                scalar.value == 0x0A || scalar.value == 0x0D
            }
        case .key(.character, modifiers: []),
            .key(.backspace, modifiers: []),
            .key(.delete, modifiers: []):
            true
        default:
            false
        }
    }
}
