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
        case .commonKeys: return "Input"
        case .snippets: return "Saved"
        case .voice: return "Voice"
        case .keyboard: return "Keyboard"
        case .multiplexer: return "Session"
        case .sendImage: return "Share"
        }
    }

    public var systemImage: String {
        switch self {
        case .commonKeys: return "terminal"
        case .snippets: return "text.book.closed"
        case .voice: return "waveform"
        case .keyboard: return "keyboard"
        case .multiplexer: return "rectangle.3.group"
        case .sendImage: return "square.and.arrow.up"
        }
    }
}

public enum DialCommonKey: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case escape, tab
    case shiftTab = "shift-tab"
    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case controlC = "control-c"
    case controlD = "control-d"
    case enter

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
        case .enter: return "Return"
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

public struct DialNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String?
    public let action: DialActionIdentifier
    public let children: [DialNode]
    public let availability: DialActionAvailability

    public init(
        id: String, title: String, subtitle: String? = nil, systemImage: String? = nil,
        action: DialActionIdentifier, children: [DialNode] = [],
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

    /// The spoken label used by the radial button and other non-visual clients.
    public var accessibilityLabel: String {
        switch availability {
        case .available: return title
        case .reviewRequired: return "\(title), approval required"
        case .blocked(let reason): return "\(title), blocked: \(reason)"
        case .unavailable(let reason): return "\(title), unavailable: \(reason)"
        }
    }
}

public struct DialSnippetDescriptor: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let preview: String
    public let availability: DialActionAvailability

    public init(
        id: UUID, name: String, preview: String,
        availability: DialActionAvailability = .available
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.availability = availability
    }
}

public struct CommandDialModel: Sendable {
    public let roots: [DialNode]

    public init(
        pinnedLiterals: [String] = [], snippets: [DialSnippetDescriptor] = [],
        connected: Bool = true,
        pinnedCategories: [DialCategory] = DialCategory.allCases,
        multiplexerChildren: [DialNode] = []
    ) {
        let availability: DialActionAvailability =
            connected
            ? .available : .unavailable(reason: "Connect to a host")
        roots = Self.makeRoots(
            pinnedLiterals: pinnedLiterals,
            snippets: snippets,
            categories: Set(pinnedCategories),
            availability: availability,
            connected: connected,
            multiplexerChildren: multiplexerChildren
        )
    }

    private static func makeRoots(
        pinnedLiterals: [String], snippets: [DialSnippetDescriptor],
        categories: Set<DialCategory>, availability: DialActionAvailability,
        connected: Bool, multiplexerChildren: [DialNode]
    ) -> [DialNode] {
        let input = inputNodes(categories: categories, availability: availability)
        let literals = literalNodes(
            values: pinnedLiterals, connected: connected, availability: availability)
        let saved = savedNodes(
            snippets: snippets, literals: literals, categories: categories,
            availability: availability)
        var roots: [DialNode] = []

        if !input.isEmpty {
            roots.append(
                DialNode(
                    id: "root.input", title: "Input", subtitle: "Type, dictate, or navigate",
                    systemImage: DialCategory.commonKeys.systemImage,
                    action: .category(.commonKeys), children: input,
                    availability: input.contains(where: \.isEnabled) ? .available : availability))
        }
        if categories.contains(.multiplexer) {
            roots.append(sessionRoot(children: multiplexerChildren, availability: availability))
        }
        if categories.contains(.snippets) || !literals.isEmpty {
            roots.append(
                DialNode(
                    id: "root.saved", title: "Saved", subtitle: "Snippets and quick text",
                    systemImage: DialCategory.snippets.systemImage, action: .category(.snippets),
                    children: saved,
                    availability: saved.contains(where: \.isEnabled)
                        ? .available
                        : (saved.isEmpty
                            ? .unavailable(reason: "No saved commands") : availability)))
        }
        if categories.contains(.sendImage) {
            roots.append(
                DialNode(
                    id: "root.share", title: "Share", subtitle: "Send an image to this host",
                    systemImage: DialCategory.sendImage.systemImage, action: .category(.sendImage),
                    children: [
                        DialNode(
                            id: "share.image", title: "Image",
                            subtitle: "Send a file to the terminal",
                            systemImage: "photo", action: .sendImage, availability: availability
                        )
                    ], availability: availability))
        }
        return roots
    }

