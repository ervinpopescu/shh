import Foundation

/// The semantic roots exposed by the Shh command dial. These identifiers are
/// intentionally stable so pinned actions can be persisted without storing
/// command text or other session data.
public enum DialCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case commonKeys = "common-keys"
    case snippets
    case voice
    case keyboard
    case multiplexer
    case sendImage = "send-image"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .commonKeys: return "Common Keys"
        case .snippets: return "Snippets"
        case .voice: return "Voice"
        case .keyboard: return "Keyboard"
        case .multiplexer: return "Multiplexer"
        case .sendImage: return "Send Image"
        }
    }
    public var systemImage: String {
        switch self {
        case .commonKeys: return "command"
        case .snippets: return "text.book.closed"
        case .voice: return "waveform"
        case .keyboard: return "keyboard"
        case .multiplexer: return "rectangle.3.group"
        case .sendImage: return "photo"
        }
    }
}

public enum DialCommonKey: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case escape, tab, shiftTab = "shift-tab", arrowUp = "arrow-up", arrowDown = "arrow-down"
    case arrowLeft = "arrow-left", arrowRight = "arrow-right", controlC = "control-c"
    case controlD = "control-d", enter

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .shiftTab: return "Shift-Tab"
        case .arrowUp: return "Up"
        case .arrowDown: return "Down"
        case .arrowLeft: return "Left"
        case .arrowRight: return "Right"
        case .controlC: return "Ctrl-C"
        case .controlD: return "Ctrl-D"
        case .enter: return "Enter"
        }
    }
    public var systemImage: String? {
        switch self {
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        default: return nil
        }
    }
}

public enum DialActionIdentifier: Hashable, Sendable {
    case category(DialCategory)
    case commonKey(DialCommonKey)
    case pinnedLiteral(String)
    case snippet(UUID)
    case voice
    case keyboard
    case multiplexer
    case multiplexerControl(MultiplexerControlAction)
    case sendImage
}

public enum DialActionAvailability: Equatable, Hashable, Sendable {
    case available
    case unavailable(reason: String)
    case reviewRequired
    case blocked(reason: String)
}

/// The compass direction resolved from a dial swipe. North and northwest are
/// the forward gestures used to open the next submenu; the other directions
/// remain available for gesture math and intentionally do not navigate.
public enum DialSwipeDirection: Equatable, Sendable {
    case north
    case northeast
    case east
    case southeast
    case south
    case southwest
    case west
    case northwest

    public var opensSubmenu: Bool {
        self == .north || self == .northwest
    }

    /// Resolves a sufficiently long translation into one of the eight compass
    /// sectors. A short or zero-length translation is not a swipe.
    public static func resolve(translation: CGSize, minimumDistance: CGFloat = 44) -> Self? {
        guard translation.width * translation.width + translation.height * translation.height >=
                minimumDistance * minimumDistance else { return nil }

        // atan2's positive y axis points down in UIKit, so invert y to make
        // north the conventional positive pi/2 direction.
        let angle = atan2(-translation.height, translation.width)
        let sector = Int(((angle + .pi / 8).truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi)
            .truncatingRemainder(dividingBy: 2 * .pi) / (.pi / 4))
        switch sector {
        case 0: return .east
        case 1: return .northeast
        case 2: return .north
        case 3: return .northwest
        case 4: return .west
        case 5: return .southwest
        case 6: return .south
        default: return .southeast
        }
    }
}

public struct DialNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String?
    public let action: DialActionIdentifier
    public let children: [DialNode]
    public let availability: DialActionAvailability

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        action: DialActionIdentifier,
        children: [DialNode] = [],
        availability: DialActionAvailability = .available
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.action = action
        self.children = children
        self.availability = availability
    }

    public var isEnabled: Bool {
        switch availability {
        case .available, .reviewRequired: return true
        case .unavailable, .blocked: return false
        }
    }
}

public struct DialSnippetDescriptor: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let preview: String
    public let availability: DialActionAvailability

    public init(id: UUID, name: String, preview: String, availability: DialActionAvailability = .available) {
        self.id = id
        self.name = name
        self.preview = preview
        self.availability = availability
    }
}

