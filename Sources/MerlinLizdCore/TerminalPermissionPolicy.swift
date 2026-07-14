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
            guard value.unicodeScalars.count == 1,
                let scalar = value.unicodeScalars.first,
                isPrintableCharacterKeyScalar(scalar)
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

        var hasVisibleBase = false
        var hasSpace = false
        var hasMark = false
        var hasEmojiVariationSelector = false
        var joinerIndices: [Int] = []

        for (index, scalar) in scalars.enumerated() {
            if isEmojiVariationSelector(scalar) {
                hasEmojiVariationSelector = true
                continue
            }
            if scalar.value == 0x200D {
                joinerIndices.append(index)
                continue
            }
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

        guard hasVisibleBase || (hasSpace && !hasMark) else { return false }
        if hasMark, !hasVisibleBase { return false }
        if hasEmojiVariationSelector,
            !scalars.contains(where: isEmojiTextBaseScalar)
        {
            return false
        }
        return joinerIndices.allSatisfy { index in
            hasEmojiTextBase(before: index, in: scalars)
                && hasEmojiTextBase(after: index, in: scalars)
        }
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

    private func isEmojiTextBaseScalar(_ scalar: Unicode.Scalar) -> Bool {
        isVisibleTextBaseScalar(scalar) && scalar.properties.isEmoji
    }

    private func hasEmojiTextBase(
        before index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        scalars[..<index].last(where: isVisibleTextBaseScalar)
            .map(isEmojiTextBaseScalar) ?? false
    }

    private func hasEmojiTextBase(
        after index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        scalars[(index + 1)...].first(where: isVisibleTextBaseScalar)
            .map(isEmojiTextBaseScalar) ?? false
    }

    private func isForbiddenRawTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0D, 0x0A:
            false
        case 0x00...0x1F, 0x7F...0x9F:
            true
        default:
            false
        }
    }

    private func isPrintableCharacterKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isForbiddenRawTextScalar(scalar) || scalar.value == 0x0A
            || scalar.value == 0x0D
        {
            return false
        }
        return switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator,
            .surrogate, .nonspacingMark, .spacingMark, .enclosingMark,
            .unassigned:
            false
        default:
            true
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