    private static func inputNodes(
        categories: Set<DialCategory>, availability: DialActionAvailability
    ) -> [DialNode] {
        var nodes: [DialNode] = []
        if categories.contains(.commonKeys) {
            let keys = Dictionary(
                uniqueKeysWithValues: DialCommonKey.allCases.map { key in
                    (
                        key,
                        DialNode(
                            id: "key.\(key.id)", title: key.title, systemImage: key.systemImage,
                            action: .commonKey(key), availability: availability)
                    )
                })
            func keyNodes(_ values: [DialCommonKey]) -> [DialNode] {
                values.compactMap { keys[$0] }
            }
            nodes.append(
                DialNode(
                    id: "input.navigate", title: "Navigate",
                    subtitle: "Move, complete, and control terminal input",
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                    action: .category(.commonKeys),
                    children: [
                        DialNode(
                            id: "input.navigate.cursor", title: "Cursor",
                            systemImage: "cursorarrow.motionlines", action: .category(.commonKeys),
                            children: keyNodes([.arrowUp, .arrowRight, .arrowDown, .arrowLeft]),
                            availability: availability),
                        DialNode(
                            id: "input.navigate.complete", title: "Complete",
                            systemImage: "arrow.right.to.line.compact",
                            action: .category(.commonKeys),
                            children: keyNodes([.tab, .shiftTab]), availability: availability),
                        DialNode(
                            id: "input.navigate.control", title: "Control",
                            systemImage: "terminal", action: .category(.commonKeys),
                            children: keyNodes([.enter, .escape, .controlC, .controlD]),
                            availability: availability),
                    ], availability: availability))
        }
        if categories.contains(.keyboard) {
            nodes.append(
                DialNode(
                    id: "input.keyboard", title: "Keyboard", subtitle: "Return to typing",
                    systemImage: DialCategory.keyboard.systemImage, action: .keyboard))
        }
        if categories.contains(.voice) {
            nodes.append(
                DialNode(
                    id: "input.dictate", title: "Voice", subtitle: "Compose with your voice",
                    systemImage: DialCategory.voice.systemImage, action: .voice,
                    availability: availability))
        }
        return nodes
    }

    private static func literalNodes(
        values: [String], connected: Bool, availability: DialActionAvailability
    ) -> [DialNode] {
        validPinnedLiterals(values).map { literal in
            let nodeAvailability: DialActionAvailability
            switch CommandPolicy().classify(literal) {
            case .safe: nodeAvailability = availability
            case .reviewRequired:
                nodeAvailability = connected ? .reviewRequired : availability
            case .blocked: nodeAvailability = .blocked(reason: "Safety policy")
            }
            return DialNode(
                id: "literal.\(literal)", title: literal, subtitle: "Insert without running",
                systemImage: "text.cursor", action: .pinnedLiteral(literal),
                availability: nodeAvailability)
        }
    }

    private static func savedNodes(
        snippets: [DialSnippetDescriptor], literals: [DialNode], categories: Set<DialCategory>,
        availability: DialActionAvailability
    ) -> [DialNode] {
        let snippetNodes = snippets.map { snippet in
            DialNode(
                id: "snippet.\(snippet.id.uuidString)", title: snippet.name,
                subtitle: snippet.preview, systemImage: "text.quote", action: .snippet(snippet.id),
                availability: snippet.availability)
        }
        var nodes: [DialNode] = []
        if categories.contains(.snippets), !snippetNodes.isEmpty {
            nodes.append(
                DialNode(
                    id: "saved.snippets", title: "Snippets", subtitle: "Insert a saved command",
                    systemImage: DialCategory.snippets.systemImage, action: .category(.snippets),
                    children: pagedNodes(
                        snippetNodes, prefix: "saved.snippets", moreTitle: "More Snippets"),
                    availability: availability))
        }
        if categories.contains(.commonKeys), !literals.isEmpty {
            nodes.append(
                DialNode(
                    id: "saved.quick-text", title: "Quick Text", subtitle: "Insert a pinned phrase",
                    systemImage: "text.cursor", action: .category(.commonKeys),
                    children: pagedNodes(
                        literals, prefix: "saved.quick-text", moreTitle: "More Quick Text"),
                    availability: availability))
        }
        return nodes
    }

    private static func sessionRoot(
        children: [DialNode], availability: DialActionAvailability
    ) -> DialNode {
        let groups = groupedMultiplexerNodes(children)
        var sessionChildren = [DialNode](
            arrayLiteral: DialNode(
                id: "session.browser", title: "Browse Sessions",
                subtitle: "Attach or switch workspace", systemImage: "rectangle.stack",
                action: .multiplexer, availability: availability))
        if !groups.isEmpty {
            sessionChildren.append(
                DialNode(
                    id: "session.current", title: "tmux", subtitle: "Windows, panes, and layout",
                    systemImage: "rectangle.3.group", action: .category(.multiplexer),
                    children: groups, availability: availability))
        }
        return DialNode(
            id: "root.session", title: "Session", subtitle: "Switch and arrange your workspace",
            systemImage: DialCategory.multiplexer.systemImage, action: .category(.multiplexer),
            children: sessionChildren, availability: availability)
    }

    private static func pagedNodes(
        _ nodes: [DialNode], prefix: String,
        moreTitle: String, page: Int = 1
    ) -> [DialNode] {
        guard nodes.count > 4 else { return nodes }
        let visible = Array(nodes.prefix(3))
        let remaining = Array(nodes.dropFirst(3))
        let more = DialNode(
            id: "\(prefix).more.\(page)", title: moreTitle,
            subtitle: "\(remaining.count) more", systemImage: "ellipsis",
            action: .category(.snippets),
            children: pagedNodes(remaining, prefix: prefix, moreTitle: moreTitle, page: page + 1))
        return visible + [more]
    }

