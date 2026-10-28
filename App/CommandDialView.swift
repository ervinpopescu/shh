import ShhCore
import ShhTerminal
import SwiftUI
import UIKit

struct SystemDialHaptics: DialHaptics {
    func emit(_ event: DialHapticEvent) {
        switch event {
        case .open, .selection, .boundary:
            UIImpactFeedbackGenerator(style: event == .boundary ? .soft : .light).impactOccurred()
        case .commit, .confirmation:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct DialPointerEvent: Equatable {
    let location: CGPoint
    let ended: Bool
}

struct CommandDialTrigger: View {
    @Binding var isOpen: Bool
    let size: CommandDialSize
    let placement: CommandDialPlacement
    let accentColor = Color(red: 0.30, green: 0.96, blue: 0.68)
    let onOpen: () -> Void
    let onClose: () -> Void
    let onDrag: (DialPointerEvent) -> Void

    private var dimension: CGFloat { size == .compact ? 46 : 54 }

    var body: some View {
        Button {
            if isOpen {
                onClose()
            } else {
                isOpen = true
                onOpen()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.88))
                    .overlay(Circle().stroke(accentColor.opacity(0.72), lineWidth: 1.5))
                Image(systemName: isOpen ? "xmark" : "command")
                    .font(.system(size: size == .compact ? 17 : 20, weight: .bold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: dimension, height: dimension)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    if !isOpen {
                        isOpen = true
                        onOpen()
                    }
                    onDrag(DialPointerEvent(location: value.location, ended: false))
                }
                .onEnded { value in
                    onDrag(DialPointerEvent(location: value.location, ended: true))
                }
        )
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .accessibilityLabel(isOpen ? "Close command center" : "Open command center")
        .accessibilityHint(
            "Shows one-handed terminal actions from the \(placement.title.lowercased()) side"
        )
        .accessibilityIdentifier("command-dial-trigger")
    }
}

struct CommandDialSurface: View {
    let model: CommandDialModel
    @Binding var navigation: CommandDialNavigation
    let triggerDrag: DialPointerEvent?
    let placement: CommandDialPlacement
    let size: CommandDialSize
    let hostLabel: String
    let paneLabel: String
    let connectionStatus: String
    let onAction: (DialActionIdentifier) -> Void
    let onDismiss: () -> Void
    let haptics: any DialHaptics

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var highlightedNodeID: String?
    @State private var lastHighlightedNodeID: String?
    @State private var gesturePreviousLocation: CGPoint?
    @State private var gestureChangedLevel = false

    private let accent = Color(red: 0.43, green: 0.95, blue: 0.69)
    private let coolAccent = Color(red: 0.44, green: 0.62, blue: 0.96)

    init(
        model: CommandDialModel, navigation: Binding<CommandDialNavigation>,
        triggerDrag: DialPointerEvent? = nil,
        placement: CommandDialPlacement,
        size: CommandDialSize, hostLabel: String, paneLabel: String,
        connectionStatus: String = "Disconnected",
        onAction: @escaping (DialActionIdentifier) -> Void, onDismiss: @escaping () -> Void,
        haptics: any DialHaptics = NoopDialHaptics()
    ) {
        self.model = model
        self._navigation = navigation
        self.triggerDrag = triggerDrag
        self.placement = placement
        self.size = size
        self.hostLabel = hostLabel
        self.paneLabel = paneLabel
        self.connectionStatus = connectionStatus
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.haptics = haptics
    }

    private var currentNodes: [DialNode] {
        guard !navigation.path.isEmpty else { return model.roots }
        var nodes = model.roots
        for parentID in navigation.path {
            guard let parent = nodes.first(where: { $0.id == parentID }) else { return [] }
            nodes = parent.children
        }
        return nodes
    }

    private var currentTitle: String {
        guard let currentID = navigation.path.last else { return "Command Center" }
        var nodes = model.roots
        for id in navigation.path {
            guard let node = nodes.first(where: { $0.id == id }) else { return "Command Center" }
            if id == currentID { return node.title }
            nodes = node.children
        }
        return "Command Center"
    }

    private var breadcrumb: String {
        var titles = ["Commands"]
        var nodes = model.roots
        for id in navigation.path {
            guard let node = nodes.first(where: { $0.id == id }) else { break }
            titles.append(node.title)
            nodes = node.children
        }
        return titles.joined(separator: "  /  ")
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = radialLayout(in: proxy)
            ZStack {
                Color(red: 0.035, green: 0.05, blue: 0.06)
                    .opacity(contrast == .increased ? 0.34 : 0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .accessibilityHidden(true)

                RadialGradient(
                    colors: [accent.opacity(0.13), coolAccent.opacity(0.05), .clear],
                    center: placement == .leading ? .bottomLeading : .bottomTrailing,
                    startRadius: 12,
                    endRadius: layout.orbitRadius * 1.7
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                if Self.usesListLayout(
                    dynamicTypeSize: dynamicTypeSize,
                    size: size,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                ) {
                    accessibilityLayout(proxy: proxy)
                        .zIndex(3)
                } else {
                    commandHeader(proxy: proxy)
                        .padding(.horizontal, 16)
                        .position(x: proxy.size.width / 2, y: proxy.safeAreaInsets.top + 62)
                        .zIndex(3)

                    wheel(layout: layout)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(
                                    scale: 0.90,
                                    anchor: placement == .leading ? .bottomLeading : .bottomTrailing
                                )
                                .combined(with: .opacity)
                        )
                        .zIndex(2)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
                value: navigation.path
            )
            .onChange(of: triggerDrag) { _, event in
                guard let event,
                    !Self.usesListLayout(
                        dynamicTypeSize: dynamicTypeSize,
                        size: size,
                        containerSize: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                else {
                    return
                }
                let frame = proxy.frame(in: .global)
                let point = CGPoint(
                    x: event.location.x - frame.minX, y: event.location.y - frame.minY)
                handlePointer(at: point, ended: event.ended, layout: layout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-dial-surface")
        .accessibilityAction(.escape) {
            if navigation.path.isEmpty { onDismiss() } else { navigation.back() }
        }
    }

    static func usesListLayout(
        dynamicTypeSize: DynamicTypeSize,
        size: CommandDialSize = .compact,
        containerSize: CGSize? = nil,
        safeAreaInsets: EdgeInsets = EdgeInsets()
    ) -> Bool {
        guard !dynamicTypeSize.isAccessibilitySize, let containerSize else {
            return dynamicTypeSize.isAccessibilitySize
        }

        let cardHalfHeight: CGFloat = size == .compact ? 39 : 44
        let centerY = containerSize.height - safeAreaInsets.bottom - cardHalfHeight - 20
        let headerReserve: CGFloat = size == .compact ? 178 : 192
        let heightLimit = centerY - safeAreaInsets.top - headerReserve - cardHalfHeight

        // A clamped radius of 132 points is not enough to keep a card inside a
        // short keyboard-reduced viewport. Use the scrollable list before the
        // radial layout reaches that clamp, while retaining the radial dial at
        // normal phone and tablet heights.
        return heightLimit < 132
    }

    private func radialLayout(in proxy: GeometryProxy) -> DialRadialLayout {
        Self.computeRadialLayout(
            size: size,
            placement: placement,
            nodeCount: currentNodes.count,
            containerSize: proxy.size,
            safeAreaInsets: proxy.safeAreaInsets
        )
    }

    static func computeRadialLayout(
        size: CommandDialSize,
        placement: CommandDialPlacement,
        nodeCount: Int,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> DialRadialLayout {
        let itemRadius: CGFloat = size == .compact ? 38 : 43
        let cardHalfWidth: CGFloat = size == .compact ? 58 : 66
        let cardHalfHeight: CGFloat = size == .compact ? 39 : 44
        let horizontalMargin = max(safeAreaInsets.leading, safeAreaInsets.trailing) + 18
        let centerInset = max(cardHalfWidth, itemRadius) + horizontalMargin
        let centerX = placement == .leading ? centerInset : containerSize.width - centerInset
        let centerY = containerSize.height - safeAreaInsets.bottom - cardHalfHeight - 20
        let availableWidth =
            placement == .leading
            ? containerSize.width - centerX - safeAreaInsets.trailing - cardHalfWidth - 14
            : centerX - safeAreaInsets.leading - cardHalfWidth - 14
        let widthLimit = max(132, availableWidth)
        // Keep compact phones from placing the uppermost card into the
        // header when the terminal viewport is reduced by the keyboard.
        let headerReserve: CGFloat = size == .compact ? 178 : 192
        let heightLimit = max(
            132, centerY - safeAreaInsets.top - headerReserve - cardHalfHeight)
        let preferred: CGFloat = size == .compact ? 254 : 330
        let radius = min(preferred, widthLimit, heightLimit)
        return DialRadialLayout.corner(
            center: CGPoint(x: centerX, y: centerY),
            radius: radius,
            itemRadius: itemRadius,
            itemSize: CGSize(width: cardHalfWidth * 2, height: cardHalfHeight * 2),
            count: max(nodeCount, 1),
            placement: placement
        )
    }

    private func commandHeader(proxy: GeometryProxy) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.caption.bold())
                    .foregroundStyle(accent)
                Text("COMMANDS")
                    .font(.caption.weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(accent)
                Spacer(minLength: 8)
                Circle()
                    .fill(connectionStatus == "Connected" ? accent : Color.orange)
                    .frame(width: 7, height: 7)
                Text(connectionStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)

            Text("\(hostLabel)  /  \(paneLabel)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if !navigation.path.isEmpty {
                Text(currentTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(coolAccent)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: min(proxy.size.width - 32, 540), alignment: .leading)
        .background(
            Color(red: 0.065, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(coolAccent.opacity(contrast == .increased ? 0.9 : 0.42), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(hostLabel), \(paneLabel), \(breadcrumb), \(connectionStatus), \(currentNodes.count) actions"
        )
        .accessibilityIdentifier("command-dial-breadcrumb")
    }

    private func accessibilityLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 16) {
            commandHeader(proxy: proxy)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(currentNodes) { node in
                        accessibilityNodeButton(node)
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                if navigation.path.isEmpty {
                    onDismiss()
                } else {
                    navigation.back()
                    haptics.emit(.selection)
                }
            } label: {
                Label(
                    navigation.path.isEmpty ? "Cancel" : "Back",
                    systemImage: navigation.path.isEmpty ? "xmark" : "chevron.backward"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("command-dial-home")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func accessibilityNodeButton(_ node: DialNode) -> some View {
        Button {
            activate(node)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: node.systemImage ?? "circle")
                    .font(.title2.weight(.semibold))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    if let subtitle = node.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if node.availability == .reviewRequired {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                } else if !node.children.isEmpty {
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(node.isEnabled ? Color.white : Color.white.opacity(0.45))
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                Color.black.opacity(contrast == .increased ? 1 : 0.88),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        node.isEnabled ? coolAccent.opacity(0.55) : Color.white.opacity(0.14),
                        lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!node.isEnabled)
        .accessibilityLabel(node.accessibilityLabel)
        .accessibilityHint(
            node.children.isEmpty
                ? "Activates this action"
                : "Opens \(node.title) and its \(node.children.count) actions"
        )
        .accessibilityIdentifier(
            "command-dial-node-\(node.id.replacingOccurrences(of: ".", with: "-"))")
    }

    private func wheel(layout: DialRadialLayout) -> some View {
        ZStack {
            ForEach(Array(currentNodes.enumerated()), id: \.element.id) { index, node in
                if let point = layout.point(at: index) {
                    radialNodeButton(node, point: point)
                }
            }
            centralPuck.position(layout.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .highPriorityGesture(radialGesture(layout: layout))
        .accessibilityAddTraits(.isModal)
        .accessibilityHint(
            "Swipe outward through a group to open it, inward toward the center to go back. Lift on an action to choose it."
        )
    }

    private var centralPuck: some View {
        Button {
            if navigation.path.isEmpty {
                haptics.emit(.commit)
                onDismiss()
            } else {
                navigation.back()
                highlightedNodeID = nil
                haptics.emit(.selection)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(red: 0.09, green: 0.11, blue: 0.12))
                    .overlay(Circle().stroke(accent.opacity(0.82), lineWidth: 1.5))
                    .shadow(color: accent.opacity(0.20), radius: 18)
                Image(systemName: navigation.path.isEmpty ? "xmark" : "chevron.backward")
                    .font(.system(size: size == .compact ? 22 : 26, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: size == .compact ? 72 : 82, height: size == .compact ? 72 : 82)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(navigation.path.isEmpty ? "Close command center" : "Back one level")
        .accessibilityHint(
            navigation.path.isEmpty
                ? "Dismisses the command center" : "Returns to the previous action group"
        )
        .accessibilityIdentifier("command-dial-home")
    }

    private func radialNodeButton(_ node: DialNode, point: CGPoint) -> some View {
        let isHighlighted = highlightedNodeID == node.id || navigation.selectedNodeID == node.id
        let width: CGFloat = size == .compact ? 112 : 128
        let height: CGFloat = size == .compact ? 74 : 84
        return Button {
            activate(node)
        } label: {
            radialNodeButtonContent(node: node, isHighlighted: isHighlighted, width: width, height: height)
        }
        .buttonStyle(.plain)
        .position(point)
        .disabled(!node.isEnabled)
        .opacity(node.isEnabled ? 1 : 0.52)
        .accessibilityLabel(node.accessibilityLabel)
        .accessibilityHint(
            node.children.isEmpty
                ? "Activates this action"
                : "Opens \(node.title) and its \(node.children.count) actions"
        )
        .accessibilityIdentifier(
            "command-dial-node-\(node.id.replacingOccurrences(of: ".", with: "-"))")
    }

    @ViewBuilder
    private func radialNodeButtonContent(
        node: DialNode, isHighlighted: Bool, width: CGFloat, height: CGFloat
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: node.systemImage ?? "circle")
                .font(.title3.weight(.semibold))
                .frame(height: 24)
            Text(node.title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.74)
        }
        .foregroundStyle(
            isHighlighted
                ? Color.black : (node.isEnabled ? Color.white : Color.white.opacity(0.48))
        )
        .padding(.horizontal, 8)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(
                    isHighlighted
                        ? accent : Color.black.opacity(contrast == .increased ? 0.96 : 0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(
                    isHighlighted
                        ? accent
                        : (node.isEnabled
                            ? coolAccent.opacity(0.46) : Color.white.opacity(0.15)),
                    lineWidth: isHighlighted ? 2 : 1
                )
        )
        .overlay(alignment: .topTrailing) {
            radialNodeBadge(for: node)
        }
        .shadow(
            color: isHighlighted ? accent.opacity(0.24) : Color.black.opacity(0.35), radius: 10,
            y: 5
        )
        .scaleEffect(isHighlighted && !reduceMotion ? 1.07 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    @ViewBuilder
    private func radialNodeBadge(for node: DialNode) -> some View {
        if node.availability == .reviewRequired {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(7)
        } else if !node.children.isEmpty {
            Image(systemName: "arrow.up.right")
                .font(.caption2.bold())
                .foregroundStyle(accent)
                .padding(7)
        }
    }

    private func radialGesture(layout: DialRadialLayout) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                handlePointer(at: value.location, ended: false, layout: layout)
            }
            .onEnded { value in
                handlePointer(at: value.location, ended: true, layout: layout)
            }
    }

    private func handlePointer(at point: CGPoint, ended: Bool, layout: DialRadialLayout) {
        let previous = gesturePreviousLocation ?? point
        gesturePreviousLocation = point
        let activeLayout = DialRadialLayout.corner(
            center: layout.center,
            radius: layout.orbitRadius,
            itemRadius: layout.itemRadius,
            itemSize: layout.itemSize,
            count: currentNodes.count,
            placement: placement
        )
        let selectedGroup = currentNodes.first { $0.id == highlightedNodeID }
        switch activeLayout.levelTransition(
            from: previous,
            to: point,
            selectedGroup: selectedGroup?.isEnabled == true
                && selectedGroup?.children.isEmpty == false,
            hasParent: !navigation.path.isEmpty
        ) {
        case .enter:
            if let selectedGroup {
                navigation.enter(selectedGroup)
                gestureChangedLevel = true
                highlightedNodeID = nil
                lastHighlightedNodeID = nil
                haptics.emit(.commit)
            }
            if ended { resetGesture() }
            return
        case .back:
            navigation.back()
            gestureChangedLevel = true
            highlightedNodeID = nil
            lastHighlightedNodeID = nil
            haptics.emit(.selection)
            if ended { resetGesture() }
            return
        case nil:
            break
        }

        if let index = activeLayout.index(at: point), currentNodes.indices.contains(index) {
            let node = currentNodes[index]
            if node.isEnabled {
                highlightedNodeID = node.id
                gestureChangedLevel = false
                if lastHighlightedNodeID != node.id {
                    haptics.emit(.selection)
                    lastHighlightedNodeID = node.id
                }
            } else {
                highlightedNodeID = nil
                if lastHighlightedNodeID != node.id {
                    haptics.emit(.boundary)
                    lastHighlightedNodeID = node.id
                }
            }
        } else {
            highlightedNodeID = nil
        }

        guard ended else { return }
        defer { resetGesture() }
        guard !gestureChangedLevel,
            let index = activeLayout.index(at: point), currentNodes.indices.contains(index),
            highlightedNodeID == currentNodes[index].id
        else { return }
        activate(currentNodes[index])
    }

    private func resetGesture() {
        highlightedNodeID = nil
        lastHighlightedNodeID = nil
        gesturePreviousLocation = nil
        gestureChangedLevel = false
    }

    private func activate(_ node: DialNode) {
        switch navigation.activate(node) {
        case .ignored:
            haptics.emit(.boundary)
        case .navigated:
            highlightedNodeID = nil
            haptics.emit(.commit)
        case .dispatch(let action):
            haptics.emit(.commit)
            onAction(action)
        }
    }
}
