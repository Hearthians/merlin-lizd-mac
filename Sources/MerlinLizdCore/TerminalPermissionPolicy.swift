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
            context: TerminalApprovalContext(
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
    public let surface: TmuxSurface
    public let screen: TerminalApprovalScreenContext

    public init(
        surface: TmuxSurface,
        screen: TerminalApprovalScreenContext
    ) {
        self.surface = surface
        self.screen = screen
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
        let bounded = Self.boundedUTF8(
            snapshot.text,
            maximumByteCount: Self.maximumTextByteCount
        )
        text = bounded.text
        isTextTruncated = bounded.truncated
    }

    private static func boundedUTF8(
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