    private struct MultiplexerGroup {
        let id: String
        let title: String
        let icon: String
        let matches: (DialNode) -> Bool
    }

    private static func groupedMultiplexerNodes(_ nodes: [DialNode]) -> [DialNode] {
        let groups = [
            MultiplexerGroup(
                id: "windows", title: "Switch Window", icon: "rectangle.2.swap",
                matches: { $0.id.contains("window") }),
            MultiplexerGroup(
                id: "focus", title: "Focus", icon: "arrow.up.and.down.and.arrow.left.and.right",
                matches: { $0.id.contains(".focus.") }),
            MultiplexerGroup(
                id: "layout", title: "Arrange Panes", icon: "rectangle.3.group",
                matches: { $0.id.contains(".split.") || $0.id.hasSuffix(".zoom") }),
            MultiplexerGroup(
                id: "actions", title: "Pane Actions", icon: "ellipsis.circle",
                matches: { _ in true }),
        ]
        var remaining = nodes
        return groups.compactMap { group in
            let matches = remaining.filter(group.matches)
            remaining.removeAll(where: group.matches)
            guard !matches.isEmpty else { return nil }
            return DialNode(
                id: "session.current.\(group.id)", title: group.title,
                systemImage: group.icon, action: .category(.multiplexer),
                children: pagedNodes(
                    matches, prefix: "session.current.\(group.id)", moreTitle: "More Actions"))
        }
    }

    public static func validPinnedLiterals(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let literal = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isInsertOnlyTerminalText(literal), seen.insert(literal).inserted else {
                return nil
            }
            return literal
        }.prefix(12).map { $0 }
    }

    /// Pinned values are terminal insertion text, never commands. A persisted
    /// value may not contain a line ending or any control byte.
    public static func isInsertOnlyTerminalText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}

public enum DialActivation: Equatable, Sendable {
    case ignored
    case navigated(nodeID: String)
    case dispatch(DialActionIdentifier)
}

public struct CommandDialNavigation: Equatable, Sendable {
    public private(set) var path: [String] = []
    public private(set) var selectedNodeID: String?
    public var isOpen: Bool

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public mutating func open() {
        isOpen = true
        selectedNodeID = nil
    }

    public mutating func dismiss() {
        isOpen = false
        path.removeAll()
        selectedNodeID = nil
    }

    public mutating func clearSelection() { selectedNodeID = nil }
    public mutating func highlight(_ id: String?) { selectedNodeID = id }

    public mutating func back() {
        if !path.isEmpty { path.removeLast() }
        selectedNodeID = nil
    }

    public mutating func enter(_ node: DialNode) {
        guard node.isEnabled, !node.children.isEmpty else { return }
        path.append(node.id)
        selectedNodeID = nil
    }

    /// Converts a selected node into navigation or a typed action. Category
    /// taps can never accidentally dispatch their placeholder action.
    @discardableResult
    public mutating func activate(_ node: DialNode) -> DialActivation {
        guard node.isEnabled else { return .ignored }
        if !node.children.isEmpty {
            enter(node)
            return .navigated(nodeID: node.id)
        }
        selectedNodeID = node.id
        return .dispatch(node.action)
    }

    public var breadcrumb: String {
        path.isEmpty ? "Shh" : "Shh / " + path.joined(separator: " / ")
    }
}

public enum DialHapticEvent: Equatable, Sendable {
    case open, selection, commit, boundary, confirmation, success, failure
}

public protocol DialHaptics: Sendable {
    func emit(_ event: DialHapticEvent)
}

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

    public init(
        placement: CommandDialPlacement = .trailing, size: CommandDialSize = .compact,
        hapticsEnabled: Bool = true, pinnedCategories: [DialCategory] = DialCategory.allCases,
        pinnedLiterals: [String] = []
    ) {
        self.placement = placement
        self.size = size
        self.hapticsEnabled = hapticsEnabled
        self.pinnedCategories = pinnedCategories
        self.pinnedLiterals = CommandDialModel.validPinnedLiterals(pinnedLiterals)
    }

    private enum CodingKeys: String, CodingKey {
        case placement, size, hapticsEnabled, pinnedCategories, pinnedLiterals
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            placement: try values.decodeIfPresent(CommandDialPlacement.self, forKey: .placement)
                ?? .trailing,
            size: try values.decodeIfPresent(CommandDialSize.self, forKey: .size) ?? .compact,
            hapticsEnabled: try values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true,
            pinnedCategories: try values.decodeIfPresent(
                [DialCategory].self, forKey: .pinnedCategories) ?? DialCategory.allCases,
            pinnedLiterals: try values.decodeIfPresent([String].self, forKey: .pinnedLiterals) ?? []
        )
    }
}