public struct CommandDialModel: Sendable {
    public let roots: [DialNode]

    public init(pinnedLiterals: [String] = [], snippets: [DialSnippetDescriptor] = [], connected: Bool = true,
                pinnedCategories: [DialCategory] = DialCategory.allCases,
                multiplexerChildren: [DialNode] = []) {
        let keys = DialCommonKey.allCases.map { key in
            DialNode(id: "key.\(key.id)", title: key.title, systemImage: key.systemImage,
                     action: .commonKey(key), availability: connected ? .available : .unavailable(reason: "Connect to a host"))
        }
        let literals = Self.validPinnedLiterals(pinnedLiterals).map { literal in
            let availability: DialActionAvailability
            switch CommandPolicy().classify(literal) {
            case .safe: availability = connected ? .available : .unavailable(reason: "Connect to a host")
            case .reviewRequired: availability = connected ? .reviewRequired : .unavailable(reason: "Connect to a host")
            case .blocked: availability = .blocked(reason: "Safety policy")
            }
            return DialNode(id: "literal.\(literal)", title: literal, systemImage: "text.cursor",
                            action: .pinnedLiteral(literal), availability: availability)
        }
        let snippetNodes = snippets.map { snippet in
            DialNode(id: "snippet.\(snippet.id.uuidString)", title: snippet.name, subtitle: snippet.preview,
                     systemImage: "text.quote", action: .snippet(snippet.id), availability: snippet.availability)
        }
        let allRoots = [
            DialNode(id: "root.\(DialCategory.commonKeys.rawValue)", title: DialCategory.commonKeys.title,
                     systemImage: DialCategory.commonKeys.systemImage, action: .category(.commonKeys), children: keys + literals,
                     availability: connected ? .available : .unavailable(reason: "Connect to a host")),
            DialNode(id: "root.\(DialCategory.snippets.rawValue)", title: DialCategory.snippets.title,
                     systemImage: DialCategory.snippets.systemImage, action: .category(.snippets), children: snippetNodes,
                     availability: connected ? .available : .unavailable(reason: "Connect to a host")),
            DialNode(id: "root.\(DialCategory.voice.rawValue)", title: DialCategory.voice.title,
                     systemImage: DialCategory.voice.systemImage, action: .voice,
                     availability: connected ? .available : .unavailable(reason: "Connect to a host")),
            DialNode(id: "root.\(DialCategory.keyboard.rawValue)", title: DialCategory.keyboard.title,
                     systemImage: DialCategory.keyboard.systemImage, action: .keyboard,
                     availability: .available),
            DialNode(id: "root.\(DialCategory.multiplexer.rawValue)", title: DialCategory.multiplexer.title,
                     systemImage: DialCategory.multiplexer.systemImage, action: .multiplexer,
                     children: multiplexerChildren,
                     availability: connected ? .available : .unavailable(reason: "Connect to a host")),
            DialNode(id: "root.\(DialCategory.sendImage.rawValue)", title: DialCategory.sendImage.title,
                     systemImage: DialCategory.sendImage.systemImage, action: .sendImage,
                     availability: connected ? .available : .unavailable(reason: "Connect to a host"))
        ]
        let pinned = Set(pinnedCategories)
        roots = allRoots.filter { node in
            let category: DialCategory?
            switch node.action {
            case .category(let value): category = value
            case .voice: category = .voice
            case .keyboard: category = .keyboard
            case .multiplexer: category = .multiplexer
            case .sendImage: category = .sendImage
            default: category = nil
            }
            return category.map(pinned.contains) ?? true
        }
    }

    public static func validPinnedLiterals(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let literal = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isInsertOnlyTerminalText(literal), seen.insert(literal).inserted else { return nil }
            return literal
        }.prefix(12).map { $0 }
    }

    /// Pinned values are terminal insertion text, never commands. In particular,
    /// a persisted value may not contain a line ending or any control byte.
    public static func isInsertOnlyTerminalText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
            !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}

