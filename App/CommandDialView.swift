import ShhCore
import ShhTerminal
import SwiftUI
import UIKit

private enum ShhDialPalette {
    static let base = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x2E / 255)
    static let mantle = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x25 / 255)
    static let surface = Color(red: 0x31 / 255, green: 0x32 / 255, blue: 0x44 / 255)
    static let overlay = Color(red: 0x45 / 255, green: 0x47 / 255, blue: 0x5A / 255)
    static let text = Color(red: 0xCD / 255, green: 0xD6 / 255, blue: 0xF4 / 255)
    static let quiet = Color(red: 0xA6 / 255, green: 0xAD / 255, blue: 0xC8 / 255)
    static let lavender = Color(red: 0xB4 / 255, green: 0xBE / 255, blue: 0xFE / 255)
    static let blue = Color(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255)
    static let teal = Color(red: 0x94 / 255, green: 0xE2 / 255, blue: 0xD5 / 255)
    static let green = Color(red: 0xA6 / 255, green: 0xE3 / 255, blue: 0xA1 / 255)
    static let red = Color(red: 0xF3 / 255, green: 0x8B / 255, blue: 0xA8 / 255)
}

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
    let onOpen: () -> Void
    let onClose: () -> Void
    let onDrag: (DialPointerEvent) -> Void

    private var dimension: CGFloat { size == .compact ? 54 : 60 }

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
                    .fill(ShhDialPalette.surface)
                    .overlay(Circle().stroke(ShhDialPalette.lavender.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                Image(systemName: isOpen ? "xmark" : "command")
                    .font(.system(size: size == .compact ? 19 : 22, weight: .semibold))
                    .foregroundStyle(ShhDialPalette.lavender)
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
        .accessibilityLabel(isOpen ? "Close command dial" : "Open command dial")
        .accessibilityHint(
            "Shows Input, Session, Saved, and Share actions from the \(placement.title.lowercased()) side"
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

    private var accent: Color {
        navigation.path.first?.contains("session") == true
            ? ShhDialPalette.blue : ShhDialPalette.lavender
    }

    init(
        model: CommandDialModel, navigation: Binding<CommandDialNavigation>,
        triggerDrag: DialPointerEvent? = nil, placement: CommandDialPlacement,
        size: CommandDialSize, hostLabel: String, paneLabel: String,
        connectionStatus: String = "Disconnected",
        onAction: @escaping (DialActionIdentifier) -> Void,
        onDismiss: @escaping () -> Void, haptics: any DialHaptics = NoopDialHaptics()
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

    private var breadcrumb: String {
        var titles = ["Commands"]
        var nodes = model.roots
        for id in navigation.path {
            guard let node = nodes.first(where: { $0.id == id }) else { break }
            titles.append(node.title)
            nodes = node.children
        }
        return titles.joined(separator: " / ")
    }

    var body: some View {
        GeometryReader { proxy in
            let center = Self.baseCenter(
                size: size, placement: placement,
                containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
            let layout = radialLayout(center: center, proxy: proxy)
            ZStack {
                ShhDialPalette.mantle
                    .opacity(contrast == .increased ? 0.88 : 0.72)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .accessibilityHidden(true)

                dialHeader(proxy: proxy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, max(proxy.safeAreaInsets.top, 8) + 8)
                    .padding(.horizontal, 14)
                    .zIndex(3)

                connectorLines(layout: layout)
                    .allowsHitTesting(false)
                    .zIndex(1)

                if Self.usesListLayout(
                    dynamicTypeSize: dynamicTypeSize, size: size,
                    containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets
                ) {
                    accessibilityLayout(proxy: proxy).zIndex(4)
                } else {
                    wheel(layout: layout, baseCenter: center).zIndex(2)
                }
            }
            .animation(
                reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.86),
                value: proxy.size
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84),
                value: navigation.path
            )
            .onChange(of: triggerDrag) { _, event in
                guard let event,
                    !Self.usesListLayout(
                        dynamicTypeSize: dynamicTypeSize, size: size,
                        containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets
                    )
                else { return }
                let frame = proxy.frame(in: .global)
                let point = CGPoint(
                    x: event.location.x - frame.minX, y: event.location.y - frame.minY)
                handlePointer(at: point, ended: event.ended, layout: layout, baseCenter: center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-dial-surface")
        .accessibilityAction(.escape) {
            if navigation.path.isEmpty { onDismiss() } else { goBack() }
        }
    }

}

extension CommandDialSurface {
    /// Compact keyboard changes only the available geometry. It never swaps
    /// the dial for a linear command list. Large Dynamic Type gets a genuine
    /// button-based alternative so VoiceOver users do not depend on gestures.
    static func usesListLayout(
        dynamicTypeSize: DynamicTypeSize, size: CommandDialSize = .compact,
        containerSize: CGSize? = nil, safeAreaInsets: EdgeInsets = EdgeInsets()
    ) -> Bool {
        _ = size
        _ = containerSize
        _ = safeAreaInsets
        return dynamicTypeSize.isAccessibilitySize
    }

    private static func baseCenter(
        size: CommandDialSize, placement: CommandDialPlacement,
        containerSize: CGSize, safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let hub: CGFloat = size == .compact ? 70 : 80
        let horizontalInset = max(safeAreaInsets.leading, safeAreaInsets.trailing) + hub / 2 + 12
        let centerX =
            placement == .leading
            ? horizontalInset : containerSize.width - horizontalInset
        let preferredCenterY = containerSize.height - safeAreaInsets.bottom - hub / 2 - 16
        let minimumCenterY = safeAreaInsets.top + hub / 2
        let maximumCenterY = containerSize.height - safeAreaInsets.bottom - hub / 2
        let centerY = min(maximumCenterY, max(minimumCenterY, preferredCenterY))
        return CGPoint(x: centerX, y: centerY)
    }

    private static let headerHeight: CGFloat = 34
    private static let headerTopSpacing: CGFloat = 8
    private static let headerSafeAreaSpacing: CGFloat = 8

    /// Matches the header's actual SwiftUI padding and frame, so cards never
    /// use a guessed clearance that becomes stale when the safe area changes.
    static func headerBottomForLayout(safeAreaTop: CGFloat) -> CGFloat {
        max(safeAreaTop, headerSafeAreaSpacing) + headerTopSpacing + headerHeight
    }

    private static func layoutInsets(for safeAreaInsets: EdgeInsets) -> DialLayoutInsets {
        DialLayoutInsets(
            top: headerBottomForLayout(safeAreaTop: safeAreaInsets.top),
            leading: safeAreaInsets.leading,
            bottom: safeAreaInsets.bottom, trailing: safeAreaInsets.trailing)
    }

    private static func preferredRadius(size: CommandDialSize, height: CGFloat) -> CGFloat {
        size == .compact ? min(254, max(112, height * 0.27)) : 330
    }

    private static func standardItemSize(for size: CommandDialSize) -> CGSize {
        CGSize(
            width: size == .compact ? 108 : 124,
            height: size == .compact ? 70 : 80)
    }

    private static func hubRadius(for size: CommandDialSize) -> CGFloat {
        size == .compact ? 35 : 40
    }

    private static func compactItemSizes(base: CGSize) -> [CGSize] {
        stride(from: 1.0, through: 0.36, by: -0.02).map {
            CGSize(width: base.width * $0, height: base.height * $0)
        }
    }

    static func computeRadialLayout(
        size: CommandDialSize, placement: CommandDialPlacement, nodeCount: Int,
        containerSize: CGSize, safeAreaInsets: EdgeInsets
    ) -> DialRadialLayout {
        let center = baseCenter(
            size: size, placement: placement,
            containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        let itemRadius = hubRadius(for: size)
        let baseSize = standardItemSize(for: size)
        let insets = layoutInsets(for: safeAreaInsets)
        let candidates = size == .compact ? compactItemSizes(base: baseSize) : [baseSize]
        for itemSize in candidates {
            let candidate = DialRadialLayout.cornerFitting(
                center: center,
                preferredRadius: preferredRadius(size: size, height: containerSize.height),
                minimumRadius: 0,
                itemRadius: itemRadius, itemSize: itemSize, count: nodeCount,
                placement: placement, bounds: containerSize, safeAreaInsets: insets,
                requireSeparatedTargets: true)
            if candidate.fits(in: containerSize, safeAreaInsets: insets, hubRadius: itemRadius) {
                return candidate
            }
        }
        return DialRadialLayout.cornerFitting(
            center: center,
            preferredRadius: preferredRadius(size: size, height: containerSize.height),
            minimumRadius: 0,
            itemRadius: itemRadius, itemSize: candidates.last ?? baseSize, count: nodeCount,
            placement: placement, bounds: containerSize, safeAreaInsets: insets,
            requireSeparatedTargets: true)
    }

    /// Resolves every selected parent from layouts recomputed for the current
    /// viewport. This keeps a child anchored to its visible ancestor when the
    /// keyboard, safe area, or device orientation changes.
    static func computeCurrentAncestorCenter(
        model: CommandDialModel, path: [String], size: CommandDialSize,
        placement: CommandDialPlacement, containerSize: CGSize, safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let rootCenter = baseCenter(
            size: size, placement: placement,
            containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        guard !path.isEmpty else { return rootCenter }

        var nodes = model.roots
        var center = rootCenter
        var layout = computeRadialLayout(
            size: size, placement: placement, nodeCount: nodes.count,
            containerSize: containerSize, safeAreaInsets: safeAreaInsets)

        for parentID in path {
            guard let index = nodes.firstIndex(where: { $0.id == parentID }),
                let parentCenter = layout.point(at: index)
            else { return center }
            center = parentCenter
            let parent = nodes[index]
            nodes = parent.children
            guard !nodes.isEmpty else { return center }
            layout = computeChildRadialLayout(
                size: size, placement: placement, nodeCount: nodes.count,
                center: center, containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        }
        return center
    }

    static func computeChildRadialLayout(
        size: CommandDialSize, placement: CommandDialPlacement, nodeCount: Int,
        center: CGPoint, containerSize: CGSize, safeAreaInsets: EdgeInsets
    ) -> DialRadialLayout {
        let itemRadius = hubRadius(for: size)
        let baseSize = standardItemSize(for: size)
        let insets = layoutInsets(for: safeAreaInsets)
        let candidates = size == .compact ? compactItemSizes(base: baseSize) : [baseSize]
        for itemSize in candidates {
            let candidate = DialRadialLayout.inwardFan(
                center: center, preferredRadius: min(142, max(78, containerSize.height * 0.2)),
                itemRadius: itemRadius, itemSize: itemSize, count: nodeCount,
                placement: placement, bounds: containerSize, safeAreaInsets: insets,
                requireSeparatedTargets: true)
            if candidate.fits(in: containerSize, safeAreaInsets: insets, hubRadius: itemRadius) {
                return candidate
            }
        }
        return DialRadialLayout.inwardFan(
            center: center, preferredRadius: min(142, max(78, containerSize.height * 0.2)),
            itemRadius: itemRadius, itemSize: candidates.last ?? baseSize, count: nodeCount,
            placement: placement, bounds: containerSize, safeAreaInsets: insets,
            requireSeparatedTargets: true)
    }

    private func radialLayout(center: CGPoint, proxy: GeometryProxy) -> DialRadialLayout {
        if navigation.path.isEmpty {
            return Self.computeRadialLayout(
                size: size, placement: placement, nodeCount: currentNodes.count,
                containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
        }
        let activeCenter = Self.computeCurrentAncestorCenter(
            model: model, path: navigation.path, size: size, placement: placement,
            containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
        return Self.computeChildRadialLayout(
            size: size, placement: placement, nodeCount: currentNodes.count,
            center: activeCenter, containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
    }

    private func dialHeader(proxy: GeometryProxy) -> some View {
        HStack(spacing: 7) {
            Image(systemName: navigation.path.isEmpty ? "command" : "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
            Text(breadcrumb)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(ShhDialPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 6)
            Circle()
                .fill(connectionStatus == "Connected" ? ShhDialPalette.green : .orange)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(connectionStatus)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ShhDialPalette.quiet)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(ShhDialPalette.base.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.26), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(hostLabel), \(paneLabel), \(breadcrumb), \(connectionStatus), \(currentNodes.count) actions"
        )
        .accessibilityIdentifier("command-dial-breadcrumb")
        .padding(.horizontal, max(0, (proxy.size.width - 520) / 2))
    }

    private func connectorLines(layout: DialRadialLayout) -> some View {
        Canvas { context, _ in
            for point in layout.positions {
                var path = Path()
                path.move(to: layout.center)
                path.addLine(to: point)
                context.stroke(
                    path,
                    with: .color(accent.opacity(0.22)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            }
        }
    }

    private func accessibilityLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            Spacer().frame(height: max(proxy.safeAreaInsets.top, 8) + 45)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(currentNodes) { node in accessibilityNodeButton(node) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            backButton
                .padding(.horizontal, 14)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
        }
    }

    private func accessibilityNodeButton(_ node: DialNode) -> some View {
        Button {
            activate(node, point: nil, baseCenter: nil)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: node.systemImage ?? "circle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.title).font(.headline).multilineTextAlignment(.leading)
                    if let subtitle = node.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(ShhDialPalette.quiet)
                    }
                }
                Spacer(minLength: 8)
                if node.availability == .reviewRequired {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                } else if !node.children.isEmpty {
                    Image(systemName: "chevron.forward").foregroundStyle(accent)
                }
            }
            .foregroundStyle(
                node.isEnabled ? ShhDialPalette.text : ShhDialPalette.quiet.opacity(0.5)
            )
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(ShhDialPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!node.isEnabled)
        .accessibilityLabel(node.accessibilityLabel)
        .accessibilityHint(node.children.isEmpty ? "Activates this action" : "Opens this group")
        .accessibilityIdentifier(
            "command-dial-node-\(node.id.replacingOccurrences(of: ".", with: "-"))")
    }

    private var backButton: some View {
        Button {
            if navigation.path.isEmpty { onDismiss() } else { goBack() }
        } label: {
            Label(
                navigation.path.isEmpty ? "Close" : "Back",
                systemImage: navigation.path.isEmpty ? "xmark" : "chevron.backward"
            )
            .font(.headline)
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(ShhDialPalette.base, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("command-dial-home")
    }

    private func wheel(layout: DialRadialLayout, baseCenter: CGPoint) -> some View {
        ZStack {
            ForEach(Array(currentNodes.enumerated()), id: \.element.id) { index, node in
                if let point = layout.point(at: index) {
                    radialNodeButton(
                        node, point: point, layout: layout, baseCenter: baseCenter)
                }
            }
            centralPuck(at: layout.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .highPriorityGesture(radialGesture(layout: layout, baseCenter: baseCenter))
        .accessibilityAddTraits(.isModal)
        .accessibilityHint(
            "Swipe over an action and lift to choose it. Move outward through a group to open it."
        )
    }

    private func centralPuck(at point: CGPoint) -> some View {
        Button {
            if navigation.path.isEmpty {
                haptics.emit(.commit)
                onDismiss()
            } else {
                goBack()
            }
        } label: {
            ZStack {
                Circle().fill(ShhDialPalette.surface)
                    .overlay(Circle().stroke(accent, lineWidth: 1.8))
                    .shadow(color: accent.opacity(0.2), radius: 14, y: 4)
                VStack(spacing: 2) {
                    Image(systemName: navigation.path.isEmpty ? "xmark" : "chevron.backward")
                        .font(.system(size: size == .compact ? 21 : 25, weight: .bold))
                    Text(navigation.path.isEmpty ? "Close" : "Back")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(accent)
            }
            .frame(width: size == .compact ? 70 : 80, height: size == .compact ? 70 : 80)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .position(point)
        .accessibilityLabel(navigation.path.isEmpty ? "Close command dial" : "Back one level")
        .accessibilityHint(
            navigation.path.isEmpty
                ? "Dismisses the command dial" : "Restores the previous dial layer and focus"
        )
        .accessibilityIdentifier("command-dial-home")
    }

    private func radialNodeButton(
        _ node: DialNode, point: CGPoint, layout: DialRadialLayout, baseCenter: CGPoint
    ) -> some View {
        let highlighted = highlightedNodeID == node.id || navigation.selectedNodeID == node.id
        let width = layout.itemSize.width
        let height = layout.itemSize.height
        return Button {
            activate(node, point: point, baseCenter: baseCenter)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: node.systemImage ?? "circle")
                    .font(.title3.weight(.semibold))
                    .frame(height: 23)
                Text(node.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(highlighted ? ShhDialPalette.base : ShhDialPalette.text)
            .padding(.horizontal, 7)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(highlighted ? accent : ShhDialPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        highlighted ? accent : accent.opacity(0.42), lineWidth: highlighted ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
            .scaleEffect(highlighted && !reduceMotion ? 1.05 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .position(point)
        .disabled(!node.isEnabled)
        .opacity(node.isEnabled ? 1 : 0.5)
        .accessibilityLabel(node.accessibilityLabel)
        .accessibilityHint(node.children.isEmpty ? "Activates this action" : "Opens this group")
        .accessibilityIdentifier(
            "command-dial-node-\(node.id.replacingOccurrences(of: ".", with: "-"))")
    }

    private func radialGesture(
        layout: DialRadialLayout, baseCenter: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                handlePointer(
                    at: value.location, ended: false, layout: layout,
                    baseCenter: baseCenter)
            }
            .onEnded { value in
                handlePointer(
                    at: value.location, ended: true, layout: layout,
                    baseCenter: baseCenter)
            }
    }

    private func handlePointer(
        at point: CGPoint, ended: Bool, layout: DialRadialLayout, baseCenter: CGPoint
    ) {
        let previous = gesturePreviousLocation ?? point
        gesturePreviousLocation = point
        let selectedGroup = currentNodes.first { $0.id == highlightedNodeID }
        let transition = layout.levelTransition(
            from: previous, to: point,
            selectedGroup: selectedGroup?.isEnabled == true
                && !(selectedGroup?.children.isEmpty ?? true),
            hasParent: !navigation.path.isEmpty)
        switch transition {
        case .enter:
            guard let selectedGroup,
                let index = currentNodes.firstIndex(where: { $0.id == selectedGroup.id })
            else { return }
            activate(selectedGroup, point: layout.point(at: index), baseCenter: baseCenter)
            gestureChangedLevel = true
            highlightedNodeID = nil
            if ended { resetGesture() }
            return
        case .back:
            goBack()
            gestureChangedLevel = true
            if ended { resetGesture() }
            return
        case nil:
            break
        }

        if let index = layout.index(at: point), currentNodes.indices.contains(index) {
            let node = currentNodes[index]
            if node.isEnabled {
                highlightedNodeID = node.id
                if lastHighlightedNodeID != node.id {
                    haptics.emit(.selection)
                    lastHighlightedNodeID = node.id
                }
            } else {
                highlightedNodeID = nil
                haptics.emit(.boundary)
            }
        } else {
            highlightedNodeID = nil
        }
        guard ended else { return }
        defer { resetGesture() }
        guard !gestureChangedLevel,
            let index = layout.index(at: point), currentNodes.indices.contains(index),
            highlightedNodeID == currentNodes[index].id
        else { return }
        activate(currentNodes[index], point: layout.point(at: index), baseCenter: baseCenter)
    }

    private func activate(_ node: DialNode, point: CGPoint?, baseCenter: CGPoint?) {
        guard node.isEnabled else {
            haptics.emit(.boundary)
            return
        }
        if !node.children.isEmpty {
            _ = navigation.activate(node)
            highlightedNodeID = nil
            haptics.emit(.commit)
            return
        }
        switch navigation.activate(node) {
        case .ignored: haptics.emit(.boundary)
        case .navigated: haptics.emit(.commit)
        case .dispatch:
            haptics.emit(.commit)
            onAction(node.action)
        }
    }

    private func goBack() {
        guard !navigation.path.isEmpty else {
            onDismiss()
            return
        }
        let restoredID = navigation.path.last
        navigation.back()
        highlightedNodeID = restoredID
        lastHighlightedNodeID = restoredID
        haptics.emit(.selection)
    }

    private func resetGesture() {
        highlightedNodeID = nil
        lastHighlightedNodeID = nil
        gesturePreviousLocation = nil
        gestureChangedLevel = false
    }
}
