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
    let surfaceLocalSafeAreaInsets: EdgeInsets

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

    /// The parent supplies `surfaceLocalSafeAreaInsets` in this surface's coordinate space.
    /// Standalone and preview callers use zero when their bounds already exclude parent
    /// safe-area or occlusion constraints.
    init(
        model: CommandDialModel, navigation: Binding<CommandDialNavigation>,
        triggerDrag: DialPointerEvent? = nil, placement: CommandDialPlacement,
        size: CommandDialSize, hostLabel: String, paneLabel: String,
        connectionStatus: String = "Disconnected",
        onAction: @escaping (DialActionIdentifier) -> Void,
        onDismiss: @escaping () -> Void, haptics: any DialHaptics = NoopDialHaptics(),
        surfaceLocalSafeAreaInsets: EdgeInsets = EdgeInsets()
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
        self.surfaceLocalSafeAreaInsets = surfaceLocalSafeAreaInsets
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
            // The parent owns the coordinate-space conversion. This value is already
            // local to the dial surface and is shared by every geometry calculation.
            let surfaceSafeAreaInsets = surfaceLocalSafeAreaInsets
            let center = Self.baseCenter(
                size: size, placement: placement,
                containerSize: proxy.size, safeAreaInsets: surfaceSafeAreaInsets)
            let layout = radialLayout(
                center: center, containerSize: proxy.size,
                safeAreaInsets: surfaceSafeAreaInsets)
            ZStack {
                ShhDialPalette.mantle
                    .opacity(contrast == .increased ? 0.88 : 0.72)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .accessibilityHidden(true)

                dialHeader(proxy: proxy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, max(surfaceSafeAreaInsets.top, 8) + 8)
                    .padding(.horizontal, 14)
                    .zIndex(3)

                connectorLines(layout: layout)
                    .allowsHitTesting(false)
                    .zIndex(1)

                if Self.usesListLayout(
                    dynamicTypeSize: dynamicTypeSize, size: size,
                    containerSize: proxy.size, safeAreaInsets: surfaceSafeAreaInsets
                ) {
                    accessibilityLayout(safeAreaInsets: surfaceSafeAreaInsets)
                        .zIndex(4)
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
                        containerSize: proxy.size, safeAreaInsets: surfaceSafeAreaInsets
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
        var firstFittingCandidate: DialRadialLayout?
        for itemSize in candidates {
            let candidate = DialRadialLayout.cornerFitting(
                center: center,
                preferredRadius: preferredRadius(size: size, height: containerSize.height),
                minimumRadius: 0,
                itemRadius: itemRadius, itemSize: itemSize, count: nodeCount,
                placement: placement, bounds: containerSize, safeAreaInsets: insets,
                requireSeparatedTargets: true)
            guard candidate.fits(in: containerSize, safeAreaInsets: insets, hubRadius: itemRadius)
            else { continue }
            firstFittingCandidate = firstFittingCandidate ?? candidate
            if isAngularLayout(candidate) { return candidate }
        }
        if let firstFittingCandidate { return firstFittingCandidate }
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
        var firstFittingCandidate: DialRadialLayout?
        for itemSize in candidates {
            let candidate = DialRadialLayout.inwardFan(
                center: center, preferredRadius: min(142, max(78, containerSize.height * 0.2)),
                itemRadius: itemRadius, itemSize: itemSize, count: nodeCount,
                placement: placement, bounds: containerSize, safeAreaInsets: insets,
                requireSeparatedTargets: true)
            guard candidate.fits(in: containerSize, safeAreaInsets: insets, hubRadius: itemRadius)
            else { continue }
            firstFittingCandidate = firstFittingCandidate ?? candidate
            if isAngularLayout(candidate) { return candidate }
        }
        if let angularFallback = inwardAngularFallback(
            center: center, itemSizes: candidates, itemRadius: itemRadius, count: nodeCount,
            placement: placement, containerSize: containerSize, safeAreaInsets: insets)
        {
            return angularFallback
        }
        if let firstFittingCandidate { return firstFittingCandidate }
        return DialRadialLayout.inwardFan(
            center: center, preferredRadius: min(142, max(78, containerSize.height * 0.2)),
            itemRadius: itemRadius, itemSize: candidates.last ?? baseSize, count: nodeCount,
            placement: placement, bounds: containerSize, safeAreaInsets: insets,
            requireSeparatedTargets: true)
    }

    /// Finds a bounded uniform-polar fan when Core's fitting fallback is nonangular.
    /// Candidate headings point toward the usable interior or its inward axes; the fan
    /// midpoint, not every ray, is inward so broad existing Core spans remain available.
    private static func inwardAngularFallback(
        center: CGPoint, itemSizes: [CGSize], itemRadius: CGFloat, count: Int,
        placement: CommandDialPlacement, containerSize: CGSize,
        safeAreaInsets: DialLayoutInsets
    ) -> DialRadialLayout? {
        guard count > 0, containerSize.width.isFinite, containerSize.height.isFinite,
            containerSize.width > 0, containerSize.height > 0,
            center.x.isFinite, center.y.isFinite, itemRadius.isFinite, itemRadius > 0,
            safeAreaInsets.leading.isFinite, safeAreaInsets.trailing.isFinite,
            safeAreaInsets.top.isFinite, safeAreaInsets.bottom.isFinite,
            safeAreaInsets.leading >= 0, safeAreaInsets.trailing >= 0,
            safeAreaInsets.top >= 0, safeAreaInsets.bottom >= 0
        else { return nil }
        let usableCenter = CGPoint(
            x: (safeAreaInsets.leading + containerSize.width - safeAreaInsets.trailing) / 2,
            y: (safeAreaInsets.top + containerSize.height - safeAreaInsets.bottom) / 2)
        let dx = usableCenter.x - center.x
        let dy = usableCenter.y - center.y
        guard usableCenter.x.isFinite, usableCenter.y.isFinite else { return nil }
        let epsilon: CGFloat = 0.001
        var headings: [CGFloat] = []
        if hypot(dx, dy) >= epsilon {
            headings.append(atan2(dy, dx))
        }
        if abs(dx) >= epsilon { headings.append(dx > 0 ? 0 : .pi) }
        if abs(dy) >= epsilon { headings.append(dy > 0 ? .pi / 2 : -.pi / 2) }
        if headings.isEmpty {
            headings.append(placement == .leading ? 0 : .pi)
        }
        var uniqueHeadings: [CGFloat] = []
        for heading in headings where heading.isFinite {
            if !uniqueHeadings.contains(where: {
                abs(atan2(sin(heading - $0), cos(heading - $0))) < epsilon
            }) {
                uniqueHeadings.append(heading)
            }
        }
        guard !uniqueHeadings.isEmpty else { return nil }

        var seenSizes: [CGSize] = []
        for requestedSize in itemSizes {
            guard requestedSize.width.isFinite, requestedSize.height.isFinite,
                requestedSize.width > 0, requestedSize.height > 0
            else { continue }
            let itemSize = CGSize(
                width: max(DialRadialLayout.minimumTargetDimension, requestedSize.width),
                height: max(DialRadialLayout.minimumTargetDimension, requestedSize.height))
            guard !seenSizes.contains(itemSize) else { continue }
            seenSizes.append(itemSize)
            let baseSpan = min(1.45, max(0.68, CGFloat(count - 1) * 0.34))
            let spans: [CGFloat] = [baseSpan, max(baseSpan, 1.9), 2.5, .pi]
            for heading in uniqueHeadings {
                for span in spans {
                    let start = heading - span / 2
                    let end = heading + span / 2
                    guard
                        let minimumRadius = requiredInwardOrbitRadius(
                            center: center, itemSize: itemSize, itemRadius: itemRadius,
                            startAngle: start, endAngle: end, count: count),
                        let maximumRadius = maximumInwardOrbitRadius(
                            center: center, itemSize: itemSize, itemRadius: itemRadius,
                            startAngle: start, endAngle: end, count: count,
                            bounds: containerSize, safeAreaInsets: safeAreaInsets),
                        minimumRadius <= maximumRadius
                    else { continue }
                    // Use the interior of a real feasible interval to avoid relying on
                    // floating-point contact at either containment/separation boundary.
                    let orbitRadius =
                        maximumRadius > minimumRadius
                        ? minimumRadius + (maximumRadius - minimumRadius) / 2
                        : minimumRadius
                    let candidate = DialRadialLayout(
                        center: center, orbitRadius: orbitRadius, itemRadius: itemRadius,
                        itemSize: itemSize, startAngle: start, endAngle: end, count: count)
                    guard
                        candidate.fits(
                            in: containerSize, safeAreaInsets: safeAreaInsets,
                            hubRadius: itemRadius),
                        candidate.itemSize.width >= DialRadialLayout.minimumTargetDimension,
                        candidate.itemSize.height >= DialRadialLayout.minimumTargetDimension
                    else { continue }
                    return candidate
                }
            }
        }
        return nil
    }

    private static func requiredInwardOrbitRadius(
        center: CGPoint, itemSize: CGSize, itemRadius: CGFloat,
        startAngle: CGFloat, endAngle: CGFloat, count: Int
    ) -> CGFloat? {
        guard count > 0, startAngle.isFinite, endAngle.isFinite else { return nil }
        var required = itemRadius + hypot(itemSize.width / 2, itemSize.height / 2)
        let angles = (0..<count).map { index in
            count > 1
                ? startAngle + CGFloat(index) * (endAngle - startAngle) / CGFloat(count - 1)
                : (startAngle + endAngle) / 2
        }
        for first in angles.indices {
            for second in angles.indices where second > first {
                let dx = cos(angles[second]) - cos(angles[first])
                let dy = sin(angles[second]) - sin(angles[first])
                let xRadius = abs(dx) > 0.000001 ? itemSize.width / abs(dx) : .infinity
                let yRadius = abs(dy) > 0.000001 ? itemSize.height / abs(dy) : .infinity
                required = max(required, min(xRadius, yRadius))
            }
        }
        return required.isFinite ? required : nil
    }

    private static func maximumInwardOrbitRadius(
        center: CGPoint, itemSize: CGSize, itemRadius: CGFloat,
        startAngle: CGFloat, endAngle: CGFloat, count: Int, bounds: CGSize,
        safeAreaInsets: DialLayoutInsets
    ) -> CGFloat? {
        let minimumX = max(
            safeAreaInsets.leading + itemSize.width / 2,
            safeAreaInsets.leading + itemRadius)
        let maximumX = min(
            bounds.width - safeAreaInsets.trailing - itemSize.width / 2,
            bounds.width - safeAreaInsets.trailing - itemRadius)
        let minimumY = max(
            safeAreaInsets.top + itemSize.height / 2,
            safeAreaInsets.top + itemRadius)
        let maximumY = min(
            bounds.height - safeAreaInsets.bottom - itemSize.height / 2,
            bounds.height - safeAreaInsets.bottom - itemRadius)
        guard center.x >= safeAreaInsets.leading + itemRadius,
            center.x <= bounds.width - safeAreaInsets.trailing - itemRadius,
            center.y >= safeAreaInsets.top + itemRadius,
            center.y <= bounds.height - safeAreaInsets.bottom - itemRadius,
            minimumX <= maximumX, minimumY <= maximumY
        else { return nil }
        var maximumRadius = CGFloat.greatestFiniteMagnitude
        for index in 0..<count {
            let angle =
                count > 1
                ? startAngle + CGFloat(index) * (endAngle - startAngle) / CGFloat(count - 1)
                : (startAngle + endAngle) / 2
            let xDirection = cos(angle)
            let yDirection = sin(angle)
            if xDirection > 0.000001 {
                maximumRadius = min(maximumRadius, (maximumX - center.x) / xDirection)
            } else if xDirection < -0.000001 {
                maximumRadius = min(maximumRadius, (minimumX - center.x) / xDirection)
            }
            if yDirection > 0.000001 {
                maximumRadius = min(maximumRadius, (maximumY - center.y) / yDirection)
            } else if yDirection < -0.000001 {
                maximumRadius = min(maximumRadius, (minimumY - center.y) / yDirection)
            }
        }
        guard maximumRadius.isFinite else { return nil }
        return max(0, maximumRadius)
    }

    /// Identifies the current Core angularFan and mirrored angular producers without
    /// expanding Core's policy API. This private check intentionally relies on their
    /// uniform polar representation and matching metadata; a future nonuniform producer
    /// must receive a local test/update rather than silently changing candidate choice.
    private static func isAngularLayout(_ layout: DialRadialLayout) -> Bool {
        guard layout.count > 1 else { return true }
        let step = (layout.endAngle - layout.startAngle) / CGFloat(layout.count - 1)
        let tolerance = CGFloat.ulpOfOne * max(1, abs(layout.orbitRadius)) * 64
        return layout.positions.enumerated().allSatisfy { index, position in
            let angle = layout.startAngle + CGFloat(index) * step
            let expected = CGPoint(
                x: layout.center.x + cos(angle) * layout.orbitRadius,
                y: layout.center.y + sin(angle) * layout.orbitRadius)
            return hypot(position.x - expected.x, position.y - expected.y) <= tolerance
        }
    }

    private func radialLayout(
        center: CGPoint, containerSize: CGSize, safeAreaInsets: EdgeInsets
    ) -> DialRadialLayout {
        if navigation.path.isEmpty {
            return Self.computeRadialLayout(
                size: size, placement: placement, nodeCount: currentNodes.count,
                containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        }
        let activeCenter = Self.computeCurrentAncestorCenter(
            model: model, path: navigation.path, size: size, placement: placement,
            containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        return Self.computeChildRadialLayout(
            size: size, placement: placement, nodeCount: currentNodes.count,
            center: activeCenter, containerSize: containerSize, safeAreaInsets: safeAreaInsets)
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

    private func accessibilityLayout(safeAreaInsets: EdgeInsets) -> some View {
        VStack(spacing: 12) {
            Spacer().frame(height: max(safeAreaInsets.top, 8) + 45)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(currentNodes) { node in accessibilityNodeButton(node) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            backButton
                .padding(.horizontal, 14)
                .padding(.bottom, max(safeAreaInsets.bottom, 12))
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
                    .strokeBorder(
                        highlighted ? accent : accent.opacity(0.42), lineWidth: highlighted ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
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
