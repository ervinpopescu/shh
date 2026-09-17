import Combine
import Foundation

/// Owns sticky accessory modifiers and applies them to text emitted by SwiftTerm.
///
/// SwiftTerm's delegate is the common path for both software and hardware keyboard
/// input. Keeping this state outside of the SwiftUI accessory view ensures that a
/// modifier tapped in the bar is visible when the keyboard emits its next byte.
public final class TerminalInputCoordinator: ObservableObject {
    @Published public private(set) var activeModifiers: KeyModifiers = []

    public init() {}

    public var isControlActive: Bool { activeModifiers.contains(.control) }
    public var isAltActive: Bool { activeModifiers.contains(.option) }
    public var isShiftActive: Bool { activeModifiers.contains(.shift) }

    public func toggleControl() { toggle(.control) }
    public func toggleAlt() { toggle(.option) }
    public func toggleShift() { toggle(.shift) }

    public func toggle(_ modifier: KeyModifiers) {
        guard modifier.isValidModifier else { return }
        if activeModifiers.contains(modifier) {
            activeModifiers.remove(modifier)
        } else {
            activeModifiers.insert(modifier)
        }
    }

    public func clear() {
        activeModifiers = []
    }

    /// Transforms one key emitted by SwiftTerm's keyboard delegate.
    ///
    /// Only a single ASCII byte is eligible for a sticky transformation. This is
    /// intentional: escape sequences, UTF-8, paste payloads, and IME composition
    /// must remain byte-for-byte intact rather than being transformed a byte at a
    /// time. A multi-byte value also leaves the sticky state available for the
    /// next actual key.
    public func processKeyboardInput(_ data: Data) -> Data {
        guard !activeModifiers.isEmpty else { return data }

        // SwiftTerm emits arrows, function keys, and hardware-keyboard actions as
        // complete ESC sequences. Preserve every byte and consume the sticky
        // state once, rather than leaving it armed for the next character.
        if data.count > 1, data.first == TerminalKeyEncoder.escapeByte {
            if !isBracketedPastePayload(data) {
                clear()
            }
            return data
        }

        guard data.count == 1, let byte = data.first, byte < 0x80 else {
            return data
        }

        let shifted = applyShift(to: byte)
        var output: Data
        if activeModifiers.contains(.control),
           let controlData = TerminalKeyEncoder.control(Character(UnicodeScalar(shifted))) {
            output = controlData
        } else {
            output = Data([shifted])
        }

        if activeModifiers.contains(.option) {
            output.insert(TerminalKeyEncoder.escapeByte, at: 0)
        }
        clear()
        return output
    }

    /// Encodes an accessory action while consuming sticky modifiers exactly once.
    /// Encoded terminal actions are passed through as complete sequences so a
    /// pending modifier cannot prepend or corrupt an escape sequence.
    public func encodeAccessory(_ key: TerminalKey) -> Data {
        let modifiers = activeModifiers
        guard !modifiers.isEmpty else { return TerminalKeyEncoder.encode(key) }

        let data: Data
        switch key {
        case .arrow(let direction, let keyModifiers, let applicationCursor):
            data = TerminalKeyEncoder.arrow(
                direction,
                modifiers: keyModifiers.union(modifiers),
                applicationCursor: applicationCursor
            )
        case .ctrlC, .ctrlD, .control:
            data = TerminalKeyEncoder.encode(key)
            if modifiers.contains(.option) {
                var prefixed = Data([TerminalKeyEncoder.escapeByte])
                prefixed.append(data)
                clear()
                return prefixed
            }
        case .paste:
            // Pasting is not a key and must never consume or transform a pending
            // modifier. The caller may subsequently cancel it explicitly.
            return TerminalKeyEncoder.encode(key)
        case .meta, .metaText:
            // These already include their own ESC prefix.
            data = TerminalKeyEncoder.encode(key)
        case .raw(let raw):
            guard raw.count == 1 else { return raw }
            clear()
            return raw
        default:
            // Escape, tab, function keys, and other complete encoded actions are
            // not safe to transform. Consume the sticky state, but send exactly
            // the sequence produced by TerminalKeyEncoder.
            data = TerminalKeyEncoder.encode(key)
        }

        clear()
        return data
    }

    public func encodeAccessoryText(_ text: String) -> Data {
        let data = Data(text.utf8)
        guard data.count == 1 else { return data }
        return processKeyboardInput(data)
    }

    private func isBracketedPastePayload(_ data: Data) -> Bool {
        let bytes = Array(data)
        let end = TerminalKeyEncoder.bracketedPasteEnd
        let hasEnd = bytes.count >= end.count && Array(bytes.suffix(end.count)) == end
        return bytes.starts(with: TerminalKeyEncoder.bracketedPasteStart)
            || bytes.starts(with: end)
            || hasEnd
    }

    private func applyShift(to byte: UInt8) -> UInt8 {
        guard activeModifiers.contains(.shift) else { return byte }
        switch byte {
        case 0x61...0x7A: return byte - 0x20 // a-z
        case 0x31: return 0x21 // 1 -> !
        case 0x32: return 0x40 // 2 -> @
        case 0x33: return 0x23 // 3 -> #
        case 0x34: return 0x24 // 4 -> $
        case 0x35: return 0x25 // 5 -> %
        case 0x36: return 0x5E // 6 -> ^
        case 0x37: return 0x26 // 7 -> &
        case 0x38: return 0x2A // 8 -> *
        case 0x39: return 0x28 // 9 -> (
        case 0x30: return 0x29 // 0 -> )
        case 0x2D: return 0x5F // - -> _
        case 0x3D: return 0x2B // = -> +
        case 0x5B: return 0x7B // [ -> {
        case 0x5D: return 0x7D // ] -> }
        case 0x5C: return 0x7C // \\ -> |
        case 0x3B: return 0x3A // ; -> :
        case 0x27: return 0x22 // ' -> "
        case 0x2C: return 0x3C // , -> <
        case 0x2E: return 0x3E // . -> >
        case 0x2F: return 0x3F // / -> ?
        default: return byte
        }
    }
}

private extension KeyModifiers {
    var isValidModifier: Bool {
        self == .shift || self == .option || self == .control
    }
}