public struct CommandDialNavigation: Equatable, Sendable {
    public private(set) var path: [String] = []
    public private(set) var selectedNodeID: String?
    public var isOpen: Bool

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public mutating func open() { isOpen = true; selectedNodeID = nil }
    public mutating func dismiss() { isOpen = false; path.removeAll(); selectedNodeID = nil }
    public mutating func clearSelection() { selectedNodeID = nil }
    public mutating func highlight(_ id: String?) { selectedNodeID = id }

    /// Browses a root category without dismissing the dial or requiring a
    /// category button to be reopened. The category remains selected while
    /// its children are shown below the category pager.
    public mutating func selectCategory(_ node: DialNode) {
        guard node.isEnabled else { return }
        path.removeAll()
        selectedNodeID = node.id
    }

    public mutating func back() {
        if !path.isEmpty { path.removeLast() }
        selectedNodeID = nil
    }

    public mutating func enter(_ node: DialNode) {
        guard node.isEnabled else { return }
        path.append(node.id)
        selectedNodeID = nil
    }

    /// Opens the next enabled child submenu in response to a forward swipe.
    /// The first swipe enters the selected root category, while subsequent
    /// swipes descend through nested child categories without executing a leaf.
    @discardableResult
    public mutating func openNextSubmenu(using direction: DialSwipeDirection,
                                         in model: CommandDialModel) -> DialNode? {
        guard isOpen, direction.opensSubmenu else { return nil }

        if path.isEmpty {
            let category = model.roots.first { $0.id == selectedNodeID && $0.isEnabled }
                ?? model.roots.first(where: \.isEnabled)
            guard let category else { return nil }
            enter(category)
            return category
        }

        guard let current = node(at: path, in: model.roots),
              let child = current.children.first(where: { $0.isEnabled && !$0.children.isEmpty }) else {
            return nil
        }
        enter(child)
        return child
    }

    private func node(at path: [String], in nodes: [DialNode]) -> DialNode? {
        guard let id = path.first, let current = nodes.first(where: { $0.id == id }) else { return nil }
        guard path.count > 1 else { return current }
        return node(at: Array(path.dropFirst()), in: current.children)
    }

    public var breadcrumb: String {
        path.isEmpty ? "Shh" : "Shh / " + path.joined(separator: " / ")
    }
}

public enum DialHapticEvent: Equatable, Sendable { case open, selection, commit, boundary, confirmation, success, failure }
public protocol DialHaptics: Sendable { func emit(_ event: DialHapticEvent) }
public struct NoopDialHaptics: DialHaptics {
    public init() {}
    public func emit(_ event: DialHapticEvent) {}
}

public enum CommandDialPlacement: String, CaseIterable, Codable, Sendable, Identifiable {
    case leading, trailing
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
public enum CommandDialSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact, regular
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
public struct CommandDialPreferences: Codable, Equatable, Sendable {
    public var placement: CommandDialPlacement
    public var size: CommandDialSize
    public var hapticsEnabled: Bool
    public var pinnedCategories: [DialCategory]
    public var pinnedLiterals: [String]
    public init(placement: CommandDialPlacement = .trailing, size: CommandDialSize = .compact,
                hapticsEnabled: Bool = true, pinnedCategories: [DialCategory] = DialCategory.allCases,
                pinnedLiterals: [String] = []) {
        self.placement = placement; self.size = size; self.hapticsEnabled = hapticsEnabled
        self.pinnedCategories = pinnedCategories; self.pinnedLiterals = CommandDialModel.validPinnedLiterals(pinnedLiterals)
    }

    private enum CodingKeys: String, CodingKey { case placement, size, hapticsEnabled, pinnedCategories, pinnedLiterals }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            placement: try values.decodeIfPresent(CommandDialPlacement.self, forKey: .placement) ?? .trailing,
            size: try values.decodeIfPresent(CommandDialSize.self, forKey: .size) ?? .compact,
            hapticsEnabled: try values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true,
            pinnedCategories: try values.decodeIfPresent([DialCategory].self, forKey: .pinnedCategories) ?? DialCategory.allCases,
            pinnedLiterals: try values.decodeIfPresent([String].self, forKey: .pinnedLiterals) ?? []
        )
    }
}
