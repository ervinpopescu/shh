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
        case .commonKeys: return "Navigation"
        case .snippets: return "Saved Commands"
        case .voice: return "Dictate"
        case .keyboard: return "Keyboard"
        case .multiplexer: return "Session"
        case .sendImage: return "Share Image"
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
        id: UUID, name: String, preview: String, availability: DialActionAvailability = .available
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
        let pinned = Set(pinnedCategories)
        let connectionAvailability: DialActionAvailability =
            connected
            ? .available
            : .unavailable(reason: "Connect to a host")

        let keys = Dictionary(
            uniqueKeysWithValues: DialCommonKey.allCases.map { key in
                (
                    key,
                    DialNode(
                        id: "key.\(key.id)", title: key.title, systemImage: key.systemImage,
                        action: .commonKey(key), availability: connectionAvailability)
                )
            })
        func nodes(for values: [DialCommonKey]) -> [DialNode] {
            values.compactMap { keys[$0] }
        }

        var inputChildren: [DialNode] = []
        if pinned.contains(.commonKeys) {
            inputChildren.append(
                DialNode(
                    id: "input.navigate", title: "Navigate",
                    subtitle: "Move, complete, and control terminal input",
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                    action: .category(.commonKeys),
                    children: [
                        DialNode(
                            id: "input.navigate.cursor", title: "Move Cursor",
                            systemImage: "cursorarrow.motionlines",
                            action: .category(.commonKeys),
                            children: nodes(for: [.arrowUp, .arrowRight, .arrowDown, .arrowLeft]),
                            availability: connectionAvailability),
                        DialNode(
                            id: "input.navigate.complete", title: "Complete",
                            systemImage: "arrow.right.to.line.compact",
                            action: .category(.commonKeys),
                            children: nodes(for: [.tab, .shiftTab]),
                            availability: connectionAvailability),
                        DialNode(
                            id: "input.navigate.control", title: "Control Process",
                            systemImage: "terminal",
                            action: .category(.commonKeys),
                            children: nodes(for: [.enter, .escape, .controlC, .controlD]),
                            availability: connectionAvailability),
                    ],
                    availability: connectionAvailability
                )
            )
        }
        if pinned.contains(.keyboard) {
            inputChildren.append(
                DialNode(
                    id: "input.keyboard", title: "Show Keyboard", subtitle: "Return to typing",
                    systemImage: DialCategory.keyboard.systemImage, action: .keyboard))
        }
        if pinned.contains(.voice) {
            inputChildren.append(
                DialNode(
                    id: "input.dictate", title: "Dictate", subtitle: "Compose with your voice",
                    systemImage: DialCategory.voice.systemImage, action: .voice,
                    availability: connectionAvailability))
        }

        let literals = Self.validPinnedLiterals(pinnedLiterals).map { literal in
            let availability: DialActionAvailability
            switch CommandPolicy().classify(literal) {
            case .safe: availability = connectionAvailability
            case .reviewRequired:
                availability = connected ? .reviewRequired : connectionAvailability
            case .blocked: availability = .blocked(reason: "Safety policy")
            }
            return DialNode(
                id: "literal.\(literal)", title: literal, subtitle: "Insert without running",
                systemImage: "text.cursor", action: .pinnedLiteral(literal),
                availability: availability)
        }
        let snippetNodes = snippets.map { snippet in
            DialNode(
                id: "snippet.\(snippet.id.uuidString)", title: snippet.name,
                subtitle: snippet.preview,
                systemImage: "text.quote", action: .snippet(snippet.id),
                availability: snippet.availability)
        }
        var runChildren: [DialNode] = []
        if pinned.contains(.snippets), !snippetNodes.isEmpty {
            runChildren.append(
                DialNode(
                    id: "run.saved", title: "Saved Commands", subtitle: "Run a trusted snippet",
                    systemImage: DialCategory.snippets.systemImage, action: .category(.snippets),
                    children: Self.pagedNodes(
                        snippetNodes, prefix: "run.saved", moreTitle: "More Commands"),
                    availability: connectionAvailability)
            )
        }
        if pinned.contains(.commonKeys), !literals.isEmpty {
            runChildren.append(
                DialNode(
                    id: "run.quick-text", title: "Quick Text", subtitle: "Insert a pinned phrase",
                    systemImage: "text.cursor", action: .category(.commonKeys),
                    children: Self.pagedNodes(
                        literals, prefix: "run.quick-text", moreTitle: "More Quick Text"),
                    availability: connectionAvailability)
            )
        }

        let multiplexerGroups = Self.groupedMultiplexerNodes(multiplexerChildren)
        var roots: [DialNode] = []
        if !inputChildren.isEmpty {
            roots.append(
                DialNode(
                    id: "root.input", title: "Input", subtitle: "Type, dictate, or navigate",
                    systemImage: "terminal", action: .category(.commonKeys),
                    children: inputChildren,
                    availability: inputChildren.contains(where: \.isEnabled)
                        ? .available : connectionAvailability)
            )
        }
        if !runChildren.isEmpty {
            roots.append(
                DialNode(
                    id: "root.run", title: "Run", subtitle: "Saved commands and quick text",
                    systemImage: "play.fill", action: .category(.snippets), children: runChildren,
                    availability: runChildren.contains(where: \.isEnabled)
                        ? .available : connectionAvailability)
            )
        }
        if pinned.contains(.multiplexer) {
            var sessionChildren = [
                DialNode(
                    id: "session.browser", title: "Browse Sessions",
                    subtitle: "Attach or switch workspace",
                    systemImage: "rectangle.stack", action: .multiplexer,
                    availability: connectionAvailability)
            ]
            if !multiplexerGroups.isEmpty {
                sessionChildren.append(
                    DialNode(
                        id: "session.current", title: "Current Session",
                        subtitle: "Windows, panes, and layout",
                        systemImage: "rectangle.3.group", action: .category(.multiplexer),
                        children: multiplexerGroups, availability: connectionAvailability)
                )
            }
            roots.append(
                DialNode(
                    id: "root.session", title: "Session",
                    subtitle: "Switch and arrange your workspace",
                    systemImage: DialCategory.multiplexer.systemImage,
                    action: .category(.multiplexer),
                    children: sessionChildren, availability: connectionAvailability)
            )
        }
        if pinned.contains(.sendImage) {
            roots.append(
                DialNode(
                    id: "root.share", title: "Share", subtitle: "Send an image to this host",
                    systemImage: "square.and.arrow.up", action: .sendImage,
                    availability: connectionAvailability)
            )
        }
        self.roots = roots
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
            children: pagedNodes(remaining, prefix: prefix, moreTitle: moreTitle, page: page + 1)
        )
        return visible + [more]
    }

    private static func groupedMultiplexerNodes(_ nodes: [DialNode]) -> [DialNode] {
        let groups: [(id: String, title: String, icon: String, matches: (DialNode) -> Bool)] = [
            ("windows", "Switch Window", "rectangle.2.swap", { $0.id.contains("window") }),
            (
                "focus", "Choose Pane", "arrow.up.and.down.and.arrow.left.and.right",
                { $0.id.contains(".focus.") }
            ),
            (
                "layout", "Arrange Panes", "rectangle.3.group",
                {
                    $0.id.contains(".split.") || $0.id.hasSuffix(".zoom")
                }
            ),
            ("actions", "Pane Actions", "ellipsis.circle", { _ in true }),
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
                    matches, prefix: "session.current.\(group.id)",
                    moreTitle: "More Actions"))
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

    /// Pinned values are terminal insertion text, never commands. In particular,
    /// a persisted value may not contain a line ending or any control byte.
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

    /// Converts a selected node into either navigation or a typed action. The
    /// view and non-visual clients share this path so category taps can never
    /// accidentally dispatch their placeholder action.
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
