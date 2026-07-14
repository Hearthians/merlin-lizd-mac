import Foundation

public enum TerminalInputEvent: Codable, Equatable, Sendable {
    case text(String)
    case key(TerminalKey, modifiers: TerminalKeyModifiers)
}

public enum TerminalKey: Codable, Equatable, Sendable {
    case character(String)
    case enter
    case escape
    case backspace
    case tab
    case up
    case down
    case right
    case left
    case home
    case end
    case insert
    case delete
    case pageUp
    case pageDown
    case function(Int)
}

public struct TerminalKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public static let shift = TerminalKeyModifiers(rawValue: 1 << 0)
    public static let control = TerminalKeyModifiers(rawValue: 1 << 1)
    public static let option = TerminalKeyModifiers(rawValue: 1 << 2)
    public static let command = TerminalKeyModifiers(rawValue: 1 << 3)

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public struct TerminalInputBatch: Codable, Equatable, Sendable {
    public let expectedRevision: UInt64
    public let events: [TerminalInputEvent]
    public let purpose: String
    public let declaredRisk: TerminalRisk

    public init(
        expectedRevision: UInt64,
        events: [TerminalInputEvent],
        purpose: String,
        declaredRisk: TerminalRisk
    ) {
        self.expectedRevision = expectedRevision
        self.events = events
        self.purpose = purpose
        self.declaredRisk = declaredRisk
    }
}

public enum TerminalRisk: Int, Codable, Comparable, Sendable {
    case observation
    case routine
    case high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TerminalInputEncodingError: Error, Equatable, Sendable {
    case invalidCharacterKey(String)
    case invalidControlCharacter(String)
    case invalidFunctionKey(Int)
    case unsupportedModifiers(
        key: TerminalKey,
        modifiers: TerminalKeyModifiers
    )
}

public enum TerminalInputEncoder {
    public static func encode(
        events: [TerminalInputEvent],
        keyboardMode: TerminalKeyboardMode
    ) throws -> Data {
        var bytes: [UInt8] = []
        for event in events {
            switch event {
            case let .text(text):
                bytes.append(contentsOf: text.utf8)
            case let .key(key, modifiers):
                bytes.append(
                    contentsOf: try encode(
                        key: key,
                        modifiers: modifiers,
                        keyboardMode: keyboardMode
                    )
                )
            }
        }
        return Data(bytes)
    }

    private static func encode(
        key: TerminalKey,
        modifiers: TerminalKeyModifiers,
        keyboardMode: TerminalKeyboardMode
    ) throws -> [UInt8] {
        let supported: TerminalKeyModifiers = [
            .shift,
            .control,
            .option,
            .command,
        ]
        guard modifiers.subtracting(supported).isEmpty,
            !modifiers.contains(.command)
        else {
            throw TerminalInputEncodingError.unsupportedModifiers(
                key: key,
                modifiers: modifiers
            )
        }

        var result: [UInt8] = []
        var xtermModifiers = modifiers
        if xtermModifiers.contains(.option) {
            result.append(0x1B)
            xtermModifiers.remove(.option)
        }

        if case let .character(value) = key {
            result.append(
                contentsOf: try encodeCharacter(
                    value,
                    key: key,
                    modifiers: xtermModifiers,
                    originalModifiers: modifiers
                )
            )
            return result
        }

        if case let .function(number) = key,
            !(1...12).contains(number)
        {
            throw TerminalInputEncodingError.invalidFunctionKey(number)
        }

        result.append(
            contentsOf: try encodeSpecialKey(
                key,
                modifiers: xtermModifiers,
                originalModifiers: modifiers,
                keyboardMode: keyboardMode
            ).utf8
        )
        return result
    }

    private static func encodeCharacter(
        _ value: String,
        key: TerminalKey,
        modifiers: TerminalKeyModifiers,
        originalModifiers: TerminalKeyModifiers
    ) throws -> [UInt8] {
        guard value.count == 1 else {
            throw TerminalInputEncodingError.invalidCharacterKey(value)
        }
        guard !modifiers.contains(.shift) else {
            throw TerminalInputEncodingError.unsupportedModifiers(
                key: key,
                modifiers: originalModifiers
            )
        }
        if modifiers.contains(.control) {
            let utf8 = Array(value.utf8)
            guard utf8.count == 1 else {
                throw TerminalInputEncodingError.invalidControlCharacter(value)
            }
            let ascii = utf8[0]
            let uppercased: UInt8
            switch ascii {
            case 65...90:
                uppercased = ascii
            case 97...122:
                uppercased = ascii - 32
            default:
                throw TerminalInputEncodingError.invalidControlCharacter(value)
            }
            return [uppercased - 64]
        }
        return Array(value.utf8)
    }

    private static func encodeSpecialKey(
        _ key: TerminalKey,
        modifiers: TerminalKeyModifiers,
        originalModifiers: TerminalKeyModifiers,
        keyboardMode: TerminalKeyboardMode
    ) throws -> String {
        switch key {
        case .enter, .escape, .backspace, .tab:
            guard modifiers.isEmpty else {
                throw TerminalInputEncodingError.unsupportedModifiers(
                    key: key,
                    modifiers: originalModifiers
                )
            }
            switch key {
            case .enter: return "\r"
            case .escape: return "\u{1B}"
            case .backspace: return "\u{7F}"
            case .tab: return "\t"
            default: preconditionFailure()
            }
        case .up, .down, .right, .left:
            let final: String
            switch key {
            case .up: final = "A"
            case .down: final = "B"
            case .right: final = "C"
            case .left: final = "D"
            default: preconditionFailure()
            }
            if modifiers.isEmpty {
                return keyboardMode == .applicationCursor
                    ? "\u{1B}O\(final)"
                    : "\u{1B}[\(final)"
            }
            return "\u{1B}[1;\(modifierParameter(modifiers))\(final)"
        case .home, .end:
            let final = key == .home ? "H" : "F"
            if modifiers.isEmpty {
                return keyboardMode == .applicationCursor
                    ? "\u{1B}O\(final)"
                    : "\u{1B}[\(final)"
            }
            return "\u{1B}[1;\(modifierParameter(modifiers))\(final)"
        case .insert, .delete, .pageUp, .pageDown:
            let number: Int
            switch key {
            case .insert: number = 2
            case .delete: number = 3
            case .pageUp: number = 5
            case .pageDown: number = 6
            default: preconditionFailure()
            }
            if modifiers.isEmpty {
                return "\u{1B}[\(number)~"
            }
            return "\u{1B}[\(number);\(modifierParameter(modifiers))~"
        case let .function(number):
            let code: String
            switch number {
            case 1: code = "P"
            case 2: code = "Q"
            case 3: code = "R"
            case 4: code = "S"
            case 5: code = "15~"
            case 6: code = "17~"
            case 7: code = "18~"
            case 8: code = "19~"
            case 9: code = "20~"
            case 10: code = "21~"
            case 11: code = "23~"
            case 12: code = "24~"
            default:
                throw TerminalInputEncodingError.invalidFunctionKey(number)
            }
            if modifiers.isEmpty {
                return number <= 4 ? "\u{1B}O\(code)" : "\u{1B}[\(code)"
            }
            if number <= 4 {
                return "\u{1B}[1;\(modifierParameter(modifiers))\(code)"
            }
            return "\u{1B}[\(code.dropLast());"
                + "\(modifierParameter(modifiers))~"
        case .character:
            preconditionFailure()
        }
    }

    private static func modifierParameter(
        _ modifiers: TerminalKeyModifiers
    ) -> Int {
        1
            + (modifiers.contains(.shift) ? 1 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
    }
}
