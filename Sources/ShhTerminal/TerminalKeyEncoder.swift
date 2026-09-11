import Foundation

public enum ArrowDirection: String, Sendable, CaseIterable {
    case up, down, left, right
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public enum TerminalKey: Sendable, Hashable {
    case escape
    case tab(shift: Bool = false)
    case arrow(ArrowDirection, modifiers: KeyModifiers = [], applicationCursor: Bool = false)
    case emacsWordBack
    case emacsWordForward
    case ctrlC
    case ctrlD
    case control(Character)
    case meta(Character)
    case metaText(String)
    case functionKey(Int)
    case paste(String, bracketed: Bool)
    case raw(Data)
}

public enum TerminalKeyEncoder {
    public static let escapeByte: UInt8 = 0x1B
    public static let tabByte: UInt8 = 0x09
    public static let ctrlCByte: UInt8 = 0x03
    public static let ctrlDByte: UInt8 = 0x04

    public static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC [ 200 ~
    public static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC [ 201 ~

    public static func encode(_ key: TerminalKey) -> Data {
        switch key {
        case .escape:
            return escape()
        case .tab(let shift):
            return tab(shift: shift)
        case .arrow(let direction, let modifiers, let applicationCursor):
            return arrow(direction, modifiers: modifiers, applicationCursor: applicationCursor)
        case .emacsWordBack:
            return emacsWordBack()
        case .emacsWordForward:
            return emacsWordForward()
        case .ctrlC:
            return ctrlC()
        case .ctrlD:
            return ctrlD()
        case .control(let character):
            return control(character) ?? Data()
        case .meta(let character):
            return meta(character)
        case .metaText(let text):
            return meta(text)
        case .functionKey(let number):
            return functionKey(number) ?? Data()
        case .paste(let text, let bracketed):
            return encodePaste(text, bracketed: bracketed)
        case .raw(let data):
            return data
        }
    }

    public static func escape() -> Data {
        Data([escapeByte])
    }

    public static func tab(shift: Bool = false) -> Data {
        if shift {
            return Data([0x1B, 0x5B, 0x5A]) // ESC [ Z (BackTab)
        }
        return Data([tabByte])
    }

    public static func arrow(
        _ direction: ArrowDirection,
        modifiers: KeyModifiers = [],
        applicationCursor: Bool = false
    ) -> Data {
        let hasShift = modifiers.contains(.shift)
        let hasOption = modifiers.contains(.option)
        let hasControl = modifiers.contains(.control)

        let suffix: UInt8
        switch direction {
        case .up: suffix = 0x41    // 'A'
        case .down: suffix = 0x42  // 'B'
        case .right: suffix = 0x43 // 'C'
        case .left: suffix = 0x44  // 'D'
        }

        if hasShift || hasOption || hasControl {
            let modifierCode = 1 + (hasShift ? 1 : 0) + (hasOption ? 2 : 0) + (hasControl ? 4 : 0)
            let modByte = UInt8(ascii: "0") + UInt8(modifierCode)
            return Data([0x1B, 0x5B, 0x31, 0x3B, modByte, suffix]) // ESC [ 1 ; <mod> <dir>
        }

        if applicationCursor {
            return Data([0x1B, 0x4F, suffix]) // ESC O <dir>
        } else {
            return Data([0x1B, 0x5B, suffix]) // ESC [ <dir>
        }
    }

    public static func emacsWordBack() -> Data {
        Data([0x1B, 0x62]) // ESC b
    }

    public static func emacsWordForward() -> Data {
        Data([0x1B, 0x66]) // ESC f
    }

    public static func ctrlC() -> Data {
        Data([ctrlCByte])
    }

    public static func ctrlD() -> Data {
        Data([ctrlDByte])
    }

    public static func control(_ character: Character) -> Data? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return Data([ascii - UInt8(ascii: "a") + 1])
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return Data([ascii - UInt8(ascii: "A") + 1])
        case UInt8(ascii: "@"), UInt8(ascii: " "):
            return Data([0x00])
        case UInt8(ascii: "["):
            return Data([0x1B])
        case UInt8(ascii: "\\"):
            return Data([0x1C])
        case UInt8(ascii: "]"):
            return Data([0x1D])
        case UInt8(ascii: "^"):
            return Data([0x1E])
        case UInt8(ascii: "_"):
            return Data([0x1F])
        case UInt8(ascii: "?"):
            return Data([0x7F])
        default:
            return nil
        }
    }

    public static func meta(_ character: Character) -> Data {
        var data = Data([escapeByte])
        data.append(Data(String(character).utf8))
        return data
    }

    public static func meta(_ text: String) -> Data {
        var data = Data([escapeByte])
        data.append(Data(text.utf8))
        return data
    }

    public static func functionKey(_ number: Int) -> Data? {
        switch number {
        case 1:  return Data([0x1B, 0x4F, 0x50])                         // ESC O P
        case 2:  return Data([0x1B, 0x4F, 0x51])                         // ESC O Q
        case 3:  return Data([0x1B, 0x4F, 0x52])                         // ESC O R
        case 4:  return Data([0x1B, 0x4F, 0x53])                         // ESC O S
        case 5:  return Data([0x1B, 0x5B, 0x31, 0x35, 0x7E])             // ESC [ 15 ~
        case 6:  return Data([0x1B, 0x5B, 0x31, 0x37, 0x7E])             // ESC [ 17 ~
        case 7:  return Data([0x1B, 0x5B, 0x31, 0x38, 0x7E])             // ESC [ 18 ~
        case 8:  return Data([0x1B, 0x5B, 0x31, 0x39, 0x7E])             // ESC [ 19 ~
        case 9:  return Data([0x1B, 0x5B, 0x32, 0x30, 0x7E])             // ESC [ 20 ~
        case 10: return Data([0x1B, 0x5B, 0x32, 0x31, 0x7E])             // ESC [ 21 ~
        case 11: return Data([0x1B, 0x5B, 0x32, 0x33, 0x7E])             // ESC [ 23 ~
        case 12: return Data([0x1B, 0x5B, 0x32, 0x34, 0x7E])             // ESC [ 24 ~
        default: return nil
        }
    }

    public static func encodePaste(_ text: String, bracketed: Bool) -> Data {
        let payload = Data(text.utf8)
        if bracketed {
            var data = Data(bracketedPasteStart)
            data.append(payload)
            data.append(contentsOf: bracketedPasteEnd)
            return data
        } else {
            return payload
        }
    }
}
